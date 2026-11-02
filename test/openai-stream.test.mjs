import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runAPIVisualStream} from '../server/openai-stream.mjs';
import {createServer} from '../server/index.mjs';
import {threeDResultSchema} from '../server/schema.mjs';
import {generateExplanation} from '../server/html-explanation.mjs';

const visual={title:'Water 🧪',reply:'A simplified molecule.',annotations:[],cards:[],diagram:{nodes:[],links:[]},scene:{objects:[{id:'oxygen',label:'Oxygen',description:'O',shape:'sphere',color:'#E88570',position:[0,0,0],scale:[1,1,1],rotation:[0,0,0]}]}};
const base={input:[{type:'text',text:'Draw water'}],model:'gpt-6.1-terra',reasoningEffort:'low',tier:'fast',schema:threeDResultSchema,getKey:async()=>'private-test-key'};
const event=value=>'data: '+JSON.stringify(value)+'\r\n\r\n';
const complete=(raw,service_tier='fast')=>({type:'response.completed',response:{status:'completed',service_tier,usage:{output_tokens:10},output:[{type:'message',content:[{type:'output_text',text:raw}]}]}});

test('OpenAI Draw sends selected model/effort and Fast through Responses, preserving image and streaming previews',async t=>{
  const work=await mkdtemp(path.join(tmpdir(),'clip-api-test-'));t.after(()=>rm(work,{recursive:true,force:true}));
  const image=path.join(work,'image.png'),pixels=Buffer.from([137,80,78,71,13,10,26,10]);await writeFile(image,pixels);
  const raw=JSON.stringify(visual),seen=[];
  const body=event({type:'response.output_text.delta',delta:raw.slice(0,35)})+event({type:'response.output_text.delta',delta:raw.slice(35)})+event(complete(raw));
  const bytes=new TextEncoder().encode(body);
  const output=await runAPIVisualStream({...base,input:[...base.input,{type:'local_image',path:image}],onText:text=>seen.push(text),fetchImpl:async(url,options)=>{
    assert.equal(url,'https://api.openai.com/v1/responses');
    assert.equal(options.headers.Authorization,'Bearer private-test-key');
    const request=JSON.parse(options.body);
    assert.equal(request.model,'gpt-6.1-terra');assert.deepEqual(request.reasoning,{effort:'low'});
    assert.equal(request.service_tier,'fast');assert.equal(request.store,false);assert.equal(request.stream,true);
    assert.equal(request.text.format.strict,true);assert.equal(request.text.format.type,'json_schema');
    assert.equal(Object.keys(request.text.format.schema.properties)[1],'scene');
    assert.equal(request.input[0].content[1].image_url,'data:image/png;base64,'+pixels.toString('base64'));
    return new Response(new ReadableStream({start(c){for(let i=0;i<bytes.length;i+=7)c.enqueue(bytes.slice(i,i+7));c.close();}}));
  }});
  assert.equal(output.raw,raw);assert.ok(seen.some(text=>text.length<raw.length));
  assert.equal(output.transport,'openai-api');assert.equal(output.serviceTier,'fast');assert.equal(output.usage.output_tokens,10);
});
test('Draw transport honors alternate picker choices, reports the actual served tier, and never requests Ultrafast for Terra',async()=>{
  const output=await runAPIVisualStream({...base,model:'gpt-6.1-sol',reasoningEffort:'high',fetchImpl:async(_url,options)=>{
    const request=JSON.parse(options.body);assert.equal(request.model,'gpt-6.1-sol');assert.equal(request.reasoning.effort,'high');
    return new Response(event(complete('{}','default')));
  }});
  assert.equal(output.serviceTier,'default');
  await assert.rejects(runAPIVisualStream({...base,tier:'ultrafast',fetchImpl:()=>assert.fail()}),/speed/);
});
test('Sol and Astra send the actual Ultrafast API tier without substituting a model or effort',async()=>{
  for(const model of ['gpt-6.1-sol','gpt-6-astra']){
    const output=await runAPIVisualStream({...base,model,tier:'ultrafast',fetchImpl:async(_url,options)=>{
      const request=JSON.parse(options.body);assert.equal(request.model,model);assert.equal(request.reasoning.effort,'low');assert.equal(request.service_tier,'ultrafast');
      return new Response(event(complete('{}','ultrafast')));
    }});
    assert.equal(output.serviceTier,'ultrafast');
  }
});
test('HTML generation uses the same API transport and preserves progressive sections and tier metadata',async()=>{
  const html={title:'Quiz',sections:[{html:'<details><summary>2+2?</summary>4</details>'}],summary:'A short quiz.'},previews=[];
  const output=await generateExplanation({message:'Make a quiz',provider:'gpt',model:'gpt-6.1-terra',reasoningEffort:'low',tier:'fast',history:[],previous:null,image:null},{onPreview:x=>previews.push(x),transport:args=>runAPIVisualStream({...args,getKey:base.getKey,fetchImpl:async(_url,options)=>{
    const request=JSON.parse(options.body);assert.deepEqual(Object.keys(request.text.format.schema.properties),['title','sections','summary']);
    return new Response(event(complete(JSON.stringify(html))));
  }})});
  assert.equal(output.transport,'openai-api');assert.equal(output.serviceTier,'fast');assert.deepEqual(output.result,html);assert.equal(previews.length,1);
});
test('missing keys, upstream failures, truncated output and refusals never trigger a Codex fallback or expose bodies',async()=>{
  await assert.rejects(runAPIVisualStream({...base,getKey:async()=>'',fetchImpl:()=>assert.fail()}),/API key/);
  await assert.rejects(runAPIVisualStream({...base,fetchImpl:async()=>new Response('private-test-key and private prompt',{status:401})}),error=>!error.message.includes('private')&&/401/.test(error.message));
  for(const data of ['data: private-test-key\n\n',event({type:'response.output_text.delta',delta:'{}'}),event({type:'response.failed',response:{error:{message:'private-test-key'}}}),event({type:'response.refusal.done',refusal:'private context'})]){
    await assert.rejects(runAPIVisualStream({...base,fetchImpl:async()=>new Response(data)}),error=>!error.message.includes('private'));
  }
  await assert.rejects(runAPIVisualStream({...base,fetchImpl:async()=>new Response(event({type:'response.output_text.delta',delta:'x'.repeat(2_000_001)}))}),/large/);
});
test('cancel before and during the API call aborts without another request',async()=>{
  const before=new AbortController();before.abort(Error('Stop'));
  await assert.rejects(runAPIVisualStream({...base,signal:before.signal,getKey:()=>assert.fail()}),/Stop/);
  const during=new AbortController();let calls=0;
  const pending=runAPIVisualStream({...base,signal:during.signal,fetchImpl:async(_url,{signal})=>{
    calls++;return new Response(new ReadableStream({start(c){signal.addEventListener('abort',()=>c.error(signal.reason),{once:true});during.abort(Error('Stop'));}}));
  }});
  await assert.rejects(pending,/Stop/);assert.equal(calls,1);
});
test('API Draw works without Codex login while chat still requires it',async t=>{
  const seen=[],server=createServer({checkAuth:async()=>false,routePresentation:async()=>'draw',routeDrawFormat:async()=>'3d',chooseStatus:async()=>null,run:async request=>{seen.push(request);return{result:visual};}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>{server.closeAllConnections();return new Promise(r=>server.close(r));});
  const url=`http://127.0.0.1:${server.address().port}`,{token}=await(await fetch(url+'/api/session')).json();
  const send=mode=>fetch(url+'/api/ask',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'Water',mode})});
  const draw=await send('draw');assert.equal(draw.status,200);assert.equal(JSON.parse((await draw.text()).trim().split('\n').at(-1)).type,'result');
  assert.equal(seen[0].model,'gpt-6.1-sol');assert.equal(seen[0].reasoningEffort,'low');assert.equal(seen[0].tier,'ultrafast');
  const automatic=await fetch(url+'/api/ask',{method:'POST',headers:{'Content-Type':'application/json','X-Clippy-Session':token},body:JSON.stringify({message:'Water',mode:'auto',model:'auto',tier:'fast',drawing:{provider:'gpt',model:'gpt-6.1-sol',reasoningEffort:'low'}})});
  await automatic.text();assert.equal(seen[1].model,'gpt-6.1-sol');assert.equal(seen[1].tier,'ultrafast','automatic Draw must use its own speed, not chat Fast');
  assert.equal((await send('chat')).status,401);assert.equal(seen.length,2);
});
