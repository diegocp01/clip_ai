import {normalizeRequest,decodeImage} from './schema.mjs';
import {normalizeEditRequest} from './edit.mjs';

export function normalizeComparison(value) {
  if(!value||Array.isArray(value)||typeof value!=='object')throw Error('Expected a comparison request.');
  const allowed=value.task==='edit'?['task','text','action']:['task','message','image','settings'];
  if(Object.keys(value).some(k=>!allowed.includes(k))||!['chat','edit'].includes(value.task))throw Error('Both supports text answers and editing only, not Draw or voice.');
  if(value.task==='edit')return {task:'edit',...normalizeEditRequest({text:value.text,action:value.action})};
  const settings=value.settings??{};
  if(!settings||Array.isArray(settings)||typeof settings!=='object'||Object.keys(settings).some(k=>!['gpt','claude'].includes(k)))throw Error('Invalid comparison models.');
  const requests={};
  for(const provider of ['gpt','claude']) {
    const config=settings[provider]??{};
    if(!config||Array.isArray(config)||typeof config!=='object'||Object.keys(config).some(k=>!['model','reasoningEffort'].includes(k))||config.model==='auto')throw Error('Choose one explicit model per provider for Both.');
    requests[provider]=normalizeRequest({message:value.message,image:value.image??null,mode:'chat',provider,...config});
  }
  decodeImage(value.image);
  return {task:'chat',requests};
}

export async function runComparison(request,{run,runClaude,runEdit,checkAuth,checkClaude,routeEdit,signal,send}) {
  let action=request.action;
  if(request.task==='edit'&&action==='auto') {
    send({type:'status',message:'Choosing edit…'});
    action=await routeEdit(request,{signal})==='rewrite'?'rewrite':'proofread';
    signal.throwIfAborted();
  }
  await Promise.all(['gpt','claude'].map(async provider=>{
    const name=provider==='gpt'?'Codex':'Claude';
    try {
      signal.throwIfAborted();
      if(!await(provider==='gpt'?checkAuth():checkClaude()))throw Error(`Sign in to ${name} to compare its answer.`);
      signal.throwIfAborted();
      send({type:'comparison-status',provider,message:request.task==='edit'?(action==='rewrite'?'Rewriting…':'Proofreading…'):'Replying…'});
      const options={signal,onStatus:message=>{if(!signal.aborted)send({type:'comparison-status',provider,message});}};
      const output=request.task==='edit'?await runEdit({text:request.text,action,provider},options):await(provider==='gpt'?run:runClaude)(request.requests[provider],options);
      signal.throwIfAborted();
      const text=request.task==='edit'?output.result?.text:output.result?.reply;
      if(typeof text!=='string'||!text.trim()||text.length>24000)throw Error('No valid text answer returned.');
      send({type:'comparison-result',provider,text,model:output.model,reasoningEffort:output.reasoningEffort});
    }catch(error){if(!signal.aborted)send({type:'comparison-error',provider,message:String(error.message||error).slice(0,1600)});}
  }));
  signal.throwIfAborted();
  send({type:'comparison-complete'});
}
