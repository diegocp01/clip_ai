import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseSignalPattern,createSignalDirector} from '../server/signal-pattern.mjs';
import {createServer} from '../server/index.mjs';
const answer=(choice,motion='follow')=>Response.json({answers:[{type:'choice',name:'signal_pattern',choice},{type:'choice',name:'signal_motion',choice:motion}]});
test('signal Decisions receives only coarse state and accepts only predefined shapes',async()=>{
  for(const pattern of ['line','eyes','wave']){
    assert.deepEqual(await chooseSignalPattern('ready',{getKey:async()=>'test',fetchImpl:async(_url,options)=>{
      const body=JSON.parse(options.body);
      assert.deepEqual(JSON.parse(body.input),{state:'ready'});
      assert.deepEqual(body.questions[0].choices.map(x=>x.value),['line','eyes','wave']);
      assert.deepEqual(body.questions[1].choices.map(x=>x.value),['follow','wander','drift_left','drift_right']);
      return answer(pattern);
    }}),{pattern,motion:'follow'});
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
  assert.deepEqual(await director('working'),{pattern:'line',motion:'follow',source:'local'});
  assert.equal(calls,1);resolve({pattern:'eyes',motion:'wander'});
  assert.deepEqual(await first,{pattern:'eyes',motion:'wander',source:'decisions'});
  assert.equal((await director('speaking')).pattern,'eyes');assert.equal(calls,1);
  now+=30001;const next=director('working');await Promise.resolve();resolve(null);await next;
  await director('ready');assert.equal(calls,2);
  await assert.rejects(director('untrusted'),/Invalid/);
});
test('signal HTTP requires local session and rejects extra/private input before selection',async t=>{
  const states=[];
  const server=createServer({directSignal:async state=>{states.push(state);return {pattern:'eyes',motion:'wander',source:'decisions'};}});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
  const base=`http://127.0.0.1:${server.address().port}`;
  const {token}=await(await fetch(base+'/api/session')).json();
  const send=(body,auth=token)=>fetch(base+'/api/signal',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':auth},body:JSON.stringify(body)});
  assert.equal((await send({state:'ready'},'bad')).status,403);
  assert.equal((await send({state:'ready',draft:'private'})).status,400);
  assert.equal((await send({state:'unknown'})).status,400);
  assert.equal((await send({state:'x'.repeat(200)})).status,413);
  assert.deepEqual(states,[]);
  assert.deepEqual(await(await send({state:'ready'})).json(),{pattern:'eyes',motion:'wander',source:'decisions'});
  assert.deepEqual(states,['ready']);
});

test('Decisions can combine any safe shape with independent or mouse-following motion',async()=>{
 for(const shape of ['line','eyes','wave'])for(const motion of ['follow','wander','drift_left','drift_right']){
  assert.deepEqual(await chooseSignalPattern('ready',{getKey:async()=>'test',fetchImpl:async()=>answer(shape,motion)}),{pattern:shape,motion});
 }
 for(const payload of [
  {answers:[{type:'choice',name:'signal_pattern',choice:'eyes'}]},
  {answers:[{type:'choice',name:'signal_pattern',choice:'eyes'},{type:'choice',name:'signal_motion',choice:'execute code'}]},
  {answers:[{type:'choice',name:'signal_pattern',choice:'eyes'},{type:'refusal',name:'signal_motion'}]}
 ])assert.equal(await chooseSignalPattern('ready',{getKey:async()=>'test',fetchImpl:async()=>Response.json(payload)}),null);
});
test('a bad motion choice preserves the last safe behavior instead of partly applying it',async()=>{
 let now=1,choice={pattern:'eyes',motion:'wander'};
 const director=createSignalDirector({now:()=>now,choose:async()=>choice});
 const original=await director('ready');now+=30001;choice={pattern:'wave',motion:'bad'};
 assert.deepEqual(await director('working'),original);
});
