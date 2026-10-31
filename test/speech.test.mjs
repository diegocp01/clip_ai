import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeSpeech,synthesizeSpeech,SPEECH_VOICES} from '../server/speech.mjs';
import {createServer} from '../server/index.mjs';

test('speech accepts only supported voices and bounded exact text',()=>{
 const text='  Hello, Diego!\nSame answer.  ';
 for(const voice of SPEECH_VOICES)assert.deepEqual(normalizeSpeech({text,voice}),{text,voice});
 assert.equal(normalizeSpeech({text}).voice,'marin');
 for(const body of [null,[],{text:''},{text:' '.repeat(30)},{text:'x'.repeat(3501)},{text,voice:'fake'},{text,model:'other'}])assert.throws(()=>normalizeSpeech(body));
});
test('speech sends the exact reply to OpenAI and keeps secrets out of failures',async()=>{
 const text='Hello! This is the displayed reply.';
 const audio=await synthesizeSpeech({text,voice:'cedar'},{getKey:async()=>'private-test-key',fetchImpl:async(url,options)=>{
  assert.equal(url,'https://api.openai.com/v1/audio/speech');
  const body=JSON.parse(options.body);assert.equal(body.input,text);assert.equal(body.voice,'cedar');assert.equal(body.model,'gpt-4o-mini-tts');assert.equal(body.response_format,'mp3');
  return new Response(new Uint8Array([73,68,51]));
 }});assert.deepEqual([...audio],[73,68,51]);
 await assert.rejects(synthesizeSpeech({text},{getKey:async()=>''}),/API key/);
 await assert.rejects(synthesizeSpeech({text},{getKey:async()=>'private-test-key',fetchImpl:async()=>new Response('private-test-key',{status:401})}),error=>error.message.includes('401')&&!error.message.includes('private-test-key'));
});
test('speech bounds response memory and respects cancellation',async()=>{
 const options={getKey:async()=>'key',fetchImpl:async()=>new Response(new Uint8Array(8*1024*1024+1))};
 await assert.rejects(synthesizeSpeech({text:'Hello'},options),/too large/);
 const controller=new AbortController();controller.abort();
 await assert.rejects(synthesizeSpeech({text:'Hello'},{...options,signal:controller.signal}));
});
test('speech endpoint authenticates, rejects overrides, returns audio and limits concurrent synthesis',async t=>{
 let release,entered;let calls=0;
 const started=new Promise(r=>entered=r);
 const server=createServer({runSpeech:async(body,{signal})=>{calls++;assert.equal(body.text,'Same reply');assert.equal(body.voice,'ash');entered();await new Promise(r=>release=r);signal.throwIfAborted();return Buffer.from('ID3');}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>server.close());
 const url=`http://127.0.0.1:${server.address().port}`;
 const headers={'Content-Type':'application/json'};
 const post=body=>fetch(url+'/api/speech',{method:'POST',headers,body:JSON.stringify(body)});
 assert.equal((await post({text:'Same reply'})).status,403);
 headers['X-Clippy-Session']=(await(await fetch(url+'/api/session')).json()).token;
 assert.equal((await post({text:'Same reply',voice:'invalid'})).status,400);
 assert.equal((await post({text:'Same reply',model:'wrong'})).status,400);
 const pending=post({text:'Same reply',voice:'ash'});await started;
 assert.equal((await post({text:'Same reply'})).status,429);release();
 const response=await pending;assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),'audio/mpeg');assert.equal(await response.text(),'ID3');assert.equal(calls,1);
});
test('disconnect cancels speech generation and errors never echo upstream details',async t=>{
 let entered,aborted;
 const started=new Promise(r=>entered=r),cancelled=new Promise(r=>aborted=r);
 const server=createServer({runSpeech:async(body,{signal})=>{entered();return new Promise((resolve,reject)=>{signal.addEventListener('abort',()=>{aborted();reject(Error('secret'));},{once:true});});}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>server.close());
 const url=`http://127.0.0.1:${server.address().port}`;
 const {token}=await(await fetch(url+'/api/session')).json();const controller=new AbortController();
 const pending=fetch(url+'/api/speech',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({text:'Hello'}),signal:controller.signal}).catch(()=>{});
 await started;controller.abort();await pending;await cancelled;
});
