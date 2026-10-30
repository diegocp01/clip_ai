import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEditRequest,editText } from '../server/edit.mjs';
import { createServer } from '../server/index.mjs';

test('text editor rejects empty selection, oversized input and model overrides',()=>{
  for(const body of [null,[],{action:'rewrite',text:' '},{action:'delete',text:'hello'},{action:'proofread',text:'x'.repeat(12001)},{action:'rewrite',text:'hello',model:'gpt-6.1-terra'}]) assert.throws(()=>normalizeEditRequest(body));
  assert.deepEqual(normalizeEditRequest({action:'rewrite',text:'hello'}),{action:'rewrite',text:'hello'});
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
