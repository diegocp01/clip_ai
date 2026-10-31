import { voiceKey } from './realtime.mjs';

export const SIGNAL_PATTERNS = Object.freeze({
  line:'A calm horizontal line drifting gently. Quiet presence or concentration.',
  eyes:'Two small blinking eyes. They can follow the pointer or look around independently.',
  wave:'A soft continuous wave. Thinking, creativity, or conversation.',
});
export const SIGNAL_MOTIONS = Object.freeze({
  follow:'React gently to the mouse anywhere inside the semicircle; wander calmly when it leaves.',
  wander:'Ignore the mouse and look around independently with slow, varied movement.',
  drift_left:'Ignore the mouse; glide left first, then return smoothly in a slow cycle.',
  drift_right:'Ignore the mouse; glide right first, then return smoothly in a slow cycle.',
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
        instructions:'Choose a restrained living green signal for Clip, a macOS assistant. Ready means open and waiting; working means answering; speaking means talking; attention means an issue. Prefer friendly eyes when ready, a wave for activity and a calm line for attention. This is decorative, never an emotion or a claim about the user.',
        choices:Object.entries(SIGNAL_PATTERNS).map(([value,description])=>({value,description})),
      },{
        type:'choice',name:'signal_motion',
        instructions:'Choose whether this decorative signal should attend to the mouse or move on its own. Follow can feel responsive when ready. Independent wandering or directional glides are also welcome, including while ready. Use restraint during work or speaking. This does not affect input handling and makes no claim about emotions or reasoning.',
        choices:Object.entries(SIGNAL_MOTIONS).map(([value,description])=>({value,description})),
      }]}),
    });
    if (!response.ok) return null;
    const data=await response.json();
    const answer=data.answers?.find(a=>a.name==='signal_pattern');
    const motion=data.answers?.find(a=>a.name==='signal_motion');
    return !signal.aborted && answer?.type==='choice' && Object.hasOwn(SIGNAL_PATTERNS,answer.choice) && motion?.type==='choice' && Object.hasOwn(SIGNAL_MOTIONS,motion.choice) ? {pattern:answer.choice,motion:motion.choice} : null;
  } catch { return null; }
}

// One bounded request at a time and at most one per 30 seconds, including failures.
// Reopening is instant; repeated hover/status changes cannot create an API loop.
export function createSignalDirector({choose=chooseSignalPattern,now=Date.now,cooldownMs=30000}={}) {
  let next=0,pending=null,last={pattern:'line',motion:'follow',source:'local'};
  return async state=>{
    if (!SIGNAL_STATES.includes(state)) throw new Error('Invalid signal state.');
    if (pending || now()<next) return last;
    next=now()+cooldownMs;
    pending=Promise.resolve().then(()=>choose(state));
    try {
      const choice=await pending;
      if (choice && Object.hasOwn(SIGNAL_PATTERNS,choice.pattern) && Object.hasOwn(SIGNAL_MOTIONS,choice.motion)) last={pattern:choice.pattern,motion:choice.motion,source:'decisions'};
    } catch { /* Keep a harmless local or previously selected pattern. */ }
    finally { pending=null; }
    return last;
  };
}
