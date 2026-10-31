import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseScreenContext,normalizeScreenRequest} from '../server/screen-context.mjs';
import {createServer} from '../server/index.mjs';
const body={message:'What is wrong with this error on my screen?',hasImage:false};
const response=choice=>Response.json({answers:[{name:'screen_context',type:'choice',choice}]});
test('screen decision discloses only submitted prompt and accepts only capture',async()=>{
 for(const choice of ['capture','skip','unknown'])assert.equal(await chooseScreenContext({...body,image:'private pixels',selectedText:'private text',history:'private history'},{getKey:async()=>'test',fetchImpl:async(_url,options)=>{
  const data=JSON.parse(options.body);assert.deepEqual(JSON.parse(data.input),{message:body.message});return response(choice);
 }}),choice==='capture');
 assert.equal(await chooseScreenContext({...body,hasImage:true},{getKey:()=>assert.fail()}),false);
 for(const fetchImpl of [async()=>new Response('',{status:403}),async()=>{throw Error('offline');},async()=>Response.json({answers:[{name:'screen_context',type:'refusal'}]})])assert.equal(await chooseScreenContext(body,{getKey:async()=>'test',fetchImpl}),false);
 assert.equal(await chooseScreenContext(body,{getKey:async()=>''}),false);
});
test('screen choice times out to no capture and propagates user cancellation',async()=>{
 const alive=setTimeout(()=>{},1000);
 try{
  assert.equal(await chooseScreenContext(body,{getKey:async()=>'test',timeoutMs:10,fetchImpl:(_u,{signal})=>new Promise((_r,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}))}),false);
  const c=new AbortController();c.abort(Error('Stop'));await assert.rejects(chooseScreenContext(body,{signal:c.signal}),/Stop/);
 }finally{clearTimeout(alive);}
});
test('screen preflight rejects extra data and malformed prompt metadata',()=>{
 for(const value of [null,[],{...body,image:'pixels'},{...body,message:''},{...body,message:'x'.repeat(6001)},{...body,hasImage:'false'}])assert.throws(()=>normalizeScreenRequest(value));
});
async function harness(t,routeScreen){
 const server=createServer({routeScreen});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
 const base=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(base+'/api/session')).json();
 return (value,signal,authorized=true)=>fetch(base+'/api/screen-context',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':authorized?token:''},body:JSON.stringify(value),signal});
}
test('screen preflight requires session, bypasses existing attachments and fails closed on invalid routes',async t=>{
 let count=0;const send=await harness(t,async()=>{count++;return true;});
 assert.equal((await send(body,undefined,false)).status,403);assert.equal(count,0);
 assert.deepEqual(await(await send({...body,hasImage:true})).json(),{capture:false});assert.equal(count,0);
 assert.deepEqual(await(await send(body)).json(),{capture:true});assert.equal(count,1);
 assert.deepEqual(await(await send({...body,image:'private'})).json(),{capture:false});assert.equal(count,1);
 const invalid=await harness(t,async()=>'capture');assert.deepEqual(await(await invalid(body)).json(),{capture:false});
});
test('disconnect aborts the screen decision before an instruction to capture returns',async t=>{
 let entered,signal;const started=new Promise(r=>entered=r);const send=await harness(t,(_b,options)=>{signal=options.signal;entered();return new Promise(r=>signal.addEventListener('abort',()=>r(true),{once:true}));});
 const c=new AbortController();const pending=send(body,c.signal);await started;c.abort();await assert.rejects(pending);
 for(let i=0;i<20&&!signal.aborted;i++)await new Promise(r=>setTimeout(r,5));assert.equal(signal.aborted,true);
});
