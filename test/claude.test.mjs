import test from 'node:test';
import assert from 'node:assert/strict';
import { access } from 'node:fs/promises';
import { EventEmitter } from 'node:events';
import { PassThrough,Writable } from 'node:stream';
import { claudeArguments,claudeAuthStatus,claudeEnvironment,claudeMessage,generateWithClaude,CLAUDE_MODEL } from '../server/claude.mjs';
import { createServer } from '../server/index.mjs';
import { normalizeRequest } from '../server/schema.mjs';

const atom=id=>({id,label:id,description:'An atom',shape:'sphere',color:'#E88570',position:[0,0,0],scale:[1,1,1],rotation:[0,0,0]});
const visual={title:'Water',scene:{objects:[atom('o'),atom('h')]},diagram:{nodes:[],links:[]},annotations:[],cards:[],reply:'Complete.'};
const delta=partial_json=>({type:'stream_event',event:{type:'content_block_delta',index:0,delta:{type:'input_json_delta',partial_json}}});
const success=extra=>({type:'result',subtype:'success',is_error:false,usage:{output_tokens:9},...extra});
function fakeClaude(events,{exitEarly=false,hang=false}={}) {
  const state={stdin:'',killed:false};
  state.spawn=(bin,args,options)=>{
    Object.assign(state,{bin,args,options});
    const child=new EventEmitter();
    child.stdout=new PassThrough();child.stderr=new PassThrough();child.exitCode=null;child.signalCode=null;
    child.stdin=new Writable({write(chunk,_encoding,done){state.stdin+=chunk;done();},final(done){
      done();
      if(hang)return;
      queueMicrotask(()=>{
        for(const event of events)child.stdout.write(JSON.stringify(event)+'\n');
        if(exitEarly)setImmediate(()=>{child.exitCode=1;child.emit('exit');});
      });
    }});
    child.kill=()=>{state.killed=true;child.signalCode='SIGTERM';queueMicrotask(()=>child.emit('exit'));};
    return child;
  };
  return state;
}
const request=extra=>normalizeRequest({message:'water',provider:'claude',...extra});

test('provider defaults to GPT and rejects anything unknown',()=>{
  assert.equal(normalizeRequest({message:'x'}).provider,'gpt');
  assert.equal(normalizeRequest({message:'x',provider:'claude'}).provider,'claude');
  assert.throws(()=>normalizeRequest({message:'x',provider:'gemini'}),/Invalid request/);
});
test('the CLI runs with no tools, MCP, settings or saved sessions',()=>{
  const args=claudeArguments();
  const value=flag=>args[args.indexOf(flag)+1];
  assert.equal(value('--tools'),'');
  assert.equal(value('--setting-sources'),'');
  for(const flag of ['-p','--strict-mcp-config','--no-session-persistence','--disable-slash-commands','--include-partial-messages'])assert.ok(args.includes(flag),flag);
  assert.equal(value('--model'),CLAUDE_MODEL);
  assert.equal(value('--effort'),'low');
  assert.equal(JSON.parse(value('--json-schema')).properties.scene.type,'object');
  assert.match(value('--system-prompt'),/You are Clip/);
  assert.match(value('--system-prompt'),/normalized 0\.\.1/);
});
test('the environment keeps the login but drops API keys and the parent session',()=>{
  const env=claudeEnvironment({HOME:'/h',PATH:'/p',USER:'u',LOGNAME:'u',ANTHROPIC_API_KEY:'secret',OPENAI_API_KEY:'secret',CLAUDECODE:'1',CLAUDE_CODE_OAUTH_TOKEN:'secret',CLIPPY_CLAUDE_BIN:'/bin/claude'});
  assert.deepEqual(env,{HOME:'/h',PATH:'/p',USER:'u',LOGNAME:'u',CLIPPY_CLAUDE_BIN:'/bin/claude'});
});
test('sign-in status comes from the CLI and fails closed',async()=>{
  assert.equal(await claudeAuthStatus({env:{},run:async()=>({stdout:'{"loggedIn":true}'})}),true);
  assert.equal(await claudeAuthStatus({env:{},run:async()=>({stdout:'{"loggedIn":false}'})}),false);
  assert.equal(await claudeAuthStatus({env:{},run:async()=>({stdout:'not json'})}),false);
  assert.equal(await claudeAuthStatus({env:{},run:async()=>{throw new Error('missing');}}),false);
});
test('a screenshot goes inline as a validated image block',()=>{
  const png='data:image/png;base64,iVBORw0KGgo=';
  const content=claudeMessage(request({image:png})).message.content;
  assert.equal(content[1].source.media_type,'image/png');
  assert.equal(content[1].source.data,'iVBORw0KGgo=');
  assert.equal(claudeMessage(request()).message.content.length,1);
  assert.throws(()=>claudeMessage({...request(),image:'data:image/png;base64,AAAA'}),/Invalid image/);
});
test('streams previews before the result, returns a validated visual and cleans up',async()=>{
  const text=JSON.stringify(visual),previews=[],statuses=[];
  const fake=fakeClaude([{type:'system',subtype:'init'},delta(text.slice(0,-20)),delta(text.slice(-20)),success({structured_output:visual})]);
  const output=await generateWithClaude(request(),{spawnImpl:fake.spawn,env:{HOME:'/h'},onPreview:r=>previews.push(r),onStatus:s=>statuses.push(s)});
  assert.equal(output.result.reply,'Complete.');
  assert.equal(output.provider,'claude');
  assert.equal(output.model,CLAUDE_MODEL);
  assert.equal(previews[0].reply,'');
  assert.ok(previews[0].scene.objects.length>=1);
  assert.match(statuses[0],/Claude/);
  assert.equal(JSON.parse(fake.stdin).message.role,'user');
  assert.match(JSON.parse(fake.stdin).message.content[0].text,/"message":"water"/);
  assert.equal(fake.killed,true);
  await assert.rejects(access(fake.options.cwd));
});
test('falls back to the result text when structured output is missing',async()=>{
  const fake=fakeClaude([success({result:JSON.stringify(visual)})]);
  assert.equal((await generateWithClaude(request(),{spawnImpl:fake.spawn,env:{}})).result.title,'Water');
});
test('reports sign-in, API, invalid and unreadable answers clearly',async()=>{
  const run=events=>generateWithClaude(request(),{spawnImpl:fakeClaude(events).spawn,env:{}});
  await assert.rejects(run([{type:'result',subtype:'success',is_error:true,result:'Not logged in · Please run /login'}]),/claude auth login/);
  await assert.rejects(run([{type:'result',subtype:'error_during_execution',is_error:true,result:'Usage limit reached'}]),/Usage limit reached/);
  await assert.rejects(run([success({structured_output:{...visual,scene:{objects:[atom('x'),atom('x')]}}})]),/duplicate/);
  await assert.rejects(run([success({result:'I cannot help'})]),/unreadable/);
});
test('reports a missing CLI and an early exit',async()=>{
  const missing=()=>{const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.stdin=new Writable({write(_c,_e,d){d();}});child.exitCode=1;child.signalCode=null;child.kill=()=>{};queueMicrotask(()=>child.emit('error',Object.assign(new Error('x'),{code:'ENOENT'})));return child;};
  await assert.rejects(generateWithClaude(request(),{spawnImpl:missing,env:{}}),/Could not find the Claude CLI/);
  await assert.rejects(generateWithClaude(request(),{spawnImpl:fakeClaude([],{exitEarly:true}).spawn,env:{}}),/ended before completing/);
});
test('cancelling stops the CLI',async()=>{
  const controller=new AbortController(),fake=fakeClaude([],{hang:true});
  const pending=generateWithClaude(request(),{spawnImpl:fake.spawn,env:{},signal:controller.signal});
  await new Promise(resolve=>setTimeout(resolve,20));
  controller.abort(new Error('Stopped by user.'));
  await assert.rejects(pending,/Stopped by user/);
  assert.equal(fake.killed,true);
});

test('the server routes each provider to its own runner and sign-in check',async t=>{
  const calls=[];
  const server=createServer({chooseStatus:async()=>null,
    run:async(r,o)=>{calls.push('gpt');o.onStatus('codex');return {result:visual,provider:'gpt'};},
    runClaude:async(r,o)=>{calls.push('claude');o.onStatus('claude');return {result:visual,provider:'claude'};},
    checkAuth:async()=>false,checkClaude:async()=>true,
    voice:{ready:async()=>false,closeAll:async()=>{}},
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const base=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(base+'/api/session')).json();
  const send=provider=>fetch(base+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'hi',mode:'chat',...(provider?{provider}:{})})});

  const claude=await send('claude');
  assert.equal(claude.status,200);
  assert.match(await claude.text(),/"provider":"claude"/);
  // GPT is signed out here. That must block GPT without blocking Claude.
  const gpt=await send('gpt');
  assert.equal(gpt.status,401);
  assert.match((await gpt.json()).error,/codex login/);
  assert.equal((await send()).status,401,'No provider must mean GPT');
  assert.equal((await send('gemini')).status,400);
  assert.deepEqual(calls,['claude']);

  const signedIn=createServer({chooseStatus:async()=>null,run:async()=>({result:visual}),checkAuth:async()=>true,voice:{ready:async()=>false,closeAll:async()=>{}}});
  await new Promise(resolve=>signedIn.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>signedIn.close(resolve)));
  const other=`http://127.0.0.1:${signedIn.address().port}`;
  const session=(await(await fetch(other+'/api/session')).json()).token;
  const named=await fetch(other+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':session},body:JSON.stringify({message:'hi'})});
  assert.match(await named.text(),/"provider":"gpt"/,'Results must name their provider');

  const gptStatus=await(await fetch(base+'/api/status')).json();
  assert.equal(gptStatus.authenticated,false);
  assert.equal(gptStatus.provider,'gpt');
  const claudeStatus=await(await fetch(base+'/api/status?provider=claude')).json();
  assert.equal(claudeStatus.authenticated,true);
  assert.equal(claudeStatus.provider,'claude');
  assert.equal(claudeStatus.model,CLAUDE_MODEL);
});
test('a signed-out Claude gets its own sign-in message',async t=>{
  const server=createServer({chooseStatus:async()=>null,run:async()=>({}),runClaude:async()=>({}),checkAuth:async()=>true,checkClaude:async()=>false,voice:{ready:async()=>false,closeAll:async()=>{}}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const base=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(base+'/api/session')).json();
  const response=await fetch(base+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'hi',mode:'chat',provider:'claude'})});
  assert.equal(response.status,401);
  assert.match((await response.json()).error,/claude auth login/);
});

test('selected Claude model and reasoning effort reach CLI arguments',async()=>{
  const fake=fakeClaude([success({structured_output:visual})]);
  const out=await generateWithClaude(request({model:'claude-opus-5-5',reasoningEffort:'max'}),{spawnImpl:fake.spawn,env:{}});
  assert.equal(fake.args[fake.args.indexOf('--model')+1],'claude-opus-5-5');
  assert.equal(fake.args[fake.args.indexOf('--effort')+1],'max');
  assert.equal(out.model,'claude-opus-5-5');assert.equal(out.reasoningEffort,'max');
});

test('Claude chat uses chat instructions and preserves maximum effort without visual previews',async()=>{
  const result={...visual,scene:{objects:[]},reply:'Hello'};
  const fake=fakeClaude([delta(JSON.stringify(result)),success({structured_output:result})]);
  await generateWithClaude(request({mode:'chat',model:'claude-opus-5-5',reasoningEffort:'max'}),{spawnImpl:fake.spawn,env:{HOME:'/h'},onPreview:()=>assert.fail('no chat visual preview')});
  const value=flag=>fake.args[fake.args.indexOf(flag)+1];
  assert.equal(value('--model'),'claude-opus-5-5');assert.equal(value('--effort'),'max');
  assert.match(value('--system-prompt'),/This is chat, not Draw/);
});
