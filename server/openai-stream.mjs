import {readFile} from 'node:fs/promises';
import {voiceKey} from './realtime.mjs';
import {assertDrawingTier} from './drawing-settings.mjs';

// Direct API transport for OpenAI Draw. Chat keeps its signed-in Codex transport.
export async function runAPIVisualStream({input,model,reasoningEffort,tier='fast',schema,signal,onText=()=>{},fetchImpl=fetch,getKey=voiceKey}) {
  const bounded=signal?AbortSignal.any([signal,AbortSignal.timeout(120000)]):AbortSignal.timeout(120000);
  bounded.throwIfAborted();
  const key=await getKey();
  if(!key)throw Error('Draw needs the existing OpenAI API key in .env.local.');
  assertDrawingTier(tier,'gpt',model);
  const content=[];
  for(const item of input){
    if(item.type==='text')content.push({type:'input_text',text:item.text});
    else if(item.type==='local_image'){
      const bytes=await readFile(item.path);
      if(bytes.length>5_000_000)throw Error('Draw image exceeds 5 MB.');
      const mime=item.path.endsWith('.png')?'image/png':'image/jpeg';
      content.push({type:'input_image',image_url:`data:${mime};base64,${bytes.toString('base64')}`});
    }else throw Error('Unsupported Draw input.');
  }
  bounded.throwIfAborted();
  // JSON schema key order controls output order. Emit visual parts before narration.
  const order=['title','scene','diagram','annotations','cards','reply'];
  const orderedSchema=schema.properties?.scene?{...schema,properties:Object.fromEntries(order.map(name=>[name,schema.properties[name]]))}:schema;
  const response=await fetchImpl('https://api.openai.com/v1/responses',{
    method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},signal:bounded,
    body:JSON.stringify({model,reasoning:{effort:reasoningEffort},service_tier:tier==='standard'?'default':tier,store:false,stream:true,max_output_tokens:16000,
      input:[{role:'user',content}],text:{format:{type:'json_schema',name:'clip_visual',strict:true,schema:orderedSchema}}}),
  });
  // Never echo upstream bodies: they can contain credentials or submitted context.
  if(!response.ok){await response.body?.cancel();throw Error(`OpenAI Draw API rejected the request (${response.status}). Check API access, billing and the selected model.`);}
  if(!response.body)throw Error('OpenAI Draw returned no response stream.');
  const reader=response.body.getReader(),decoder=new TextDecoder();
  let buffer='',raw='',bytesRead=0,completed=null;
  const accept=block=>{
    const data=block.split(/\r?\n/).filter(line=>line.startsWith('data:')).map(line=>line.slice(5).trimStart()).join('\n');
    if(!data||data==='[DONE]')return;
    let event;try{event=JSON.parse(data);}catch{throw Error('OpenAI Draw returned an invalid stream event.');}
    if(event.type==='response.output_text.delta'){
      if(typeof event.delta!=='string')throw Error('Invalid Draw text event.');
      raw+=event.delta;
      if(raw.length>2_000_000)throw Error('Draw output is too large.');
      onText(raw);
    }else if(event.type==='response.output_text.done'){
      if(typeof event.text==='string'){raw=event.text;if(raw.length>2_000_000)throw Error('Draw output is too large.');onText(raw);}
    }else if(event.type==='response.completed'){
      if(event.response?.status!=='completed')throw Error('OpenAI Draw did not complete.');
      completed=event.response;
    }else if(['response.failed','response.incomplete','response.refusal.delta','response.refusal.done','error'].includes(event.type)){
      throw Error('OpenAI Draw could not complete this visual.');
    }
  };
  try{
    while(!completed){
      bounded.throwIfAborted();
      const {value,done}=await reader.read();
      if(done){buffer+=decoder.decode();if(buffer.trim())accept(buffer);break;}
      bytesRead+=value.byteLength;
      if(bytesRead>4_000_000)throw Error('Draw stream is too large.');
      buffer+=decoder.decode(value,{stream:true});
      let match;
      while((match=/\r?\n\r?\n/.exec(buffer))){
        const block=buffer.slice(0,match.index);buffer=buffer.slice(match.index+match[0].length);accept(block);
      }
    }
    bounded.throwIfAborted();
    if(!completed)throw Error('OpenAI Draw ended before completion.');
    const parts=completed.output?.filter(item=>item.type==='message').flatMap(item=>item.content??[])??[];
    if(parts.some(item=>item.type==='refusal'))throw Error('OpenAI Draw could not complete this visual.');
    const final=parts.filter(item=>item.type==='output_text').map(item=>item.text).join('');
    if(final){raw=final;if(raw.length>2_000_000)throw Error('Draw output is too large.');onText(raw);}
    if(!raw)throw Error('OpenAI Draw returned no visual.');
    return {raw,usage:completed.usage??null,serviceTier:completed.service_tier??null,transport:'openai-api'};
  }finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
}
