import { drawingSettings } from './drawing-settings.mjs';
import { execFile,spawn } from 'node:child_process';
import { mkdtemp,rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { promisify } from 'node:util';
import { assertResult,decodeImage,resultSchema } from './schema.mjs';
import { VISUAL_INSTRUCTIONS } from './codex.mjs';
import { previewEmitter } from './visual-stream.mjs';

const exec = promisify(execFile);
export const CLAUDE_MODEL = 'claude-sonnet-5-5';
export const CLAUDE_EFFORT = 'low';
// USER and LOGNAME are how the CLI finds its Keychain login. API keys stay out,
// so this always uses the signed-in Claude account, as GPT uses the ChatGPT one.
export function claudeEnvironment(source=process.env) {
  return Object.fromEntries(['HOME','PATH','USER','LOGNAME','TMPDIR','LANG','LC_ALL','CLAUDE_CONFIG_DIR','CLIPPY_CLAUDE_BIN'].filter(k=>typeof source[k]==='string').map(k=>[k,source[k]]));
}
const claudeBinary = env => env.CLIPPY_CLAUDE_BIN||'claude';
export async function claudeAuthStatus({env=claudeEnvironment(),run=exec}={}) {
  try {
    const {stdout} = await run(claudeBinary(env),['auth','status'],{env,timeout:10000});
    return JSON.parse(stdout).loggedIn===true;
  } catch { return false; }
}
// No tools, MCP servers, settings, hooks, skills or saved sessions: it can only answer.
export function claudeArguments({model=CLAUDE_MODEL,effort=CLAUDE_EFFORT,schema=resultSchema,instructions=VISUAL_INSTRUCTIONS}={}) {
  return ['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--include-partial-messages',
    '--json-schema',JSON.stringify(schema),'--model',model,'--effort',effort,'--system-prompt',instructions,
    '--tools','','--no-session-persistence','--strict-mcp-config','--setting-sources','','--disable-slash-commands'];
}
// The Claude CLI's replacement for the Codex SDK: one structured answer, with nothing else it can do.
export function claudeMessage(request) {
  const content=[{type:'text',text:'CONTEXT AND USER REQUEST (JSON):\n'+JSON.stringify({history:request.history,previous:request.previous,message:request.message})}];
  const image=decodeImage(request.image);
  if(image)content.push({type:'image',source:{type:'base64',media_type:image.extension==='png'?'image/png':'image/jpeg',data:image.data.toString('base64')}});
  return {type:'user',message:{role:'user',content}};
}
export function generateWithClaude(request,options={}) {
  const {model,reasoningEffort,name}=drawingSettings({...request,provider:'claude'});
  return runClaudeStructured(claudeMessage(request),{model,effort:reasoningEffort,...options,instructions:VISUAL_INSTRUCTIONS,schema:resultSchema,validate:assertResult,status:`Thinking with ${name}…`,tier:request.tier??'fast'});
}
export async function runClaudeStructured(message,{signal,onStatus=()=>{},onPreview,env=claudeEnvironment(),spawnImpl=spawn,model=CLAUDE_MODEL,effort=CLAUDE_EFFORT,instructions,schema,validate=x=>x,status,tier=null}={}) {
  const started=Date.now();
  signal?.throwIfAborted();
  // Outside the project, so the CLI finds no project instructions to load.
  const work=await mkdtemp(path.join(tmpdir(),'clippy-claude-'));
  let child,lines,exitTimer;
  try {
    onStatus(status);
    child=spawnImpl(claudeBinary(env),claudeArguments({model,effort,schema,instructions}),{cwd:work,env,stdio:['pipe','pipe','pipe']});
    // Do not log stderr: upstream diagnostic output may contain private context.
    child.stderr.resume();
    const onText=onPreview?previewEmitter(onPreview):()=>{};
    let raw='',abort;
    const output=await new Promise((resolve,reject)=>{
      abort=()=>reject(signal.reason||new Error('Drawing cancelled.'));
      signal?.addEventListener('abort',abort,{once:true});
      child.on('error',error=>reject(new Error(error.code==='ENOENT'?'Could not find the Claude CLI. Install Claude Code, or switch back to GPT.':'Could not start the Claude CLI.')));
      child.stdin.on('error',()=>reject(new Error('The Claude CLI closed its connection.')));
      child.on('exit',()=>reject(new Error('Claude ended before completing the drawing.')));
      lines=createInterface({input:child.stdout,crlfDelay:Infinity});
      lines.on('line',line=>{
        try {
          if(line.length>3_000_000)throw new Error('Claude event too large.');
          const event=JSON.parse(line);
          const delta=event.type==='stream_event'&&event.event?.type==='content_block_delta'?event.event.delta:null;
          if(delta?.type==='input_json_delta'&&delta.partial_json){
            raw+=delta.partial_json;
            if(raw.length>2_000_000)throw new Error('Visual response too large.');
            onText(raw);
          }
          if(event.type==='result')resolve(event);
        }catch(error){reject(error);}
      });
      child.stdin.end(JSON.stringify(message)+'\n');
    }).finally(()=>signal?.removeEventListener('abort',abort));
    if(output.is_error||output.subtype!=='success'){
      const text=String(output.result||'');
      throw new Error(/not logged in/i.test(text)?'Sign in to Claude first: run claude auth login in Terminal.':(text.slice(0,500)||'Claude could not complete the drawing.'));
    }
    let result=output.structured_output;
    if(!result){try{result=JSON.parse(output.result);}catch{throw new Error('Claude returned an unreadable answer. Please try again.');}}
    return {result:validate(result),usage:output.usage??null,elapsedMs:Date.now()-started,model,reasoningEffort:effort,requestedTier:tier,provider:'claude'};
  } finally {
    lines?.close();
    if(child){
      child.kill('SIGTERM');exitTimer=setTimeout(()=>child.kill('SIGKILL'),1000);exitTimer.unref?.();
      await new Promise(resolve=>{if(child.exitCode!==null||child.signalCode!==null){clearTimeout(exitTimer);resolve();}else child.once('exit',()=>{clearTimeout(exitTimer);resolve();});});
    }
    await rm(work,{recursive:true,force:true});
  }
}
