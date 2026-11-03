import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp,writeFile,rm,readlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { PassThrough,Writable } from 'node:stream';
import { partialJSON,previewEmitter,visualPreview } from '../server/visual-stream.mjs';
import { runVisualStream } from '../server/codex-stream.mjs';
import { generate } from '../server/codex.mjs';
import { readEvents } from '../public/stream.js';
import { VoiceConversation } from '../public/voice.js';
const atom=id=>({id,label:'Oxygen "atom" 🧪',description:'An atom',shape:'sphere',color:'#E88570',position:[0,0,0],scale:[1,1,1],rotation:[0,0,0]});
const visual={title:'Water',scene:{objects:[atom('o'),atom('h')]},diagram:{nodes:[],links:[]},annotations:[],cards:[],reply:'Complete.'};

test('JSON previews arrive before completion at every character boundary and contain only complete validated parts',()=>{
 const raw=JSON.stringify(visual),seen=[];const emit=previewEmitter(r=>seen.push({at:cursor,result:r}));let cursor=0;
 for(cursor=1;cursor<=raw.length;cursor++)emit(raw.slice(0,cursor));
 assert.deepEqual(seen.map(x=>x.result.scene.objects.length),[1,2]);
 assert.ok(seen.every(x=>x.at<raw.length));assert.equal(seen[0].result.reply,'');
 assert.deepEqual(JSON.parse(JSON.stringify(partialJSON(raw))),visual);
 assert.throws(()=>visualPreview(JSON.stringify({...visual,scene:{objects:[{...atom('o'),shape:'script'}]}})),/invalid visual/);
 assert.throws(()=>visualPreview(JSON.stringify({...visual,scene:{objects:[atom('x'),atom('x')]}})),/duplicate/);
 assert.throws(()=>visualPreview('{"scene":{"objects":[{},]}}'));
 assert.throws(()=>previewEmitter()(' '.repeat(2_000_001)),/too large/);
});
test('streaming generation preserves explicit Fast on Sol Low and emits previews before resolving final result',async()=>{
 const seen=[];
 const output=await generate({message:'water',tier:'fast',image:null,previous:null,history:[]},{onPreview:r=>seen.push(r),transport:async opts=>{
  assert.equal(opts.model,'gpt-6.1-sol');assert.equal(opts.reasoningEffort,'low');assert.equal(opts.tier,'fast');assert.equal(opts.env.OPENAI_API_KEY,undefined);
  opts.onText(JSON.stringify(visual).slice(0,-20));assert.equal(seen.length,1);
  return {raw:JSON.stringify(visual),usage:null};
 }});
 assert.equal(output.result.reply,'Complete.');assert.equal(seen[0].reply,'');
});
test('NDJSON reader delivers an early event without waiting for the body and handles split UTF-8',async()=>{
 let controller;const stream=new ReadableStream({start(c){controller=c;}});
 const iterator=readEvents(new Response(stream));
 const bytes=new TextEncoder().encode(JSON.stringify({type:'preview',label:'🧪'})+'\n');
 controller.enqueue(bytes.slice(0,bytes.length-5));controller.enqueue(bytes.slice(bytes.length-5));
 assert.equal((await iterator.next()).value.label,'🧪');
 controller.enqueue(new TextEncoder().encode('{"type":"result"}\n'));controller.close();
 assert.equal((await iterator.next()).value.type,'result');assert.equal((await iterator.next()).done,true);
});

test('app-server transport isolates config, streams text, keeps fixed model settings, and kills the child',async t=>{
 const work=await mkdtemp(path.join(tmpdir(),'clippy-stream-test-'));t.after(()=>rm(work,{recursive:true,force:true}));
 await writeFile(path.join(work,'auth.json'),'{}',{mode:0o600});
 let child,opts,args,killed=false;const sent=[],previews=[];
 const spawnImpl=(_bin,a,o)=>{
  args=a;opts=o;child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.exitCode=null;child.signalCode=null;
  const reply=msg=>child.stdout.write(JSON.stringify(msg)+'\n');
  child.stdin=new Writable({write(chunk,_encoding,done){
   const msg=JSON.parse(chunk);sent.push(msg);
   if(msg.method==='initialize')queueMicrotask(()=>reply({id:msg.id,result:{}}));
   if(msg.method==='thread/start')queueMicrotask(()=>reply({id:msg.id,result:{thread:{id:'thread'}}}));
   if(msg.method==='turn/start')queueMicrotask(()=>{
    reply({id:msg.id,result:{turn:{id:'turn'}}});
    reply({method:'item/agentMessage/delta',params:{threadId:'thread',delta:JSON.stringify(visual)}});
    reply({method:'turn/completed',params:{threadId:'thread',turn:{status:'completed'}}});
   });done();
  }});
  child.kill=()=>{killed=true;child.signalCode='SIGTERM';queueMicrotask(()=>child.emit('exit'));};return child;
 };
 const out=await runVisualStream({input:[{type:'text',text:'water'}],work,model:'gpt-6.1-terra',reasoningEffort:'low',tier:'fast',schema:{type:'object'},env:{CODEX_HOME:work,PATH:process.env.PATH},spawnImpl,onText:r=>previews.push(r)});
 assert.equal(JSON.parse(out.raw).title,'Water');assert.equal(previews.length,1);assert.equal(killed,true);
 assert.notEqual(opts.env.CODEX_HOME,work);assert.equal(await readlink(path.join(opts.env.CODEX_HOME,'auth.json')),path.join(work,'auth.json'));
 assert.ok(args.includes('features.shell_tool=false'));assert.ok(args.includes('features.plugins=false'));
 assert.equal(sent.find(m=>m.method==='thread/start').params.ephemeral,true);
 assert.equal(sent.find(m=>m.method==='thread/start').params.serviceTier,'fast');
 assert.equal(sent.find(m=>m.method==='turn/start').params.effort,'low');
});

test('voice consumes live previews and rolls back a failed drawing without committing it',async()=>{
 const previews=[],rollbacks=[];let controller;
 const response=new Response(new ReadableStream({start(c){controller=c;}}));
 const voice=new VoiceConversation({preview:r=>previews.push(r),rollback:r=>rollbacks.push(r),fetchImpl:async()=>response});
 voice.previous=visual;
 const s={controller:new AbortController(),token:'token',seen:new Set(),drawCount:0,channel:{readyState:'open',send(){}},drawing:false};voice.session=s;
 const drawing=voice.draw(s,{name:'draw_visual',call_id:'one',arguments:'{"prompt":"draw water"}'});
 controller.enqueue(new TextEncoder().encode(JSON.stringify({type:'preview',result:visual})+'\n'));
 await new Promise(r=>setImmediate(r));assert.equal(previews.length,1);
 controller.enqueue(new TextEncoder().encode('{"type":"error","message":"test failure"}\n'));controller.close();await drawing;
 assert.deepEqual(rollbacks,[visual]);assert.equal(voice.previous,visual);
});

test('WebKit fetch keeps its Window receiver in the voice client',async()=>{
 const original=globalThis.fetch;
 try{
  globalThis.fetch=function(){assert.equal(this,globalThis);return Promise.resolve(Response.json({configured:false}));};
  const events=[];const voice=new VoiceConversation({notify:e=>events.push(e)});
  await voice.start();assert.ok(events.some(e=>e.state==='error'&&e.message.includes('Set up')));
 }finally{globalThis.fetch=original;}
});

test('aborting app-server initialization kills the child and rejects pending RPC',async t=>{
 const work=await mkdtemp(path.join(tmpdir(),'clippy-cancel-test-'));t.after(()=>rm(work,{recursive:true,force:true}));
 await writeFile(path.join(work,'auth.json'),'{}',{mode:0o600});
 const controller=new AbortController();let killed=false;
 const spawnImpl=()=>{
  const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough();child.stdin=new PassThrough();child.exitCode=null;child.signalCode=null;
  child.kill=()=>{killed=true;child.signalCode='SIGTERM';queueMicrotask(()=>child.emit('exit'));};
  setImmediate(()=>controller.abort(new Error('Test cancellation')));return child;
 };
 await assert.rejects(runVisualStream({input:[],work,model:'gpt-6.1-terra',reasoningEffort:'low',tier:'fast',schema:{},env:{CODEX_HOME:work},spawnImpl,signal:controller.signal}),/Test cancellation/);
 assert.equal(killed,true);
});

test('diagram links wait for their nodes when JSON fields arrive out of order',()=>{
 const prefix='{"diagram":{"links":[{"from":"a","to":"b","label":"flow"}],"nodes":[';
 const a={id:'a',label:'A',x:20,y:50,color:'#E88570'},b={...a,id:'b',label:'B',x:80};
 const one=visualPreview(prefix+JSON.stringify(a)+',');
 assert.equal(one.diagram.nodes.length,1);assert.equal(one.diagram.links.length,0);
 const both=visualPreview(prefix+JSON.stringify(a)+','+JSON.stringify(b));
 assert.equal(both.diagram.nodes.length,2);assert.equal(both.diagram.links.length,1);
});
