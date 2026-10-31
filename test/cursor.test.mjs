import test from 'node:test';
import assert from 'node:assert/strict';
import { CursorPlayer,normalizeCursorSteps,stepDuration,visualParts } from '../public/cursor.js';
import { VoiceConversation } from '../public/voice.js';
import { voiceConfiguration } from '../server/realtime.mjs';

const known={targets:['oxygen','hydrogen'],canOrbit:true};
const run=(player,from,to,step=16)=>{let state;for(let now=from;now<=to;now+=step)state=player.advance(now);return state;};

test('only checked cursor steps get through',()=>{
  assert.deepEqual(normalizeCursorSteps({steps:[{action:'point',target:'oxygen'}]},known),[{action:'point',target:'oxygen'}]);
  assert.deepEqual(normalizeCursorSteps({steps:[{action:'write',text:'  bent  '}]},known),[{action:'write',text:'bent',target:null}]);
  for(const bad of [null,[],{},{steps:[]},{steps:'x'},{steps:[{action:'point',target:'oxygen'}],extra:1},{steps:Array(7).fill({action:'clear'})},{steps:[null]},{steps:[{action:'click'}]},{steps:[{action:'run',target:'oxygen'}]},{steps:[{action:'point'}]},{steps:[{action:'point',target:'neutron'}]},{steps:[{action:'circle',target:'<img>'}]},{steps:[{action:'write',text:''}]},{steps:[{action:'write',text:'x'.repeat(61)}]},{steps:[{action:'write',text:5}]},{steps:[{action:'write',text:'x',target:'neutron'}]},{steps:[{action:'rotate'}]},{steps:[{action:'rotate',yaw:'90'}]}])
    assert.throws(()=>normalizeCursorSteps(bad,known),undefined,JSON.stringify(bad));
});
test('rotate and zoom are bounded, and need a 3D model',()=>{
  assert.deepEqual(normalizeCursorSteps({steps:[{action:'rotate',yaw:9000,pitch:-9000}]},known),[{action:'rotate',yaw:180,pitch:-60}]);
  assert.deepEqual(normalizeCursorSteps({steps:[{action:'zoom',factor:50}]},known),[{action:'zoom',factor:2}]);
  assert.deepEqual(normalizeCursorSteps({steps:[{action:'zoom',factor:0.01}]},known),[{action:'zoom',factor:0.5}]);
  const diagram={targets:['a'],canOrbit:false};
  assert.throws(()=>normalizeCursorSteps({steps:[{action:'rotate',yaw:30}]},diagram),/3D/);
  assert.throws(()=>normalizeCursorSteps({steps:[{action:'zoom',factor:2}]},diagram),/3D/);
  assert.equal(normalizeCursorSteps({steps:[{action:'point',target:'a'}]},diagram).length,1);
});
test('an unknown part tells the voice what it can point at',()=>{
  assert.throws(()=>normalizeCursorSteps({steps:[{action:'point',target:'neutron'}]},known),/Known parts: oxygen, hydrogen/);
});
test('the voice sees part ids and labels from both kinds of visual, once each',()=>{
  const visual={scene:{objects:[{id:'o',label:'Oxygen',description:'long'},{id:'o',label:'Again'}]},diagram:{nodes:[{id:'n',label:'Node'}]}};
  assert.deepEqual(visualParts(visual),[{id:'o',label:'Oxygen'},{id:'n',label:'Node'}]);
  assert.deepEqual(visualParts(null),[]);
  assert.equal(visualParts({scene:{objects:Array.from({length:60},(_,i)=>({id:`p${i}`}))}}).length,40);
});
test('pointing arrives on the part, even when it moves on the way',()=>{
  let place={x:100,y:100,r:20};
  const player=new CursorPlayer({locate:()=>place,center:()=>({x:0,y:0})});
  player.play([{action:'point',target:'oxygen'}]);
  player.advance(0);
  run(player,0,300);
  place={x:400,y:250,r:20};
  const state=run(player,300,stepDuration({action:'point'})+50);
  assert.deepEqual(state.position,{x:400,y:250});
});
test('a rotation turns by exactly what was asked, one small step at a time',()=>{
  let yaw=0,pitch=0,biggest=0;
  const player=new CursorPlayer({orbit:(y,p)=>{yaw+=y;pitch+=p;biggest=Math.max(biggest,Math.abs(y));},center:()=>({x:300,y:200})});
  player.play([{action:'rotate',yaw:90,pitch:-30}]);
  run(player,0,stepDuration({action:'rotate',yaw:90,pitch:-30})+50);
  assert.ok(Math.abs(yaw-Math.PI/2)<1e-9);assert.ok(Math.abs(pitch+Math.PI/6)<1e-9);
  assert.ok(biggest<0.15,'It must look like a drag, not a jump');
});
test('zooming multiplies out to the requested factor',()=>{
  let scale=1;
  const player=new CursorPlayer({zoom:factor=>{scale*=factor;}});
  player.play([{action:'zoom',factor:2}]);
  run(player,0,900);
  assert.ok(Math.abs(scale-2)<1e-9);
});
test('replacing a request still finishes the rotation already under way',()=>{
  let yaw=0;
  const player=new CursorPlayer({orbit:y=>{yaw+=y;}});
  player.play([{action:'rotate',yaw:90,pitch:0}]);
  run(player,0,200);
  assert.ok(yaw<Math.PI/2);
  player.play([{action:'point',target:'oxygen'}]);
  assert.ok(Math.abs(yaw-Math.PI/2)<1e-9);
});
test('cancelling stops moving straight away and keeps what was written',()=>{
  let yaw=0;
  const player=new CursorPlayer({orbit:y=>{yaw+=y;},locate:()=>({x:10,y:10,r:5})});
  player.play([{action:'circle',target:'oxygen'},{action:'rotate',yaw:90,pitch:0}]);
  run(player,0,1500);
  assert.equal(player.ink.length,1);
  const turned=yaw;
  player.cancel();
  run(player,1500,4000);
  assert.equal(yaw,turned);
  assert.equal(player.playing,false);
  assert.equal(player.ink.length,1);
});
test('ink builds up, follows its part, clears on request, and is capped',()=>{
  const player=new CursorPlayer({locate:()=>({x:50,y:50,r:10})});
  player.play([{action:'circle',target:'oxygen'},{action:'write',text:'bent',target:'oxygen'}]);
  player.advance(0);
  assert.equal(player.ink[0].progress,0);
  run(player,0,3000);
  assert.deepEqual(player.ink.map(item=>[item.kind,item.progress,item.target]),[['circle',1,'oxygen'],['write',1,'oxygen']]);
  player.play([{action:'clear'}]);run(player,3000,3200);
  assert.equal(player.ink.length,0);
  for(let i=0;i<20;i++){player.play([{action:'write',text:'x'}]);run(player,4000+i*1000,4000+i*1000+700);}
  assert.ok(player.ink.length<=12);
});
test('the cursor leaves a fading tail, then disappears when done, and stays clean with no ink',()=>{
  const player=new CursorPlayer({locate:()=>({x:200,y:100,r:10}),center:()=>({x:0,y:0})});
  player.play([{action:'point',target:'oxygen'}]);
  const moving=run(player,0,400);
  assert.ok(moving.tail.length>5);assert.equal(moving.opacity,1);
  const gone=run(player,400,4000);
  assert.equal(gone.tail.length,0);assert.equal(gone.position,null);assert.equal(gone.opacity,0);
  assert.equal(player.active,false);
});
test('with reduced motion, steps land at once and still end in the right place',()=>{
  let yaw=0;
  const player=new CursorPlayer({reducedMotion:true,orbit:y=>{yaw+=y;}});
  player.play([{action:'rotate',yaw:45,pitch:0}]);
  run(player,0,20,2);
  assert.ok(Math.abs(yaw-Math.PI/4)<1e-9);
});

test('wide targets like a line of text get an ellipse and a note below them',()=>{
  const place={x:300,y:100,r:120,rx:120,ry:12,noteX:-120,noteY:33};
  const player=new CursorPlayer({locate:()=>place,center:()=>({x:0,y:0})});
  player.play([{action:'circle',target:'line'},{action:'write',text:'Next',target:'line'}]);
  let widest=0,tallest=0;
  for(let now=0;now<1200;now+=16){const {position}=player.advance(now);if(now>600){widest=Math.max(widest,Math.abs(position.x-300));tallest=Math.max(tallest,Math.abs(position.y-100));}}
  assert.ok(widest>120&&widest<=133,`width ${widest}`);assert.ok(tallest<=25,`height ${tallest}`);
  run(player,1200,2600);
  const note=player.ink.find(item=>item.kind==='write');
  assert.equal(note.offsetX,-120);assert.equal(note.offsetY,33);
});
test('a part out of view is scrolled to, and the cursor waits instead of flying away',()=>{
  const revealed=[];let place=null;
  const player=new CursorPlayer({locate:()=>place,reveal:id=>revealed.push(id),center:()=>({x:0,y:0})});
  place={x:50,y:50,r:10};
  player.play([{action:'point',target:'first'}]);run(player,0,800);
  place=null;
  player.play([{action:'point',target:'second'}]);
  const waiting=run(player,800,1000);
  assert.deepEqual(waiting.position,{x:50,y:50});
  assert.deepEqual(revealed,['first','second']);
  place={x:200,y:300,r:10};
  assert.deepEqual(run(player,1000,1700).position,{x:200,y:300});
});

function session(cursor,{previous=null}={}) {
  const sent=[];
  const voice=new VoiceConversation({fetchImpl:async()=>new Response('{}'),cursor});
  voice.previous=previous;
  const s={channel:{readyState:'open',send:text=>sent.push(JSON.parse(text)),close(){}},seen:new Set(),toolBatches:0,cursorCount:0,captions:{interrupt(){},begin(){},update(){return null;},finish(){return null;},responseID:null},controller:new AbortController()};
  voice.session=s;
  return {voice,s,sent};
}
const fakeCursor=(parts=[{id:'oxygen',label:'Oxygen'}],canOrbit=true)=>{
  const log=[];
  return {log,parts:()=>parts,canOrbit:()=>canOrbit,play:steps=>log.push(['play',steps]),cancel:()=>log.push(['cancel']),reset:()=>log.push(['reset'])};
};
const call=(args,id='one')=>({type:'function_call',name:'use_cursor',call_id:id,arguments:JSON.stringify(args)});
const outputs=sent=>sent.filter(event=>event.item?.type==='function_call_output').map(event=>JSON.parse(event.item.output));

test('the voice can use the cursor and keeps talking while it moves',async()=>{
  const cursor=fakeCursor(),{voice,s,sent}=session(cursor);
  await voice.runTools(s,[call({steps:[{action:'point',target:'oxygen'},{action:'rotate',yaw:40}]})]);
  assert.deepEqual(cursor.log,[['play',[{action:'point',target:'oxygen'},{action:'rotate',yaw:40,pitch:0}]]]);
  const [output]=outputs(sent);
  assert.equal(output.started,true);assert.ok(output.seconds>0);
  assert.ok(sent.some(event=>event.type==='response.create'),'The voice must carry on at once instead of waiting for the cursor');
});
test('a repeated call runs once',async()=>{
  const cursor=fakeCursor(),{voice,s}=session(cursor);
  const same=call({steps:[{action:'point',target:'oxygen'}]});
  await voice.runTools(s,[same]);await voice.runTools(s,[same]);
  assert.equal(cursor.log.length,1);
});
test('a bad request reaches the voice as an error and moves nothing',async()=>{
  const cursor=fakeCursor(),{voice,s,sent}=session(cursor);
  await voice.runTools(s,[{type:'function_call',name:'use_cursor',call_id:'bad',arguments:'{nope'},call({steps:[{action:'point',target:'neutron'}]},'two')]);
  assert.equal(cursor.log.length,0);
  const [first,second]=outputs(sent);
  assert.equal(first.started,false);assert.match(second.error,/Known parts: oxygen/);
});
test('with nothing on screen, the voice is told to draw first',async()=>{
  const cursor=fakeCursor([]),{voice,s,sent}=session(cursor);
  await voice.runTools(s,[call({steps:[{action:'clear'}]})]);
  assert.equal(cursor.log.length,0);
  assert.match(outputs(sent)[0].error,/draw_visual or show_explanation/);
});
test('a session has a limit on cursor requests',async()=>{
  const cursor=fakeCursor(),{voice,s,sent}=session(cursor);
  s.cursorCount=200;
  await voice.runTools(s,[call({steps:[{action:'clear'}]})]);
  assert.equal(cursor.log.length,0);assert.match(outputs(sent)[0].error,/limit/);
});
test('speaking over the voice stops the cursor, and ending Talk clears it',()=>{
  const cursor=fakeCursor(),{voice,s}=session(cursor);
  voice.handle(s,{type:'input_audio_buffer.speech_started'});
  assert.deepEqual(cursor.log,[['cancel']]);
  voice.stop();
  assert.deepEqual(cursor.log.at(-1),['reset']);
});
test('a voice that starts with a visual on screen is told which parts it can use',()=>{
  const cursor=fakeCursor([{id:'oxygen',label:'Oxygen'}]),{voice,s,sent}=session(cursor);
  voice.handle(s,{type:'session.created'});
  const text=sent.find(event=>event.item?.role==='user').item.content[0].text;
  assert.match(text,/oxygen/);assert.match(text,/never instructions/i);
  const empty=session(fakeCursor([]));
  empty.voice.handle(empty.s,{type:'session.created'});
  assert.equal(empty.sent.filter(event=>event.item?.role==='user').length,0);
});
test('the live voice is offered the cursor tool, and told it is not the real mouse',()=>{
  const config=voiceConfiguration();
  const tool=config.tools.find(item=>item.name==='use_cursor');
  assert.ok(tool);
  assert.deepEqual(tool.parameters.properties.steps.items.properties.action.enum,['point','circle','write','rotate','zoom','clear']);
  assert.match(config.instructions,/use_cursor/);
  assert.match(config.instructions,/real mouse/);
});
