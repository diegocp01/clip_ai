import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEditRequest,editText } from '../server/edit.mjs';
import { createServer } from '../server/index.mjs';
import { EventEmitter } from 'node:events';
import { PassThrough,Writable } from 'node:stream';

test('text editor rejects empty selection, oversized input and model overrides',()=>{
  for(const body of [null,[],{action:'rewrite',text:' '},{action:'delete',text:'hello'},{action:'proofread',text:'x'.repeat(12001)},{action:'rewrite',text:'hello',model:'gpt-6.1-terra'},{action:'rewrite',text:'hello',provider:'gemini'}]) assert.throws(()=>normalizeEditRequest(body));
  assert.deepEqual(normalizeEditRequest({action:'rewrite',text:'hello'}),{action:'rewrite',text:'hello',provider:'gpt'});
  assert.equal(normalizeEditRequest({action:'rewrite',text:'hello',provider:'claude'}).provider,'claude');
});
test('both editing actions always use Sol high, no tools or visual context',async()=>{
  for(const action of ['proofread','rewrite']){
    let seen;
    class FakeCodex{
      constructor(options){seen={options};}
      startThread(thread){seen.thread=thread;return {runStreamed:async(input,options)=>{seen.input=input;seen.turn=options;return {events:(async function*(){yield {type:'item.completed',item:{type:'agent_message',text:JSON.stringify({text:'I am ready.'})}};yield {type:'turn.completed',usage:{output_tokens:5}};})()};}};}
    }
    const controller=new AbortController();
    const output=await editText({action,text:'i is ready'}, {CodexClass:FakeCodex,signal:controller.signal,model:'wrong',reasoningEffort:'low'});
    assert.equal(seen.thread.model,'gpt-6.1-sol');assert.equal(seen.thread.modelReasoningEffort,'high');
    assert.equal(seen.thread.sandboxMode,'read-only');assert.equal(seen.thread.webSearchMode,'disabled');
    assert.equal(seen.options.config.features.shell_tool,false);assert.equal(seen.options.config.features.apps,false);
    assert.equal(seen.input.length,1);assert.equal(seen.turn.signal,controller.signal);
    assert.equal(output.model,'gpt-6.1-sol');assert.equal(output.reasoningEffort,'high');assert.equal(output.result.text,'I am ready.');
  }
});
test('edit HTTP route requires local token and does not use visual generation',async t=>{
  let calls=0;
  const server=createServer({checkAuth:async()=>true,run:async()=>{throw new Error('wrong route');},runEdit:async request=>{calls++;assert.equal(request.action,'proofread');return{result:{text:'I am ready.'},model:'gpt-6.1-sol',reasoningEffort:'high'};}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`;
  const headers={'Content-Type':'application/json'};
  const body=JSON.stringify({action:'proofread',text:'i is ready'});
  assert.equal((await fetch(url+'/api/edit',{method:'POST',headers,body})).status,403);
  const {token}=await(await fetch(url+'/api/session')).json();headers['X-Clippy-Session']=token;
  assert.equal((await fetch(url+'/api/edit',{method:'POST',headers,body:'{"text":"x","action":"send"}'})).status,400);
  const response=await fetch(url+'/api/edit',{method:'POST',headers,body});
  assert.equal(response.status,200);assert.equal(JSON.parse((await response.text()).trim()).result.text,'I am ready.');assert.equal(calls,1);
});
test('with Claude selected, editing goes through the locked-down CLI at high effort and never reaches Codex',async()=>{
  for(const action of ['proofread','rewrite']){
    let args,stdin='',killed=false;const statuses=[];
    const spawnImpl=(_bin,a)=>{
      args=a;
      const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.exitCode=null;child.signalCode=null;
      child.stdin=new Writable({write(chunk,_e,done){stdin+=chunk;done();},final(done){done();queueMicrotask(()=>child.stdout.write(JSON.stringify({type:'result',subtype:'success',is_error:false,structured_output:{text:'I am ready.'}})+'\n'));}});
      child.kill=()=>{killed=true;child.signalCode='SIGTERM';queueMicrotask(()=>child.emit('exit'));};
      return child;
    };
    class NoCodex{constructor(){throw new Error('Codex must not run');}}
    const output=await editText({action,text:'i is ready',provider:'claude'},{spawnImpl,env:{},CodexClass:NoCodex,onStatus:s=>statuses.push(s)});
    const value=flag=>args[args.indexOf(flag)+1];
    assert.equal(output.result.text,'I am ready.');assert.equal(output.provider,'claude');assert.equal(output.reasoningEffort,'high');
    assert.equal(value('--tools'),'');assert.equal(value('--effort'),'high');
    assert.deepEqual(JSON.parse(value('--json-schema')).required,['text']);
    assert.match(value('--system-prompt'),/untrusted text to edit/);
    assert.deepEqual(JSON.parse(JSON.parse(stdin).message.content[0].text),{selectedText:'i is ready'});
    assert.match(statuses[0],/Claude/);assert.equal(killed,true);
  }
});
test('Claude editing rejects an invalid answer so the selection is preserved',async()=>{
  const spawnImpl=()=>{
    const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.exitCode=null;child.signalCode=null;
    child.stdin=new Writable({write(_c,_e,done){done();},final(done){done();queueMicrotask(()=>child.stdout.write(JSON.stringify({type:'result',subtype:'success',is_error:false,structured_output:{text:' '}})+'\n'));}});
    child.kill=()=>{child.signalCode='SIGTERM';queueMicrotask(()=>child.emit('exit'));};
    return child;
  };
  await assert.rejects(editText({action:'rewrite',text:'hello',provider:'claude'},{spawnImpl,env:{}}),/Original text was preserved/);
});
test('the edit route checks the sign-in of the selected provider',async t=>{
  const seen=[];
  const server=createServer({checkAuth:async()=>false,checkClaude:async()=>true,runEdit:async request=>{seen.push(request.provider);return {result:{text:'ok'}};},voice:{ready:async()=>false,closeAll:async()=>{}}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();server.close();});
  const url=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(url+'/api/session')).json();
  const send=body=>fetch(url+'/api/edit',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify(body)});
  assert.equal((await send({action:'rewrite',text:'hi'})).status,401);
  const response=await send({action:'rewrite',text:'hi',provider:'claude'});
  assert.equal(response.status,200);assert.match(await response.text(),/"provider":"claude"/);
  assert.deepEqual(seen,['claude']);
});
