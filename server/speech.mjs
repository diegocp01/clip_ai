import {voiceKey} from './realtime.mjs';

export const SPEECH_VOICES=Object.freeze(['marin','cedar','coral','ash','alloy','ballad','echo','fable','nova','onyx','sage','shimmer','verse']);
export const SPEECH_MODEL='gpt-4o-mini-tts';
export function normalizeSpeech(body) {
  if(!body||Array.isArray(body)||typeof body!=='object'||Object.keys(body).some(k=>!['text','voice'].includes(k)))throw Error('Expected reply text and voice.');
  if(typeof body.text!=='string'||!body.text.trim()||body.text.length>3500)throw Error('Speech text must contain 1–3500 characters.');
  const voice=body.voice??'marin';
  if(!SPEECH_VOICES.includes(voice))throw Error('Unknown reply voice.');
  return {text:body.text,voice};
}
export async function synthesizeSpeech(body,{signal,fetchImpl=fetch,getKey=voiceKey}={}) {
  const {text,voice}=normalizeSpeech(body);
  const key=await getKey();if(!key)throw Error('Set up the OpenAI API key for spoken replies.');
  const bounded=signal?AbortSignal.any([signal,AbortSignal.timeout(45000)]):AbortSignal.timeout(45000);
  bounded.throwIfAborted();
  const response=await fetchImpl('https://api.openai.com/v1/audio/speech',{method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:JSON.stringify({model:SPEECH_MODEL,voice,input:text,response_format:'mp3',instructions:'Read the supplied text exactly as written. Speak calmly, naturally and clearly. Do not add a greeting, commentary or sound effects.'}),signal:bounded});
  if(!response.ok)throw Error(`OpenAI speech unavailable (${response.status}). Check API access and billing.`);
  const chunks=[];let size=0;
  for await(const chunk of response.body){bounded.throwIfAborted();size+=chunk.length;if(size>8*1024*1024){throw Error('Speech response too large.');}chunks.push(chunk);}
  if(!size)throw Error('OpenAI returned no speech.');
  return Buffer.concat(chunks);
}
