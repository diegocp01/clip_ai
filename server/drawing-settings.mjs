import { readFileSync } from 'node:fs';

// Shared with the native picker. OpenAI Draw uses API billing; Claude uses its CLI.
export const drawingModels = JSON.parse(readFileSync(new URL('../shared/drawing-models.json', import.meta.url), 'utf8'));
export function drawingSettings({provider='gpt', model, reasoningEffort}={}) {
  const choices = drawingModels.filter(item=>item.provider===provider);
  const selected = model == null ? choices[0] : choices.find(item=>item.id===model);
  if (!selected) throw new Error('Invalid drawing model for this provider.');
  const effort = reasoningEffort ?? 'low';
  if (!selected.efforts.includes(effort)) throw new Error('Invalid reasoning effort for this model.');
  return {model:selected.id, reasoningEffort:effort, name:selected.name,defaultTier:selected.defaultTier??'fast'};
}
export function assertDrawingTier(tier,provider,model){
  if(!['standard','fast','ultrafast'].includes(tier))throw Error('Invalid OpenAI Draw speed.');
  if(tier==='ultrafast'&&(provider!=='gpt'||!['gpt-6.1-sol','gpt-6-astra'].includes(model)))throw Error('Ultrafast speed is supported only for GPT-6.1 Sol and GPT-6 Astra.');
  return tier;
}
