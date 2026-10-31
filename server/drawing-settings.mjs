import { readFileSync } from 'node:fs';

// Shared with the native picker. Provider access is still enforced by its CLI.
export const drawingModels = JSON.parse(readFileSync(new URL('../shared/drawing-models.json', import.meta.url), 'utf8'));
export function drawingSettings({provider='gpt', model, reasoningEffort}={}) {
  const choices = drawingModels.filter(item=>item.provider===provider);
  const selected = model == null ? choices[0] : choices.find(item=>item.id===model);
  if (!selected) throw new Error('Invalid drawing model for this provider.');
  const effort = reasoningEffort ?? 'low';
  if (!selected.efforts.includes(effort)) throw new Error('Invalid reasoning effort for this model.');
  return {model:selected.id, reasoningEffort:effort, name:selected.name};
}
