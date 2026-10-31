import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseEditAction} from '../server/edit-decision.mjs';
import {normalizeEditRequest,editText} from '../server/edit.mjs';
import {createServer} from '../server/index.mjs';
const request={text:'i is ready',action:'auto',provider:'gpt'};
const answer=choice=>Response.json({answers:[{type:'choice',name:'editing_action',choice}]});
test('edit Decisions sends only the selected text and permits only proofread/rewrite',async()=>{
 for(const choice of ['proofread','rewrite'])assert.equal(await chooseEditAction({...request,message:'private prompt',image:'private pixels',history:'private history'},{getKey:async()=>'test',fetchImpl:async(url,options)=>{
  assert.equal(url,'https://api.openai.com/v1/decisions');const body=JSON.parse(options.body);
  assert.deepEqual(JSON.parse(body.input),{selectedText:request.text});
  assert.deepEqual(body.questions[0].choices.map(c=>c.value),['proofread','rewrite']);return answer(choice);
 }}),choice);
 for(const fetchImpl of [async()=>answer('draw'),async()=>Response.json({answers:[{type:'refusal',name:'editing_action'}]}),async()=>new Response('',{status:403}),async()=>{throw Error('offline');}])assert.equal(await chooseEditAction(request,{getKey:async()=>'test',fetchImpl}),null);
 assert.equal(await chooseEditAction(request,{getKey:async()=>'',fetchImpl:()=>assert.fail()}),null);
});
test('edit choice times out conservatively but preserves Stop cancellation',async()=>{
 const alive=setTimeout(()=>{},1000);
 try {
  assert.equal(await chooseEditAction(request,{getKey:async()=>'test',timeoutMs:10,fetchImpl:(_u,{signal})=>new Promise((_r,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}))}),null);
  const controller=new AbortController();controller.abort(new Error('Stop'));
  await assert.rejects(chooseEditAction(request,{signal:controller.signal,getKey:()=>assert.fail()}),/Stop/);
 }finally{clearTimeout(alive);}
});
test('Auto is accepted at the boundary but cannot bypass the edit decision',()=>{
 assert.equal(normalizeEditRequest(request).action,'auto');
 assert.throws(()=>editText(request),/resolved by Decisions/);
 for(const value of [{...request,action:'draw'},{...request,text:' '},{...request,text:'x'.repeat(12001)},{...request,model:'auto'},{...request,image:'data'}])assert.throws(()=>normalizeEditRequest(value));
});
async function harness(t,overrides={}) {
 const server=createServer({checkAuth:async()=>true,checkClaude:async()=>true,routePresentation:()=>assert.fail('selection must never route to Draw or chat'),routeChat:()=>assert.fail(),run:()=>assert.fail(),runClaude:()=>assert.fail(),...overrides});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
 const base=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(base+'/api/session')).json();
 return async(body,signal,authorized=true)=>{
  const response=await fetch(base+'/api/edit',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':authorized?token:''},body:JSON.stringify(body),signal});
  return {status:response.status,events:(await response.text()).trim().split('\n').map(JSON.parse)};
 };
}
test('each automatic edit choice reaches only the selected editing provider',async t=>{
 for(const provider of ['gpt','claude'])for(const action of ['proofread','rewrite']) {
  let seen;
  const send=await harness(t,{routeEdit:async()=>action,runEdit:async r=>{seen=r;return{result:{text:'I am ready.'}};}});
  const {events}=await send({...request,provider});assert.equal(seen.action,action);assert.equal(seen.provider,provider);
  assert.ok(events.some(e=>e.type==='edit-route'&&e.action===action&&e.source==='decisions'));assert.equal(events.at(-1).result.text,'I am ready.');
 }
});
test('unknown/refused/offline edit choices default to minimal proofreading',async t=>{
 for(const choice of [null,'draw','chat','send']) {
  const send=await harness(t,{routeEdit:async()=>choice,runEdit:async r=>{assert.equal(r.action,'proofread');return{result:{text:r.text}};}});
  const {events}=await send(request);assert.ok(events.some(e=>e.type==='edit-route'&&e.action==='proofread'&&e.source==='fallback'));
 }
});
test('manual editing bypasses Decisions and unauthorized requests never reach it',async t=>{
 let calls=0;
 const send=await harness(t,{routeEdit:()=>assert.fail(),runEdit:async r=>{calls++;return{result:{text:r.text}};}});
 for(const action of ['proofread','rewrite'])assert.equal((await send({...request,action})).events.at(-1).type,'result');
 assert.equal((await send(request,undefined,false)).status,403);assert.equal(calls,2);
});
test('disconnect during automatic edit decision cancels and never edits',async t=>{
 let entered,signal,calls=0;const started=new Promise(r=>entered=r);
 const send=await harness(t,{routeEdit:(_r,options)=>{signal=options.signal;entered();return new Promise(r=>signal.addEventListener('abort',()=>r('rewrite'),{once:true}));},runEdit:()=>{calls++;}});
 const controller=new AbortController();const result=send(request,controller.signal);await started;controller.abort();await assert.rejects(result);
 for(let i=0;i<20&&!signal.aborted;i++)await new Promise(r=>setTimeout(r,5));assert.ok(signal.aborted);assert.equal(calls,0);
});
