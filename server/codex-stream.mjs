import { spawn } from 'node:child_process';
import { mkdir, symlink, access } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
// Each request gets a private config directory. Only the existing managed login
// is linked; personal tools, hooks, plugins, rules and sessions are not loaded.
export async function runVisualStream({input,work,model,reasoningEffort,tier,schema,signal,onText=()=>{},env={},spawnImpl=spawn}) {
  const home=path.join(work,'codex');await mkdir(home,{mode:0o700});
  const auth=path.join(env.CODEX_HOME||path.join(homedir(),'.codex'),'auth.json');
  try {await access(auth);await symlink(auth,path.join(home,'auth.json'));}
  catch {throw new Error('Streaming visuals need the Codex file login. Run the bundled codex login first.');}
  const config={
    'features.shell_tool':false,'features.multi_agent':false,'features.apps':false,'features.plugins':false,
    'features.memories':false,'features.request_permissions_tool':false,'features.fast_mode':tier!=='standard',
    'skills.bundled.enabled':false,'skills.include_instructions':false,'project_doc_max_bytes':0,
    'web_search':'disabled','model_reasoning_effort':reasoningEffort,'cli_auth_credentials_store':'file',
    'sandbox_mode':'read-only','approval_policy':'never',
  };
  const args=['app-server','--listen','stdio://'];for(const [key,value] of Object.entries(config))args.push('-c',`${key}=${JSON.stringify(value)}`);
  signal?.throwIfAborted();
  const child=spawnImpl(env.CLIPPY_CODEX_BIN||path.join(root,'node_modules/.bin/codex'),args,{cwd:work,env:{...env,CODEX_HOME:home},stdio:['pipe','pipe','pipe']});
  // Do not log stderr: upstream diagnostic output may contain private context.
  child.stderr.resume();
  const lines=createInterface({input:child.stdout,crlfDelay:Infinity});
  let sequence=0,threadId=null,raw='',usage=null,settled=false,exitTimer;
  const pending=new Map();
  let resolveTurn,rejectTurn;
  const completion=new Promise((resolve,reject)=>{resolveTurn=resolve;rejectTurn=reject;});
  completion.catch(()=>{});
  const fail=error=>{if(settled)return;settled=true;for(const item of pending.values())item.reject(error);pending.clear();rejectTurn(error);};
  const write=message=>{child.stdin.write(JSON.stringify(message)+'\n');};
  const request=(method,params)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});write({id,method,params});});
  const abort=()=>fail(signal.reason||new Error('Drawing cancelled.'));
  child.on('error',()=>fail(new Error('Could not start the bundled Codex streaming runtime.')));
  child.stdin.on('error',()=>fail(new Error('Codex streaming connection closed.')));
  child.on('exit',()=>{clearTimeout(exitTimer);if(!settled)fail(new Error('Codex ended before completing the drawing.'));});
  signal?.addEventListener('abort',abort,{once:true});
  const timer=setTimeout(()=>fail(new Error('Drawing timed out. Try a simpler request.')),120000);timer.unref?.();
  lines.on('line',line=>{
    if(settled)return;
    try {
      if(line.length>3_000_000)throw new Error('Codex event too large.');
      const event=JSON.parse(line);
      if(event.method&&event.id!==undefined){write({id:event.id,error:{code:-32601,message:'Tools and approval requests are unavailable in Clippy visuals.'}});return;}
      if(event.id!==undefined){const item=pending.get(event.id);if(item){pending.delete(event.id);event.error?item.reject(new Error(String(event.error.message).slice(0,500))):item.resolve(event.result);}return;}
      const p=event.params;if(!p||p.threadId!==threadId)return;
      if(event.method==='item/agentMessage/delta'){raw+=p.delta;if(raw.length>2_000_000)throw new Error('Visual response too large.');onText(raw);}
      if(event.method==='item/completed'&&p.item?.type==='agentMessage'){raw=p.item.text;onText(raw);}
      if(event.method==='thread/tokenUsage/updated')usage=p.tokenUsage?.last||null;
      if(event.method==='turn/completed'){
        if(p.turn?.status!=='completed')throw new Error(p.turn?.error?.message||'Drawing did not complete.');
        settled=true;resolveTurn({raw,usage});
      }
    }catch(error){fail(error);}
  });
  try {
    await request('initialize',{clientInfo:{name:'clippy_island',title:'Clippy Island',version:'0.1.0'}});
    write({method:'initialized',params:{}});
    const started=await request('thread/start',{model,cwd:work,ephemeral:true,approvalPolicy:'never',sandbox:'read-only',serviceTier:tier==='standard'?'default':'fast',baseInstructions:'You are a visual JSON generator. Follow the supplied visual specification. You have no tools.',config:{model_reasoning_effort:reasoningEffort}});
    threadId=started.thread.id;
    await request('turn/start',{threadId,model,effort:reasoningEffort,outputSchema:schema,input:input.map(item=>item.type==='local_image'?{type:'localImage',path:item.path}:{...item,text_elements:[]})});
    return await completion;
  } finally {
    settled=true;clearTimeout(timer);signal?.removeEventListener('abort',abort);lines.close();child.stdin.end();
    child.kill('SIGTERM');exitTimer=setTimeout(()=>child.kill('SIGKILL'),1000);exitTimer.unref?.();
    await new Promise(resolve=>{if(child.exitCode!==null||child.signalCode!==null){clearTimeout(exitTimer);resolve();}else child.once('exit',resolve);});
  }
}
