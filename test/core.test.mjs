import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readdir } from 'node:fs/promises';
import { normalizeRequest,assertResult,decodeImage } from '../server/schema.mjs';
import { codexEnvironment,generate,sdkOptions } from '../server/codex.mjs';
import { createServer } from '../server/index.mjs';

const result={title:'Water',reply:'A schematic water molecule.',cards:[],diagram:{nodes:[],links:[]},scene:{objects:[{id:'oxygen',label:'Oxygen',description:'O',shape:'sphere',color:'#E88570',position:[0,0,0],scale:[1,1,1],rotation:[0,0,0]}]}};
test('requests reject unexpected fields, large history, invalid speed and executable scene payloads',()=>{
  assert.equal(normalizeRequest({message:'hello'}).tier,'fast');
  for(const body of [{message:' '},{message:'x',path:'/etc/passwd'},{message:'x',tier:'turbo'},{message:'x',history:Array(13).fill({role:'user',content:'x'})}])assert.throws(()=>normalizeRequest(body));
  assert.throws(()=>assertResult({...result,html:'<script/>'}));
  assert.throws(()=>assertResult({...result,scene:{objects:[{...result.scene.objects[0],shape:'javascript'}]}}));
  assert.throws(()=>assertResult({...result,diagram:{nodes:[],links:[{from:'x',to:'y',label:''}]}}));
});
test('images are bounded and verified by magic bytes',()=>{
  assert.throws(()=>decodeImage('data:image/png;base64,PHNjcmlwdD4='));
  assert.throws(()=>decodeImage('https://example.test/a.png'));
  assert.equal(decodeImage('data:image/png;base64,iVBORw0KGgo=').extension,'png');
});
test('SDK inherits login environment without API keys or personal configuration',()=>{
  assert.deepEqual(codexEnvironment({HOME:'/home/a',PATH:'/bin',OPENAI_API_KEY:'secret',CODEX_API_KEY:'secret',OTHER_SECRET:'secret'}),{HOME:'/home/a',PATH:'/bin'});
  assert.equal(sdkOptions().config.service_tier,'fast');
  assert.equal(sdkOptions().config.features.fast_mode,true);
  assert.throws(()=>sdkOptions('ultrafast'),/Terra/);
  assert.equal(sdkOptions('standard').config.service_tier,undefined);
  assert.equal(sdkOptions().config.features.shell_tool,false);
});
test('SDK provider forwards selected model, schema, image and cancellation; cleans temporary data',async()=>{
  let seen;
  const controller=new AbortController();
  class FakeCodex{constructor(opts){seen={opts};}startThread(opts){seen.thread=opts;return {runStreamed:async(input,options)=>{seen.input=input;seen.options=options;return {events:(async function*(){yield {type:'item.completed',item:{type:'agent_message',text:JSON.stringify(result)}};yield {type:'turn.completed',usage:{output_tokens:10}};})()};}};}}
  const out=await generate(normalizeRequest({message:'water',tier:'fast',image:'data:image/png;base64,iVBORw0KGgo='}),{signal:controller.signal,transport:null,CodexClass:FakeCodex});
  assert.equal(out.result.title,'Water');assert.equal(out.requestedTier,'fast');
  assert.equal(seen.thread.model,'gpt-6.1-terra');assert.equal(seen.thread.sandboxMode,'read-only');
  assert.equal(seen.thread.modelReasoningEffort,'low');
  assert.equal(out.reasoningEffort,'low');
  assert.equal(seen.options.signal,controller.signal);assert.equal(seen.input[1].type,'local_image');
  await assert.rejects(readdir(seen.thread.workingDirectory),{code:'ENOENT'});
});
test('SDK failure never fabricates a result',async()=>{
  class Failure{startThread(){return{runStreamed:async()=>({events:(async function*(){yield{type:'turn.failed',error:{message:'Tier unavailable'}};})()})};}}
  await assert.rejects(generate(normalizeRequest({message:'x'}),{transport:null,CodexClass:Failure}),/Tier unavailable/);
});
test('local HTTP server protects inference and streams validated requests',async t=>{
  let calls=0;
  const server=createServer({checkAuth:async()=>true,run:async()=>{calls++;return{result,usage:null,elapsedMs:1,model:'gpt-6.1-terra',requestedTier:'standard'};}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`;
  const headers={'Content-Type':'application/json'};
  assert.equal((await fetch(url+'/api/chat',{method:'POST',headers,body:'{"message":"x"}'})).status,403);
  assert.equal((await fetch(url+'/api/session',{headers:{Origin:'https://untrusted.example'}})).status,403);
  const badHostStatus=await new Promise((resolve,reject)=>{http.get(url+'/api/session',{headers:{Host:'untrusted.example'}},res=>{res.resume();resolve(res.statusCode);}).on('error',reject);});
  assert.equal(badHostStatus,403);
  const {token}=await(await fetch(url+'/api/session')).json();headers['X-Clippy-Session']=token;
  assert.equal((await fetch(url+'/api/chat',{method:'POST',headers,body:'{"message":""}'})).status,400);
  const response=await fetch(url+'/api/chat',{method:'POST',headers,body:'{"message":"water"}'});
  assert.equal(response.status,200);assert.equal(JSON.parse((await response.text()).trim()).result.title,'Water');assert.equal(calls,1);
  assert.equal((await fetch(url+'/%2eenv')).status,403);
});
test('disconnect cancels active model generation',async t=>{
  let cancellation;
  const cancelled=new Promise(resolve=>cancellation=resolve);
  const server=createServer({checkAuth:async()=>true,run:async(_req,{signal,onStatus})=>{onStatus('working');await new Promise(resolve=>signal.addEventListener('abort',()=>{cancellation();resolve();},{once:true}));throw new Error('cancelled');}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(url+'/api/session')).json();const controller=new AbortController();
  const res=await fetch(url+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:'{"message":"x"}',signal:controller.signal});
  const reader=res.body.getReader();await reader.read();controller.abort();
  await Promise.race([cancelled,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('not cancelled')),2000);timer.unref();})]);
});
