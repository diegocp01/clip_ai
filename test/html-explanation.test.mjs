import test from 'node:test';
import assert from 'node:assert/strict';
import {assertExplanation,normalizeExplanation,explanationEmitter} from '../server/html-explanation.mjs';
import {createServer} from '../server/index.mjs';
import {VoiceConversation} from '../public/voice.js';
const example={title:'Tokens',sections:[{html:'<h1>Inputs</h1>'},{html:'<details><summary>Answer</summary>47</details>'}],summary:'Next-token prediction.'};
test('HTML streams only completed sections, bounded and without duplicate previews',()=>{
 const seen=[],emit=explanationEmitter(x=>seen.push(x));
 emit('{"title":"Tokens","sections":[{"html":"<h1>');assert.equal(seen.length,0);
 emit('{"title":"Tokens","sections":[{"html":"<h1>Inputs</h1>"},');assert.equal(seen.length,1);
 emit('{"title":"Tokens","sections":[{"html":"<h1>Inputs</h1>"},{"html":"part');assert.equal(seen.length,1);
 emit(JSON.stringify(example));assert.equal(seen.length,2);assert.equal(seen[1].sections.length,2);
 assert.throws(()=>assertExplanation({...example,sections:[{html:'x'.repeat(8001)}]}));
 assert.throws(()=>emit('x'.repeat(150001)));
 assert.equal(normalizeExplanation({message:'Explain',previous:example}).previous,example);
 assert.throws(()=>normalizeExplanation({message:'Explain',previous:{html:'bad'}}));
 assert.throws(()=>normalizeExplanation({message:'Explain',provider:'both'}));
});
test('HTML endpoint authenticates, forwards image/context, and streams preview before final',async t=>{
 let calls=0;
 const server=createServer({checkAuth:async()=>true,runHTML:async(request,{onPreview})=>{calls++;assert.equal(request.previous.title,'Tokens');onPreview({...example,sections:example.sections.slice(0,1)});return {result:example};}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));t.after(()=>server.close());
 const base=`http://127.0.0.1:${server.address().port}`;
 const options={method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:'Explain',previous:example})};
 assert.equal((await fetch(base+'/api/explanation',options)).status,403);
 const {token}=await(await fetch(base+'/api/session')).json();options.headers['X-Clippy-Session']=token;
 const response=await fetch(base+'/api/explanation',options);assert.equal(response.status,200);
 const events=(await response.text()).trim().split('\n').map(JSON.parse);
 assert.deepEqual(events.map(e=>e.type),['preview','result']);assert.equal(calls,1);
 options.body=JSON.stringify({message:'Explain',provider:'both'});assert.equal((await fetch(base+'/api/explanation',options)).status,400);assert.equal(calls,1);
});
function fixture(fetchImpl){
 const sent=[],previews=[],rendered=[];
 const voice=new VoiceConversation({fetchImpl,previewHTML:x=>previews.push(x),renderHTML:x=>rendered.push(x),render:()=>assert.fail('HTML must not use drawing renderer')});
 const session={controller:new AbortController(),channel:{readyState:'open',send:x=>sent.push(JSON.parse(x))},token:'test',seen:new Set(),drawCount:0,toolBatches:1,screen:'shared crop',responding:false};voice.session=session;
 return {voice,session,sent,previews,rendered};
}
test('voice HTML tool uses latest pointer crop, streams, remembers panel, and reports actual summary',async()=>{
 const f=fixture(async(path,options)=>{
  assert.equal(path,'/api/ask');const request=JSON.parse(options.body);assert.equal(request.tier,'ultrafast');assert.equal(request.model,'gpt-6.1-sol');assert.equal(request.image,'shared crop');assert.equal(request.previous,null);
  return new Response([JSON.stringify({type:'preview',format:'html',result:{...example,sections:example.sections.slice(0,1)}}),JSON.stringify({type:'result',format:'html',result:example})].join('\n'));
 });
 f.voice.setDrawingSettings({provider:'gpt',model:'gpt-6.1-sol',reasoningEffort:'low',tier:'ultrafast'});
 const item={name:'show_explanation',call_id:'1',arguments:JSON.stringify({prompt:'Explain the circled tensor'})};
 await f.voice.draw(f.session,item);await f.voice.draw(f.session,item);
 assert.equal(f.previews.length,1);assert.equal(f.rendered.length,1);assert.equal(f.voice.previousHTML.title,'Tokens');
 assert.deepEqual(JSON.parse(f.sent[0].item.output),{shown:true,title:'Tokens',summary:'Next-token prediction.'});
});
test('dismissal aborts generation and never renders a late result',async()=>{
 let release;
 const f=fixture(async()=>{await new Promise(r=>release=r);return new Response(JSON.stringify({type:'result',format:'html',result:example})+'\n');});
 const pending=f.voice.draw(f.session,{name:'show_explanation',call_id:'2',arguments:'{"prompt":"Explain"}'});
 f.voice.cancelVisual();release();await pending;
 assert.equal(f.rendered.length,0);assert.equal(JSON.parse(f.sent[0].item.output).shown,false);
});
