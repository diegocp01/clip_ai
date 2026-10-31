import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeComparison,runComparison} from '../server/comparison.mjs';
import {createServer} from '../server/index.mjs';
const image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=';
const prompt={task:'chat',message:'Explain the screenshot',image,settings:{gpt:{model:'gpt-6.1-sol',reasoningEffort:'low'},claude:{model:'claude-sonnet-5-5',reasoningEffort:'medium'}}};
const reply=text=>({result:{reply:text},model:'test-model',reasoningEffort:'low'});
const defaults={checkAuth:async()=>true,checkClaude:async()=>true,routeEdit:async()=>'proofread'};
test('Both normalizes identical image/text with independent explicit models and no history or drawing',()=>{
 const r=normalizeComparison(prompt);
 for(const p of ['gpt','claude']){assert.equal(r.requests[p].mode,'chat');assert.equal(r.requests[p].image,image);assert.equal(r.requests[p].message,prompt.message);assert.deepEqual(r.requests[p].history,[]);assert.equal(r.requests[p].previous,null);}
 assert.equal(r.requests.claude.reasoningEffort,'medium');
 for(const change of [{task:'draw'},{task:'voice'},{mode:'draw'},{provider:'both'},{history:[]},{settings:{gpt:{model:'auto'}}},{settings:{claude:{model:'gpt-6.1-sol'}}},{settings:{gpt:{tools:['x']}}},{image:'data:image/png;base64,aGVsbG8='}])assert.throws(()=>normalizeComparison({...prompt,...change}));
 assert.equal(normalizeComparison({task:'edit',text:'i is here',action:'auto'}).action,'auto');
 assert.throws(()=>normalizeComparison({task:'edit',text:'x',action:'proofread',image}));
});
test('both providers start concurrently and results arrive independently, never routed to Draw',async()=>{
 const events=[],started=[];let finishGpt;
 const pending=runComparison(normalizeComparison(prompt),{...defaults,signal:new AbortController().signal,send:e=>events.push(e),run:async r=>{started.push(r.provider);return new Promise(resolve=>finishGpt=()=>resolve(reply('Codex answer')));},runClaude:async r=>{started.push(r.provider);return reply('Claude answer');}});
 await new Promise(r=>setImmediate(r));assert.deepEqual(started,['gpt','claude']);
 assert.equal(events.find(e=>e.type==='comparison-result').provider,'claude');
 finishGpt();await pending;
 assert.deepEqual(events.filter(e=>e.type==='comparison-result').map(e=>e.text),['Claude answer','Codex answer']);assert.equal(events.at(-1).type,'comparison-complete');
});
test('one sign-in or provider failure retains the other answer',async()=>{
 for(const options of [{checkClaude:async()=>false},{runClaude:async()=>{throw Error('Claude failed');}}]){
  const events=[];await runComparison(normalizeComparison(prompt),{...defaults,signal:new AbortController().signal,send:e=>events.push(e),run:async()=>reply('Good answer'),runClaude:async()=>reply('unused'),...options});
  assert.ok(events.some(e=>e.type==='comparison-result'&&e.provider==='gpt'));
  assert.ok(events.some(e=>e.type==='comparison-error'&&e.provider==='claude'));
 }
});
test('automatic proofread comparison chooses one action and gives both the same selected text',async()=>{
 const requests=[],events=[];let decisions=0;
 await runComparison(normalizeComparison({task:'edit',text:'i is ready',action:'auto'}),{...defaults,routeEdit:async()=>{decisions++;return 'rewrite';},runEdit:async r=>{requests.push(r);return{result:{text:`${r.provider} edit`}};},signal:new AbortController().signal,send:e=>events.push(e)});
 assert.equal(decisions,1);assert.deepEqual(requests.map(r=>[r.text,r.action]),[['i is ready','rewrite'],['i is ready','rewrite']]);assert.equal(events.filter(e=>e.type==='comparison-result').length,2);
});
test('Stop aborts both providers and suppresses late answers',async()=>{
 const c=new AbortController(),events=[],signals=[];let count=0,ready;
 const started=new Promise(r=>ready=r);
 const run=async(_r,{signal})=>{signals.push(signal);if(++count===2)ready();return new Promise(resolve=>signal.addEventListener('abort',()=>resolve(reply('late')),{once:true}));};
 const pending=runComparison(normalizeComparison(prompt),{...defaults,run,runClaude:run,signal:c.signal,send:e=>events.push(e)});
 await started;c.abort();await assert.rejects(pending);assert.ok(signals.every(s=>s.aborted));assert.equal(events.some(e=>e.type==='comparison-result'||e.type==='comparison-complete'),false);
});
async function harness(t,options={}) {
 const server=createServer({...defaults,...options});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
 const base=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(base+'/api/session')).json();
 return {send:(body,authorized=true,signal)=>fetch(base+'/api/compare',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':authorized?token:''},body:JSON.stringify(body),signal}),status:()=>fetch(base+'/api/status?provider=both')};
}
test('comparison HTTP authenticates, rejects Draw/voice and streams both answers',async t=>{
 const h=await harness(t,{run:async()=>reply('A'),runClaude:async()=>reply('B')});
 assert.equal((await h.send(prompt,false)).status,403);
 for(const task of ['draw','voice'])assert.equal((await h.send({...prompt,task})).status,400);
 const response=await h.send(prompt);assert.equal(response.status,200);
 const events=(await response.text()).trim().split('\n').map(JSON.parse);
 assert.equal(events.filter(e=>e.type==='comparison-result').length,2);
 assert.equal((await(await h.status()).json()).provider,'both');
});
test('comparison reserves both slots and disconnect aborts both provider operations',async t=>{
 let count=0,started;const ready=new Promise(r=>started=r),signals=[];
 const run=(_r,{signal})=>{signals.push(signal);if(++count===2)started();return new Promise(resolve=>signal.addEventListener('abort',()=>resolve(reply('late')),{once:true}));};
 const h=await harness(t,{run,runClaude:run});const c=new AbortController();const pending=h.send(prompt,true,c.signal);await ready;
 assert.equal((await h.send(prompt)).status,429);c.abort();try{await(await pending).text();}catch{}
 for(let i=0;i<30&&!signals.every(s=>s.aborted);i++)await new Promise(r=>setTimeout(r,5));
 assert.equal(signals.length,2);assert.ok(signals.every(s=>s.aborted));
});
