import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseSignalPattern,createSignalDirector} from '../server/signal-pattern.mjs';
import {createServer} from '../server/index.mjs';
const answer=choice=>Response.json({answers:[{type:'choice',name:'signal_pattern',choice}]});
test('signal Decisions receives only coarse state and accepts only predefined shapes',async()=>{
  for(const pattern of ['line','eyes','wave']){
    assert.equal(await chooseSignalPattern('ready',{getKey:async()=>'test',fetchImpl:async(_url,options)=>{
      const body=JSON.parse(options.body);
      assert.deepEqual(JSON.parse(body.input),{state:'ready'});
      assert.deepEqual(body.questions[0].choices.map(x=>x.value),['line','eyes','wave']);
      return answer(pattern);
    }}),pattern);
  }
  for(const fetchImpl of [async()=>answer('code()'),async()=>new Response('',{status:401}),async()=>Response.json({answers:[{type:'refusal'}]}),async()=>{throw Error('offline');}])
    assert.equal(await chooseSignalPattern('working',{getKey:async()=>'test',fetchImpl}),null);
  assert.equal(await chooseSignalPattern('ready',{getKey:async()=>'',fetchImpl:()=>assert.fail()}),null);
  assert.equal(await chooseSignalPattern('private draft',{getKey:()=>assert.fail()}),null);
});
test('signal timeout aborts its bounded cosmetic request',async()=>{
  const keepAlive=setTimeout(()=>{},1000);
  try{
    assert.equal(await chooseSignalPattern('ready',{getKey:async()=>'test',timeoutMs:10,fetchImpl:(_url,{signal})=>new Promise((_r,reject)=>signal.addEventListener('abort',()=>reject(signal.reason),{once:true}))}),null);
  }finally{clearTimeout(keepAlive);}
});
test('rapid opening and state changes cannot multiply Decisions calls, including failure',async()=>{
  let now=1,calls=0,resolve;
  const director=createSignalDirector({now:()=>now,choose:()=>{calls++;return new Promise(r=>resolve=r);}});
  const first=director('ready');await Promise.resolve();
  assert.deepEqual(await director('working'),{pattern:'line',source:'local'});
  assert.equal(calls,1);resolve('eyes');
  assert.deepEqual(await first,{pattern:'eyes',source:'decisions'});
  assert.equal((await director('speaking')).pattern,'eyes');assert.equal(calls,1);
  now+=30001;const next=director('working');await Promise.resolve();resolve(null);await next;
  await director('ready');assert.equal(calls,2);
  await assert.rejects(director('untrusted'),/Invalid/);
});
test('signal HTTP requires local session and rejects extra/private input before selection',async t=>{
  const states=[];
  const server=createServer({directSignal:async state=>{states.push(state);return {pattern:'eyes',source:'decisions'};}});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
  const base=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(base+'/api/session')).json();
  const send=(body,auth=token)=>fetch(base+'/api/signal',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':auth},body:JSON.stringify(body)});
  assert.equal((await send({state:'ready'},'bad')).status,403);
  assert.equal((await send({state:'ready',draft:'private'})).status,400);
  assert.equal((await send({state:'unknown'})).status,400);
  assert.equal((await send({state:'x'.repeat(200)})).status,413);
  assert.deepEqual(states,[]);
  assert.deepEqual(await(await send({state:'ready'})).json(),{pattern:'eyes',source:'decisions'});
  assert.deepEqual(states,['ready']);
});
