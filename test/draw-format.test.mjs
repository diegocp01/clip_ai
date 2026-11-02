import test from 'node:test';
import assert from 'node:assert/strict';
import {chooseDrawFormat} from '../server/draw-format.mjs';
import {choosePresentation} from '../server/presentation.mjs';
import {createServer} from '../server/index.mjs';
import {generate} from '../server/codex.mjs';
import {assertThreeDResult} from '../server/schema.mjs';

const plane={title:'Airplane',reply:'The wings turn air downward.',annotations:[],cards:[],scene:{objects:[{id:'wing',label:'Wing',description:'Creates lift',shape:'box',color:'#7298CF',position:[0,0,0],scale:[4,0.1,1],rotation:[0,0,0]}]},diagram:{nodes:[],links:[]}};
const html={title:'Token prediction',summary:'Predict the next token.',sections:[{html:'<details><summary>Question</summary>47</details>'}]};
test('format decision is a bounded separate API choice and shares no pixels/history',async()=>{
  for(const format of ['3d','html'])assert.equal(await chooseDrawFormat({message:'How do airplanes work?',image:'private pixels',previous:plane,history:['private history']},{getKey:async()=>'test',fetchImpl:async(_url,options)=>{
    const body=JSON.parse(options.body);assert.equal(body.questions[0].name,'draw_format');
    assert.deepEqual(body.questions[0].choices.map(x=>x.value),['3d','html']);
    assert.deepEqual(JSON.parse(body.input),{message:'How do airplanes work?',hasAttachedImage:true,previousFormat:'3d'});
    return Response.json({answers:[{name:'draw_format',type:'choice',choice:format}]});
  }}),format);
  for(const fetchImpl of [async()=>Response.json({answers:[{name:'draw_format',type:'choice',choice:'execute'}]}),async()=>new Response('',{status:500}),async()=>{throw Error('offline');}])assert.equal(await chooseDrawFormat({message:'x'},{getKey:async()=>'test',fetchImpl}),null);
  assert.equal(await chooseDrawFormat({message:'x'},{getKey:async()=>'',fetchImpl:()=>assert.fail()}),null);
  const abort=new AbortController();abort.abort(Error('Stop'));
  await assert.rejects(chooseDrawFormat({message:'x'},{signal:abort.signal,getKey:()=>assert.fail()}),/Stop/);
});
async function harness(t,deps={}) {
  const server=createServer({checkAuth:async()=>true,checkClaude:async()=>true,chooseStatus:async()=>null,routeDrawFormat:async()=>'3d',run:async()=>({result:plane}),...deps});
  await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
  const base=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(base+'/api/session')).json();
  return async(body,signal)=>{const response=await fetch(base+'/api/ask',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify(body),signal});return{status:response.status,events:(await response.text()).trim().split('\n').map(JSON.parse)};};
}
test('Draw selects a medium before inference and streams the matching format',async t=>{
  for(const format of ['3d','html']){
    let seen;
    const run=async(request,{onPreview})=>{seen=request;const result=format==='3d'?plane:html;onPreview(result);return{result};};
    const send=await harness(t,{routeDrawFormat:async() =>format,run:format==='3d'?run:()=>assert.fail('wrong generator'),runHTML:format==='html'?run:()=>assert.fail('wrong generator')});
    const {events}=await send({message:'Explain this',mode:'draw'});
    assert.equal(seen.visualFormat,format);assert.equal(events.find(e=>e.type==='draw-format').source,'decisions');
    assert.equal(events.find(e=>e.type==='preview').format,format);assert.equal(events.at(-1).format,format);assert.equal(events.at(-1).mode,'draw');
  }
});
test('automatic visual choice uses independent Draw settings, while chat never chooses a medium',async t=>{
  let formats=0,seen;
  const send=await harness(t,{routePresentation:async()=>'draw',routeDrawFormat:async()=>{formats++;return'3d';},runClaude:async request=>{seen=request;return{result:plane};}});
  await send({message:'How do airplanes work?',mode:'auto',drawing:{provider:'claude',model:'claude-sonnet-5-5',reasoningEffort:'high'}});
  assert.equal(seen.provider,'claude');assert.equal(seen.model,'claude-sonnet-5-5');assert.equal(seen.visualFormat,'3d');
  await send({message:'Hi',mode:'chat'});assert.equal(formats,1);
});
test('creative visual request reaches 3D generation through both decisions with its full prompt and Draw settings',async t=>{
  const message='Create a hyperrealistic fighter jet—detailed metal panels, glowing afterburners, and cinematic lighting above the clouds.';
  for(const provider of ['gpt','claude']){
    let seen;const decisions=[];
    const fetchImpl=async(_url,options)=>{
      const body=JSON.parse(options.body),question=body.questions[0];
      decisions.push(question.name);
      assert.equal(JSON.parse(body.input).message,message);
      return Response.json({answers:[{name:question.name,type:'choice',choice:question.name==='presentation'?'draw':'3d'}]});
    };
    const generate=async request=>{seen=request;return{result:plane};};
    const send=await harness(t,{
      routePresentation:(request,options)=>choosePresentation(request,{...options,getKey:async()=>'test',fetchImpl}),
      routeDrawFormat:(request,options)=>chooseDrawFormat(request,{...options,getKey:async()=>'test',fetchImpl}),
      routeChat:()=>assert.fail('Draw must not choose a chat model'),
      run:provider==='gpt'?generate:()=>assert.fail('wrong Draw provider'),
      runClaude:provider==='claude'?generate:()=>assert.fail('wrong Draw provider'),
      runHTML:()=>assert.fail('a fighter jet should reach the 3D generator'),
    });
    const model=provider==='gpt'?'gpt-6.1-terra':'claude-sonnet-5-5';
    const {events}=await send({message,mode:'auto',model:'auto',reasoningEffort:'auto',drawing:{provider,model,reasoningEffort:'low'}});
    assert.deepEqual(decisions,['presentation','draw_format']);
    assert.equal(seen.message,message);assert.equal(seen.provider,provider);assert.equal(seen.model,model);
    assert.equal(seen.mode,'draw');assert.equal(seen.visualFormat,'3d');assert.equal(seen.reasoningEffort,'low');
    assert.equal(events.at(-1).mode,'draw');assert.equal(events.at(-1).format,'3d');
    assert.ok(events.at(-1).result.scene.objects.length>0);
  }
});
test('HTML context is validated and retained only for an HTML follow-up',async t=>{
  let seen;
  const send=await harness(t,{routeDrawFormat:async()=>'html',runHTML:async request=>{seen=request;return{result:html};}});
  assert.equal((await send({message:'Explain the next step',mode:'draw',previous:html})).status,200);
  assert.deepEqual(seen.previous,html);
  assert.equal((await send({message:'Explain',previous:{...html,sections:[{html:'x'.repeat(8001)}]}})).status,400);
});
test('failed format decision falls back to 3D; cancellation prevents inference',async t=>{
  const send=await harness(t,{routeDrawFormat:async()=>null});
  const {events}=await send({message:'Draw a plane',mode:'draw'});assert.equal(events.find(e=>e.type==='draw-format').format,'3d');assert.equal(events.find(e=>e.type==='draw-format').source,'fallback');
  let entered,signal;const ready=new Promise(r=>entered=r);
  const cancel=await harness(t,{routeDrawFormat:(_r,options)=>{signal=options.signal;entered();return new Promise(resolve=>signal.addEventListener('abort',()=>resolve('3d'),{once:true}));},run:()=>assert.fail('cancelled inference')});
  const abort=new AbortController(),pending=cancel({message:'Plane',mode:'draw'},abort.signal);await ready;abort.abort();await assert.rejects(pending);
  for(let i=0;i<20&&!signal.aborted;i++)await new Promise(r=>setTimeout(r,5));assert.equal(signal.aborted,true);
});
test('3D generation requires physical objects, excludes diagram/cards, and preserves part IDs',async()=>{
  let options;
  await generate({message:'Airplane',provider:'gpt',model:'gpt-6.1-terra',reasoningEffort:'low',mode:'draw',visualFormat:'3d',history:[],previous:null,image:null},{transport:async args=>{options=args;return{raw:JSON.stringify(plane)};}});
  assert.equal(options.schema.properties.scene.properties.objects.minItems,1);
  assert.equal(options.schema.properties.diagram.properties.nodes.maxItems,0);
  assert.match(options.input[0].text,/recognizable subject/);assert.match(options.input[0].text,/airplane/);
  assert.equal(assertThreeDResult(plane).scene.objects[0].id,'wing');
  assert.throws(()=>assertThreeDResult({...plane,scene:{objects:[]}}),/needs a model/);
});
