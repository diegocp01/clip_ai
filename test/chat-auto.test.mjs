import test from 'node:test';
import assert from 'node:assert/strict';
import {autoModels,autoChoices,chooseChatRoute,validateAutoRoute} from '../server/chat-settings.mjs';
import {normalizeRequest} from '../server/schema.mjs';
import {createServer} from '../server/index.mjs';
import {generate} from '../server/codex.mjs';

test('Auto is restricted to chat, the approved four models, and every supported effort',()=>{
  assert.deepEqual(autoModels.map(m=>m.id).sort(),['gpt-6-astra','gpt-6.1-terra','claude-opus-5-5','claude-sonnet-5-5'].sort());
  assert.equal(autoChoices.length,22);
  for(const m of autoModels)for(const effort of m.efforts)assert.equal(validateAutoRoute({model:m.id,provider:m.provider,reasoningEffort:effort}).reasoningEffort,effort);
  assert.throws(()=>validateAutoRoute({model:'gpt-6.1-sol',provider:'gpt',reasoningEffort:'low'}));
  assert.throws(()=>validateAutoRoute({model:'claude-opus-5-5',provider:'claude',reasoningEffort:'ultra'}));
  assert.throws(()=>normalizeRequest({message:'hi',model:'auto'}));
  assert.throws(()=>normalizeRequest({message:'hi',mode:'draw',model:'auto'}));
  assert.throws(()=>normalizeRequest({message:'hi',mode:'chat',model:'auto',reasoningEffort:'low'}));
  assert.equal(normalizeRequest({message:'hi',mode:'chat',model:'auto'}).reasoningEffort,'auto');
  assert.equal(normalizeRequest({message:'hi',mode:'chat',model:'gpt-6-astra',reasoningEffort:'ultra'}).reasoningEffort,'ultra');
  assert.throws(()=>normalizeRequest({message:'hi',mode:'draw',model:'gpt-6-astra',reasoningEffort:'ultra'}));
});
test('Decisions chooses a validated joint model/effort without image or history disclosure',async()=>{
  const route=await chooseChatRoute({message:'hi',image:'private screenshot',history:['private history']},{getKey:async()=>'secret',fetchImpl:async(url,opts)=>{
    assert.equal(url,'https://api.openai.com/v1/decisions');
    const body=JSON.parse(opts.body);
    assert.deepEqual(JSON.parse(body.input),{message:'hi',hasAttachedImage:true});
    assert.equal(body.questions[0].choices.length,22);
    return Response.json({answers:[{name:'chat_route',type:'choice',choice:'gpt-6-astra:ultra'}]});
  }});
  assert.equal(route.model,'gpt-6-astra');assert.equal(route.reasoningEffort,'ultra');
});
test('routing failures never invent a model or effort',async()=>{
  for(const fetchImpl of [async()=>new Response('private',{status:401}),async()=>Response.json({answers:[{name:'chat_route',type:'refusal'}]}),async()=>Response.json({answers:[{name:'chat_route',type:'choice',choice:'claude-opus-5-5:ultra'}]}),async()=>{throw Error('private');}]) {
    await assert.rejects(chooseChatRoute({message:'hi'},{getKey:async()=>'secret',fetchImpl}),/Auto could not choose/);
  }
  await assert.rejects(chooseChatRoute({message:'hi'},{getKey:async()=>'',fetchImpl:()=>assert.fail()}),/Auto could not choose/);
  const controller=new AbortController();controller.abort(new Error('cancelled'));
  await assert.rejects(chooseChatRoute({message:'hi'},{signal:controller.signal,getKey:()=>assert.fail()}),/cancelled/);
});
test('route timeout aborts the API and fails explicitly',async()=>{
  const keepAlive=setTimeout(()=>{},1000);let aborted=false;
  try {await assert.rejects(chooseChatRoute({message:'hi'},{getKey:async()=>'secret',timeoutMs:10,fetchImpl:(_url,{signal})=>new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{aborted=true;reject(signal.reason);},{once:true}))}),/Auto could not choose/);assert.ok(aborted);}
  finally{clearTimeout(keepAlive);}
});
async function harness(t,options={}) {
  const server=createServer({checkAuth:async()=>true,checkClaude:async()=>true,chooseStatus:async()=>null,...options});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(url+'/api/session')).json();
  return async body=>{const response=await fetch(url+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify(body)});
    return {status:response.status,events:(await response.text()).trim().split('\n').map(line=>JSON.parse(line))};};
}
test('all 22 Auto model/effort pairs reach the correct backend unchanged',async t=>{
  let selected,seen,calls=0;
  const run=provider=>async(request)=>{calls++;seen=request;assert.equal(request.provider,provider);return{result:{reply:'Hi'}};};
  const send=await harness(t,{routeChat:async()=>selected,run:run('gpt'),runClaude:run('claude')});
  for(const model of autoModels)for(const reasoningEffort of model.efforts) {
    selected={model:model.id,provider:model.provider,reasoningEffort};
    const {events}=await send({message:'hi',mode:'chat',model:'auto'});
    assert.equal(seen.model,model.id);assert.equal(seen.reasoningEffort,reasoningEffort);
    assert.equal(events.find(e=>e.type==='route').model,model.id);
    assert.equal(events.at(-1).type,'result');
  }
  assert.equal(calls,22);
});
test('Draw and manual chat bypass Auto, and routing failure never starts inference',async t=>{
  let routed=0,calls=0;
  const send=await harness(t,{routeChat:async()=>{routed++;throw Error('Auto unavailable');},run:async req=>{calls++;return{result:{reply:req.mode}};}});
  await send({message:'draw water',mode:'draw'});await send({message:'hi',mode:'chat',model:'gpt-6.1-terra'});
  assert.equal(calls,2);assert.equal(routed,0);
  const {events}=await send({message:'hi',mode:'chat',model:'auto'});
  assert.equal(events.at(-1).type,'error');assert.equal(calls,2);assert.equal(routed,1);
});
test('Auto checks the chosen provider sign-in and rejects invalid injected routes',async t=>{
  let selected={model:'claude-opus-5-5',provider:'claude',reasoningEffort:'max'};
  const send=await harness(t,{routeChat:async()=>selected,checkClaude:async()=>false,run:()=>assert.fail('no fallback'),runClaude:()=>assert.fail('not signed in')});
  assert.match((await send({message:'hi',mode:'chat',model:'auto'})).events.at(-1).message,/Claude is not signed in/);
  selected={model:'gpt-6-luna',provider:'gpt',reasoningEffort:'low'};
  assert.match((await send({message:'hi',mode:'chat',model:'auto'})).events.at(-1).message,/unsupported/);
});
test('manual GPT chat forwards Ultra and chat instructions without visual previews',async()=>{
  let captured;
  const result={title:'Hello',reply:'Hi',cards:[],annotations:[],diagram:{nodes:[],links:[]},scene:{objects:[]}};
  await generate(normalizeRequest({message:'hi',mode:'chat',model:'gpt-6-astra',reasoningEffort:'ultra'}),{
    transport:async options=>{captured=options;options.onText(JSON.stringify(result));return{raw:JSON.stringify(result)};},onPreview:()=>assert.fail('chat has no visual preview')});
  assert.equal(captured.reasoningEffort,'ultra');assert.match(captured.input[0].text,/This is chat, not Draw/);
});

test('disconnect during routing aborts Decisions and never starts a model',async t=>{
  let observedAbort;
  const aborted=new Promise(resolve=>observedAbort=resolve);
  const server=createServer({routeChat:(_req,{signal})=>new Promise((_resolve,reject)=>{
    signal.addEventListener('abort',()=>{observedAbort();reject(signal.reason);},{once:true});
  }),run:()=>assert.fail('cancelled before inference'),runClaude:()=>assert.fail('cancelled before inference')});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(url+'/api/session')).json();
  const controller=new AbortController();
  const response=await fetch(url+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'hi',mode:'chat',model:'auto'}),signal:controller.signal});
  await response.body.getReader().read();controller.abort();
  await Promise.race([aborted,new Promise((_resolve,reject)=>{const timer=setTimeout(()=>reject(Error('routing did not abort')),1500);timer.unref();})]);
});

test('provider Auto exposes only its two eligible models and every supported effort',async()=>{
 for(const provider of ['gpt','claude']){
  const eligible=autoModels.filter(m=>m.provider===provider);
  const chosen=eligible.at(-1),effort=chosen.efforts.at(-1);
  const route=await chooseChatRoute({message:'Explain a difficult idea',provider,autoScope:provider},{getKey:async()=>'secret',fetchImpl:async(_url,opts)=>{
   const choices=JSON.parse(opts.body).questions[0].choices;
   assert.equal(choices.length,provider==='gpt'?12:10);
   assert.deepEqual(choices.map(c=>c.value).sort(),eligible.flatMap(m=>m.efforts.map(e=>`${m.id}:${e}`)).sort());
   return Response.json({answers:[{name:'chat_route',type:'choice',choice:`${chosen.id}:${effort}`}]});
  }});
  assert.equal(route.provider,provider);assert.equal(route.reasoningEffort,effort);
 }
});
test('scoped Auto rejects a decision from the other provider',async()=>{
 await assert.rejects(chooseChatRoute({message:'hi',autoScope:'gpt'},{getKey:async()=>'secret',fetchImpl:async()=>Response.json({answers:[{name:'chat_route',type:'choice',choice:'claude-opus-5-5:max'}]})}),/could not choose/);
 assert.throws(()=>validateAutoRoute({provider:'gpt',model:'gpt-6-astra',reasoningEffort:'ultra'},'claude'),/unsupported/);
});
test('Auto scope validates at the request boundary and legacy Auto still covers all four',()=>{
 assert.equal(normalizeRequest({message:'hi',mode:'chat',model:'auto'}).autoScope,'all');
 assert.equal(normalizeRequest({message:'hi',mode:'chat',provider:'claude',model:'auto',autoScope:'claude'}).autoScope,'claude');
 for(const request of [
  {mode:'chat',model:'auto',autoScope:'claude',provider:'gpt'},
  {mode:'chat',model:'auto',autoScope:'unknown'},
  {mode:'chat',model:'gpt-6-astra',autoScope:'gpt'},
  {mode:'draw',autoScope:'gpt'}
 ])assert.throws(()=>normalizeRequest({message:'hi',...request}));
});
test('HTTP scoped Auto blocks cross-provider injected routes before any inference',async t=>{
 let calls=0;
 const send=await harness(t,{routeChat:async request=>{assert.equal(request.autoScope,'gpt');return{provider:'claude',model:'claude-opus-5-5',reasoningEffort:'max'};},run:()=>{calls++;},runClaude:()=>{calls++;}});
 const {events}=await send({message:'hi',mode:'chat',provider:'gpt',model:'auto',autoScope:'gpt'});
 assert.equal(events.at(-1).type,'error');assert.equal(calls,0);
});
test('scoped Auto survives presentation routing and never changes independent Draw settings',async t=>{
 let presentation='chat',seen;
 const send=await harness(t,{routePresentation:async()=>presentation,routeChat:async request=>{
  assert.equal(request.autoScope,'claude');return{provider:'claude',model:'claude-sonnet-5-5',reasoningEffort:'max'};
 },runClaude:async req=>{seen=req;return{result:{reply:'answer'}};},run:async req=>{seen=req;return{result:{reply:'drawing'}};}});
 const request={message:'Explain this',mode:'auto',provider:'claude',model:'auto',autoScope:'claude',drawing:{provider:'gpt',model:'gpt-6.1-terra',reasoningEffort:'low'}};
 assert.equal((await send(request)).events.at(-1).type,'result');assert.equal(seen.provider,'claude');assert.equal(seen.reasoningEffort,'max');
 presentation='draw';await send(request);assert.equal(seen.provider,'gpt');assert.equal(seen.model,'gpt-6.1-terra');assert.equal(seen.reasoningEffort,'low');assert.equal(seen.autoScope,null);
});
