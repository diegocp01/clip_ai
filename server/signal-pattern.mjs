import { voiceKey } from './realtime.mjs';

export const SIGNAL_PATTERNS = Object.freeze({
  line:'A calm horizontal line drifting gently. Quiet presence or concentration.',
  eyes:'Two small curious eyes looking toward the pointer and blinking. Welcoming or attentive.',
  wave:'A soft continuous wave. Thinking, creativity, or conversation.',
});
export const SIGNAL_STATES = Object.freeze(['ready','working','speaking','attention']);

// Cosmetic only. Send coarse app state, never the draft, selection, screen or conversation.
export async function chooseSignalPattern(state,{fetchImpl=fetch,getKey=voiceKey,timeoutMs=2500}={}) {
  if (!SIGNAL_STATES.includes(state)) return null;
  const signal=AbortSignal.timeout(timeoutMs);
  try {
    const key=await getKey();
    if (!key || signal.aborted) return null;
    const response=await fetchImpl('https://api.openai.com/v1/decisions',{
      method:'POST',headers:{Authorization:`Bearer ${key}`,'Content-Type':'application/json'},signal,
      body:JSON.stringify({model:'gpt-6-luna',input:JSON.stringify({state}),questions:[{
        type:'choice',name:'signal_pattern',
        instructions:'Choose a restrained living green signal for Clippy, a macOS assistant. Ready means open and waiting; working means answering; speaking means talking; attention means an issue. Prefer friendly eyes when ready, a wave for activity and a calm line for attention. This is decorative, never an emotion or a claim about the user.',
        choices:Object.entries(SIGNAL_PATTERNS).map(([value,description])=>({value,description})),
      }]}),
    });
    if (!response.ok) return null;
    const data=await response.json();
    const answer=data.answers?.find(a=>a.name==='signal_pattern');
    return !signal.aborted && answer?.type==='choice' && Object.hasOwn(SIGNAL_PATTERNS,answer.choice) ? answer.choice : null;
  } catch { return null; }
}

// One bounded request at a time and at most one per 30 seconds, including failures.
// Reopening is instant; repeated hover/status changes cannot create an API loop.
export function createSignalDirector({choose=chooseSignalPattern,now=Date.now,cooldownMs=30000}={}) {
  let next=0,pending=null,last={pattern:'line',source:'local'};
  return async state=>{
    if (!SIGNAL_STATES.includes(state)) throw new Error('Invalid signal state.');
    if (pending || now()<next) return last;
    next=now()+cooldownMs;
    pending=Promise.resolve().then(()=>choose(state));
    try {
      const pattern=await pending;
      if (Object.hasOwn(SIGNAL_PATTERNS,pattern)) last={pattern,source:'decisions'};
    } catch { /* Keep a harmless local or previously selected pattern. */ }
    finally { pending=null; }
    return last;
  };
}
