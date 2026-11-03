import test from 'node:test';
import assert from 'node:assert/strict';
import {choosePresentation} from '../server/presentation.mjs';
import {normalizeRequest} from '../server/schema.mjs';
import {createServer} from '../server/index.mjs';
const drawing={provider:'claude',model:'claude-sonnet-5-5',reasoningEffort:'high'};
const request={message:'Why do eclipses happen?',mode:'auto',provider:'gpt',model:'gpt-6.1-sol',reasoningEffort:'low',drawing};
const response=choice=>Response.json({answers:[{name:'presentation',type:'choice',choice}]});
test('visual choice sends only submitted prompt and image presence and validates the two routes',async()=>{
  for(const choice of ['chat','draw']){
    assert.equal(await choosePresentation({...request,image:'private pixels',history:['private history'],previous:{private:true}},{getKey:async()=>'test',fetchImpl:async(_url,options)=>{
      const body=JSON.parse(options.body);
      assert.deepEqual(JSON.parse(body.input),{message:request.message,hasAttachedImage:true});
      assert.deepEqual(body.questions[0].choices.map(x=>x.value),['draw','chat']);
      return response(choice);
    }}),choice);
  }
  for(const fetchImpl of [async()=>response('edit'),async()=>new Response('',{status:401}),async()=>Response.json({answers:[{type:'refusal',name:'presentation'}]}),async()=>{throw Error('offline');}]){
    assert.equal(await choosePresentation(request,{getKey:async()=>'test',fetchImpl}),null);
  }
  assert.equal(await choosePresentation(request,{getKey:async()=>'',fetchImpl:()=>assert.fail()}),null);
});
test('presentation timeout falls back while user cancellation is preserved',async()=>{
  const keepAlive=setTimeout(()=>{},1000);
  try{
    const fetchImpl=(_url,{signal})=>new Promise((_r,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}));
    assert.equal(await choosePresentation(request,{getKey:async()=>'test',fetchImpl,timeoutMs:10}),null);
    const abort=new AbortController();abort.abort(new Error('Stop'));
    await assert.rejects(choosePresentation(request,{signal:abort.signal,getKey:()=>assert.fail()}),/Stop/);
  }finally{clearTimeout(keepAlive);}
});
test('automatic presentation requires validated independent Draw settings',()=>{
  assert.equal(normalizeRequest(request).mode,'auto');
  assert.equal(normalizeRequest({...request,model:'auto',reasoningEffort:'auto'}).model,'auto');
  for(const change of [{drawing:null},{drawing:{...drawing,model:'auto'}},{drawing:{...drawing,reasoningEffort:'ultra'}},{drawing:{...drawing,provider:'other'}},{mode:'chat'},{mode:'draw'}])assert.throws(()=>normalizeRequest({...request,...change}));
});
async function harness(t,options={}){
  const server=createServer({checkAuth:async()=>true,checkClaude:async()=>true,chooseStatus:async()=>null,...options});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
  const url=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(url+'/api/session')).json();
  const send=async(body,signal)=>fetch(url+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify(body),signal});
  return async(body,signal)=>{const r=await send(body,signal);return (await r.text()).trim().split('\n').map(JSON.parse);};
}
test('a helpful visual uses Draw settings and provider instead of Auto chat selection',async t=>{
  let seen;
  const send=await harness(t,{routePresentation:async()=>'draw',routeChat:()=>assert.fail('chat model selection must not run'),checkAuth:async()=>false,run:()=>assert.fail('wrong provider'),runClaude:async r=>{seen=r;await new Promise(resolve=>setImmediate(resolve));return{result:{reply:'An eclipse diagram'}};}});
  const events=await send({...request,model:'auto',reasoningEffort:'auto'});
  assert.equal(seen.mode,'draw');assert.equal(seen.model,drawing.model);assert.equal(seen.reasoningEffort,'high');
  assert.ok(events.some(e=>e.type==='presentation'&&e.mode==='draw'&&e.source==='decisions'));
  assert.ok(events.some(e=>e.type==='status'&&e.message==='Drawing…'));
  assert.equal(events.at(-1).mode,'draw');
});
test('text choice preserves manual chat settings and Auto model routing',async t=>{
  let seen,modelCalls=0;
  const send=await harness(t,{routePresentation:async()=>'chat',routeChat:async()=>{modelCalls++;return{provider:'gpt',model:'gpt-6-astra',reasoningEffort:'max'};},run:async r=>{seen=r;return{result:{reply:'Answer'}};}});
  await send(request);assert.equal(seen.model,'gpt-6.1-sol');assert.equal(seen.reasoningEffort,'low');assert.equal(modelCalls,0);
  const events=await send({...request,model:'auto',reasoningEffort:'auto'});
  assert.equal(seen.mode,'chat');assert.equal(seen.model,'gpt-6-astra');assert.equal(seen.reasoningEffort,'max');assert.equal(modelCalls,1);
  assert.equal(events.at(-1).mode,'chat');
});
test('invalid or unavailable presentation decisions fall back to text, never edit',async t=>{
  for(const choice of [null,'edit','bad']){
    let seen;
    const send=await harness(t,{routePresentation:async()=>choice,run:async r=>{seen=r;return{result:{reply:'Answer'}};},runEdit:()=>assert.fail()});
    const events=await send(request);assert.equal(seen.mode,'chat');
    assert.ok(events.some(e=>e.type==='presentation'&&e.source==='fallback'));
  }
});
test('explicit Draw and explicit chat bypass presentation selection',async t=>{
  let calls=0;
  const send=await harness(t,{routePresentation:()=>assert.fail(),run:async()=>{calls++;return{result:{reply:'Answer'}};}});
  for(const mode of ['draw','chat'])await send({message:'hi',mode});
  assert.equal(calls,2);
});
test('selected Draw provider must be authenticated before inference',async t=>{
  let calls=0;
  const send=await harness(t,{routePresentation:async()=>'draw',checkClaude:async()=>false,runClaude:()=>{calls++;}});
  const events=await send(request);assert.equal(calls,0);assert.equal(events.at(-1).type,'error');assert.match(events.at(-1).message,/Sign in to Claude/);
});
test('disconnect during presentation cannot start inference',async t=>{
  let started,decisionSignal,calls=0;
  const entered=new Promise(r=>started=r);
  const send=await harness(t,{routePresentation:(_r,{signal})=>{decisionSignal=signal;started();return new Promise(resolve=>signal.addEventListener('abort',()=>resolve('draw'),{once:true}));},run:()=>{calls++;},runClaude:()=>{calls++;}});
  const abort=new AbortController();const pending=send(request,abort.signal);await entered;abort.abort();await assert.rejects(pending);
  for(let i=0;i<20&&!decisionSignal.aborted;i++)await new Promise(r=>setTimeout(r,5));
  assert.ok(decisionSignal.aborted);assert.equal(calls,0);
});
