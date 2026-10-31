import test from 'node:test';
import assert from 'node:assert/strict';
import {RealtimeService,voiceConfiguration} from '../server/realtime.mjs';
import {createServer} from '../server/index.mjs';
import {VoiceConversation} from '../public/voice.js';
const sdp='v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';

test('voice config limits capabilities to drawing and uses live audio with interruption',()=>{
 const config=voiceConfiguration();
 assert.equal(config.model,'gpt-realtime-2.1');assert.deepEqual(config.tools.map(t=>t.name),['draw_visual']);
 assert.equal(config.audio.input.turn_detection.interrupt_response,true);assert.deepEqual(config.output_modalities,['audio']);
});
test('voice service keeps key on server, limits sessions and hangs up known calls only',async()=>{
 const calls=[];
 const service=new RealtimeService({getKey:async()=>'test-secret',fetchImpl:async(url,options)=>{
  calls.push({url,options});
  return url.endsWith('/hangup')?new Response('',{status:200}):new Response(sdp,{status:201,headers:{location:'/v1/realtime/calls/rtc_test'}});
 }});
 await assert.rejects(service.create('invalid'),/offer/);
 const session=await service.create(sdp);
 assert.equal(session.model,'gpt-realtime-2.1');assert.equal(JSON.stringify(session).includes('test-secret'),false);
 assert.equal(calls[0].options.headers.Authorization,'Bearer test-secret');
 assert.equal(JSON.parse(calls[0].options.body.get('session')).model,'gpt-realtime-2.1');
 await assert.rejects(service.create(sdp),/already active/);
 await service.close('https://evil.test');assert.equal(calls.length,1);
 await service.close(session.id);assert.equal(calls[1].url,'https://api.openai.com/v1/realtime/calls/rtc_test/hangup');
 assert.equal(service.calls.size,0);
});
test('missing credential and API failures create no active session',async()=>{
 const absent=new RealtimeService({getKey:async()=>''});await assert.rejects(absent.create(sdp),/OPENAI_API_KEY/);
 const bad=new RealtimeService({getKey:async()=>'secret',fetchImpl:async()=>new Response('secret credential detail',{status:401})});
 await assert.rejects(bad.create(sdp),error=>!error.message.includes('secret')&&error.message.includes('401'));
 assert.equal(bad.calls.size,0);assert.equal(bad.creating,false);
});
test('voice HTTP requests require local session and reject client configuration overrides',async t=>{
 let count=0;
 const voice={ready:async()=>true,closeAll:async()=>{},close:async()=>{},create:async offer=>{count++;assert.equal(offer,sdp);return{id:'test',sdp,model:'gpt-realtime-2.1'};}};
 const server=createServer({chooseStatus:async()=>null,voice,checkAuth:async()=>true});await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>server.close());
 const url=`http://127.0.0.1:${server.address().port}`;
 const headers={'Content-Type':'application/json'};
 assert.equal((await fetch(url+'/api/realtime/call',{method:'POST',headers,body:JSON.stringify({sdp})})).status,403);
 const {token}=await(await fetch(url+'/api/session')).json();headers['X-Clippy-Session']=token;
 assert.equal((await fetch(url+'/api/realtime/call',{method:'POST',headers,body:JSON.stringify({sdp,model:'wrong'})})).status,400);
 const response=await fetch(url+'/api/realtime/call',{method:'POST',headers,body:JSON.stringify({sdp})});assert.equal(response.status,200);assert.equal(count,1);
});
function clientFixture(mediaOverride) {
 const events=[],requests=[],sent=[];let stopped=0,closed=0;
 const tracks={getTracks:()=>[{stop(){stopped++;}}],getAudioTracks:()=>[{stop(){stopped++;}}]};
 class Peer {
  constructor(){this.channel={readyState:'open',send:data=>sent.push(JSON.parse(data)),close(){}};}
  addTrack(){} createDataChannel(){return this.channel;} async createOffer(){return{sdp};} async setLocalDescription(){} async setRemoteDescription(){} close(){closed++;}
 }
 const fetchImpl=async(path,opts)=>{
  requests.push({path,opts});
  if(path.endsWith('/status'))return Response.json({configured:true});
  if(path==='/api/session')return Response.json({token:'local-token'});
  if(path.endsWith('/call'))return Response.json({id:'session',sdp,limitMs:600000});
  if(path.endsWith('/stop'))return Response.json({stopped:true});
  if(path==='/api/chat')return new Response(JSON.stringify({type:'result',result:{title:'Water',reply:'Water schematic',scene:{objects:[]},diagram:{nodes:[],links:[]},cards:[]}})+'\n');
  throw new Error('Unexpected route');
 };
 const voice=new VoiceConversation({notify:event=>events.push(event),render:result=>events.push({result}),fetchImpl,Peer,media:mediaOverride||{getUserMedia:async()=>tracks},makeAudio:()=>({play:async()=>{},pause(){}})});
 return{voice,events,requests,sent,tracks,stopped:()=>stopped,closed:()=>closed};
}
test('ending voice stops microphone, playback, connection, pending work and requests hangup',async()=>{
 const f=clientFixture();await f.voice.start();const s=f.voice.session;
 f.voice.handle(s,{type:'session.created'});f.voice.setMuted(true);assert.equal(s.audio.muted,true);
 f.voice.stop();await new Promise(r=>setImmediate(r));
 assert.equal(f.voice.session,null);assert.equal(f.stopped(),1);assert.equal(f.closed(),1);assert.equal(s.controller.signal.aborted,true);
 assert.ok(f.requests.some(r=>r.path==='/api/realtime/stop'));assert.equal(s.audio.srcObject,null);
});
test('ending while microphone permission is pending cannot start a late session',async()=>{
 let grant;const pending=new Promise(r=>grant=r);const f=clientFixture({getUserMedia:()=>pending});
 const starting=f.voice.start();await new Promise(r=>setImmediate(r));f.voice.stop();grant(f.tracks);await starting;
 assert.equal(f.stopped(),1);assert.equal(f.voice.session,null);assert.equal(f.requests.some(r=>r.path.endsWith('/call')),false);
});
test('voice drawings follow the selected provider while the voice itself stays on Realtime',async()=>{
 const f=clientFixture();f.voice.setProvider('claude');
 f.voice.setDrawingSettings({provider:'claude',model:'claude-opus-5-5',reasoningEffort:'high'});
 await f.voice.start();const s=f.voice.session;
 f.voice.handle(s,{type:'session.created'});
 await f.voice.draw(s,{name:'draw_visual',call_id:'one',arguments:JSON.stringify({prompt:'Draw water'})});
 const drawing=JSON.parse(f.requests.find(r=>r.path==='/api/chat').opts.body);
 assert.equal(drawing.provider,'claude');assert.equal(drawing.model,'claude-opus-5-5');assert.equal(drawing.reasoningEffort,'high');
 assert.ok(f.requests.some(r=>r.path==='/api/realtime/call'));
 f.voice.setProvider('anything else');assert.equal(f.voice.provider,'gpt');
 f.voice.stop();
});
test('voice drawings use Terra Fast route, reject other tools, and deduplicate calls',async()=>{
 const f=clientFixture();await f.voice.start();const s=f.voice.session;
 f.voice.handle(s,{type:'session.created'});
 const call={name:'draw_visual',call_id:'one',arguments:JSON.stringify({prompt:'Draw water'})};
 await f.voice.draw(s,call);await f.voice.draw(s,call);
 const drawings=f.requests.filter(r=>r.path==='/api/chat');assert.equal(drawings.length,1);assert.equal(JSON.parse(drawings[0].opts.body).tier,'fast');
 await f.voice.draw(s,{name:'execute_shell',call_id:'two',arguments:'{}'});
 assert.equal(f.requests.filter(r=>r.path==='/api/chat').length,1);
 assert.ok(f.sent.some(e=>e.item?.type==='function_call_output'&&JSON.parse(e.item.output).shown));
 f.voice.stop();
});

test('completed voice explanation calls stream a visual before confirming it is shown',async()=>{
 const f=clientFixture();await f.voice.start();const s=f.voice.session;
 const result={title:'Molecules',reply:'Atoms bond to form molecules.',scene:{objects:[]},diagram:{nodes:[{id:'o',label:'Oxygen',x:50,y:50,color:'#7298CF'}],links:[]},cards:[]};
 let finish;const pending=new Promise(r=>finish=r);const requests=[];
 f.voice.fetch=async(path,options)=>{
  if(path==='/api/chat'){
   requests.push(JSON.parse(options.body));
   return new Response(new ReadableStream({start(controller){
    controller.enqueue(new TextEncoder().encode(JSON.stringify({type:'preview',result})+'\n'));
    pending.then(()=>{controller.enqueue(new TextEncoder().encode(JSON.stringify({type:'result',result})+'\n'));controller.close();});
   }}));
  }
  return Response.json({stopped:true});
 };
 let previewed=false,rendered=false;f.voice.preview=()=>{previewed=true;};f.voice.render=()=>{rendered=true;};
 const item={type:'function_call',name:'draw_visual',call_id:'implicit-molecules',arguments:JSON.stringify({prompt:'Explain how molecules work with labeled atoms and bonds.'})};
 f.voice.handle(s,{type:'response.done',response:{status:'completed',output:[item]}});
 await new Promise(r=>setImmediate(r));
 assert.equal(requests.length,1);assert.equal(requests[0].mode,'draw');assert.equal(previewed,true);assert.equal(rendered,false);
 assert.equal(f.sent.some(e=>e.item?.type==='function_call_output'),false);
 finish();await new Promise(r=>setImmediate(r));
 assert.equal(rendered,true);
 const output=f.sent.find(e=>e.item?.type==='function_call_output');assert.equal(JSON.parse(output.item.output).shown,true);
 assert.equal(f.sent.at(-1).type,'response.create');
 f.voice.handle(s,{type:'response.done',response:{status:'completed',output:[item]}});await new Promise(r=>setImmediate(r));assert.equal(requests.length,1);
 f.voice.stop();
});
test('cancelled voice responses cannot dispatch stale drawing calls',async()=>{
 const f=clientFixture();await f.voice.start();const s=f.voice.session;
 f.voice.handle(s,{type:'response.done',response:{status:'cancelled',output:[{type:'function_call',name:'draw_visual',call_id:'cancelled',arguments:JSON.stringify({prompt:'Old question'})}]}});
 await new Promise(r=>setImmediate(r));assert.equal(f.requests.some(r=>r.path==='/api/chat'),false);assert.equal(s.seen.size,0);f.voice.stop();
});
test('voice drawing failures report shown:false so the voice can continue verbally',async()=>{
 const f=clientFixture();await f.voice.start();const s=f.voice.session;
 f.voice.fetch=async path=>path==='/api/chat'?new Response(JSON.stringify({type:'error',message:'Drawing model unavailable'})+'\n'):Response.json({stopped:true});
 await f.voice.draw(s,{name:'draw_visual',call_id:'failed',arguments:JSON.stringify({prompt:'Explain molecule structure'})});
 const output=f.sent.find(e=>e.item?.type==='function_call_output');assert.equal(JSON.parse(output.item.output).shown,false);assert.equal(f.sent.at(-1).type,'response.create');f.voice.stop();
});
