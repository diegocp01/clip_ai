import test from 'node:test';
import assert from 'node:assert/strict';
import { chooseLoadingStatus,runWithLoadingStatus } from '../server/decisions.mjs';
import { createServer } from '../server/index.mjs';

const decision = choice => Response.json({answers:[{type:'choice',name:'loading_activity',choice}]});
test('Decisions classifies submitted text without forwarding screenshots, history, or credentials in the body',async()=>{
  let sent;
  const label=await chooseLoadingStatus({message:'hi',image:'private image',history:['private history']},{getKey:async()=>'test-secret',fetchImpl:async(url,options)=>{
    assert.equal(url,'https://api.openai.com/v1/decisions');
    sent=JSON.parse(options.body);assert.equal(options.headers.Authorization,'Bearer test-secret');
    return decision('reply');
  }});
  assert.equal(label,'Replying…');assert.equal(sent.model,'gpt-6-luna');
  assert.deepEqual(JSON.parse(sent.input),{message:'hi',hasAttachedImage:true});
  assert.equal(sent.questions[0].type,'choice');
  assert.ok(!JSON.stringify(sent).includes('test-secret'));
});
test('Decisions failures, refusal, unknown labels, and absent keys safely fall back',async()=>{
  for (const fetchImpl of [async()=>new Response('private detail',{status:401}),async()=>{throw Error('secret detail');},async()=>decision('<script>'),async()=>Response.json({answers:[{type:'refusal',name:'loading_activity'}]}),async()=>Response.json({answers:null})]) {
    assert.equal(await chooseLoadingStatus({message:'hi'},{getKey:async()=>'secret',fetchImpl}),null);
  }
  assert.equal(await chooseLoadingStatus({message:'hi'},{getKey:async()=>'',fetchImpl:()=>assert.fail('must not fetch without key')}),null);
});
test('Decisions timeout and cancellation abort the network request',async()=>{
  const keepAlive=setTimeout(()=>{},1000);
  try {
    let aborted=false;
    const fetchImpl=(_url,{signal})=>new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{aborted=true;reject(signal.reason);},{once:true}));
    assert.equal(await chooseLoadingStatus({message:'hi'},{getKey:async()=>'secret',fetchImpl,timeoutMs:10}),null);
    assert.ok(aborted);
    const controller=new AbortController();controller.abort();
    assert.equal(await chooseLoadingStatus({message:'hi'},{signal:controller.signal,getKey:()=>assert.fail('already cancelled')}),null);
  } finally {clearTimeout(keepAlive);}
});
test('topic status replaces generic provider wording without delaying generation',async()=>{
  const statuses=[];let finishDecision;let started=false;
  const choice=new Promise(resolve=>finishDecision=resolve);
  const result=await runWithLoadingStatus(async(_request,{onStatus,onPreview})=>{
    started=true;onStatus('Drawing with model…');finishDecision('Replying…');
    await new Promise(resolve=>setImmediate(resolve));onPreview({title:'Hello'});return 'answer';
  },{message:'hi'},{onStatus:s=>statuses.push(s),onPreview:()=>{}},{chooseStatus:()=>{assert.ok(started);return choice;}});
  assert.equal(result,'answer');assert.deepEqual(statuses,['Thinking…','Replying…']);
});
test('a late decision cannot delay or overwrite a completed response',async()=>{
  const statuses=[];let finishDecision,decisionSignal;
  const pending=new Promise(resolve=>finishDecision=resolve);
  const result=await runWithLoadingStatus(async()=>42,{message:'hi'},{onStatus:s=>statuses.push(s)},
    {chooseStatus:(_req,{signal})=>{decisionSignal=signal;return pending;}});
  assert.equal(result,42);assert.ok(decisionSignal.aborted);
  finishDecision('Drawing…');await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(statuses,['Thinking…']);
});
test('a cancelled generation never receives a late loading label',async()=>{
  const controller=new AbortController(),statuses=[];
  let finishDecision;
  await assert.rejects(runWithLoadingStatus(async()=>{controller.abort();throw Error('cancelled');},{message:'hi'},
    {signal:controller.signal,onStatus:s=>statuses.push(s)},
    {chooseStatus:()=>new Promise(resolve=>finishDecision=resolve)}),/cancelled/);
  finishDecision('Replying…');await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(statuses,['Thinking…']);
});

for (const provider of ['gpt','claude']) test(`${provider} HTTP stream keeps the chosen activity through previews`,async t=>{
  let calls=0;
  const runner=async(_request,{onStatus,onPreview})=>{
    onStatus('Drawing with model…');
    await new Promise(resolve=>setImmediate(resolve));
    onPreview({title:'Hello'});return {result:{reply:'Hi!'}};
  };
  const server=createServer({run:runner,runClaude:runner,checkAuth:async()=>true,checkClaude:async()=>true,
    chooseStatus:async request=>{calls++;assert.equal(request.message,'hi');return 'Replying…';}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>server.close());
  const url=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(url+'/api/session')).json();
  const response=await fetch(url+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'hi',provider})});
  const events=(await response.text()).trim().split('\n').map(line=>JSON.parse(line));
  assert.deepEqual(events.map(e=>e.type),['status','status','preview','result']);
  assert.deepEqual(events.filter(e=>e.type==='status').map(e=>e.message),['Thinking…','Replying…']);
  assert.equal(events.at(-1).result.reply,'Hi!');assert.equal(calls,1);
});
