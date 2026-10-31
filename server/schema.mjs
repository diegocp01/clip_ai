import Ajv from 'ajv';
import { chatSettings } from './chat-settings.mjs';
import { drawingSettings } from './drawing-settings.mjs';

const string = (maxLength = 1200) => ({ type: 'string', maxLength });
const number = (minimum, maximum) => ({ type: 'number', minimum, maximum });
const object = properties => ({ type: 'object', additionalProperties: false, properties, required: Object.keys(properties) });
const array = (items, maxItems) => ({ type: 'array', items, maxItems });
const vector = (min, max) => ({ ...array(number(min, max), 3), minItems: 3 });
const color = { type: 'string', pattern: '^#[a-fA-F0-9]{6}$' };
export const resultSchema = object({
  title: string(100), reply: string(3500),
  annotations: array(object({kind:{type:'string',enum:['rect','arrow','circle']},label:string(120),x:number(0,1),y:number(0,1),width:number(0,1),height:number(0,1)}),8),
  cards: array(object({ title: string(100), body: string(700) }), 6),
  diagram: object({
    nodes: array(object({ id: string(50), label: string(120), x: number(0,100), y: number(0,100), color }),24),
    links: array(object({ from: string(50), to: string(50), label: string(100) }),40),
  }),
  scene: object({ objects: array(object({
    id: string(50), label: string(100), description: string(700),
    shape: { type:'string',enum:['sphere','box','cylinder','cone','torus'] },
    color, position: vector(-10,10), scale: vector(0.05,5), rotation: vector(-6.284,6.284),
  }),40) }),
});
const requestSchema = object({
  message: { ...string(6000), minLength:1 },
  mode: {type:'string',enum:['chat','draw','auto']},
  drawing: {anyOf:[{type:'null'},object({provider:{type:'string',enum:['gpt','claude']},model:string(100),reasoningEffort:string(20)})]},
  tier: { type:'string',enum:['standard','fast'] },
  provider: { type:'string',enum:['gpt','claude'] },
  model: { anyOf:[{type:'null'},string(100)] },
  autoScope: {anyOf:[{type:'null'},{type:'string',enum:['all','gpt','claude']}]},
  reasoningEffort: { anyOf:[{type:'null'},string(20)] },
  history: array(object({ role: {type:'string',enum:['user','assistant']}, content:string(4000) }),12),
  previous: { anyOf:[{type:'null'},resultSchema] },
  image: { anyOf:[{type:'null'},{type:'string',maxLength:7_000_000,pattern:'^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$'}] },
});
const ajv = new Ajv({allErrors:true});
const validateResult = ajv.compile(resultSchema);
const validateRequest = ajv.compile(requestSchema);
export function assertResult(value) {
  // Old conversation visuals remain readable after the annotation upgrade.
  if (value && typeof value === 'object' && !('annotations' in value)) value.annotations=[];
  if (!validateResult(value)) throw new Error('The model returned an invalid visual. Please try again.');
  for (const collection of [value.scene.objects,value.diagram.nodes]) {
    if (new Set(collection.map(x=>x.id)).size !== collection.length) throw new Error('The model returned duplicate part IDs. Please try again.');
  }
  const ids = new Set(value.diagram.nodes.map(n=>n.id));
  if (value.diagram.links.some(l=>!ids.has(l.from)||!ids.has(l.to))) throw new Error('The model returned a link to a missing diagram node. Please try again.');
  return value;
}
export function normalizeRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Expected a JSON object.');
  const normalized = {autoScope:null,drawing:null,mode:'draw',tier:'fast',provider:'gpt',model:null,reasoningEffort:null,history:[],previous:null,image:null,...value};
  if (normalized.previous) assertResult(normalized.previous);
  if (!validateRequest(normalized)) throw new Error('Invalid request. Check the message, image size, speed and model settings.');
  if (!normalized.message.trim()) throw new Error('Enter a question first.');
  if (normalized.previous) assertResult(normalized.previous);
  if(normalized.mode==='auto') {
    if(!normalized.drawing)throw new Error('Automatic presentation needs Draw settings.');
    drawingSettings(normalized.drawing);
  } else if(normalized.drawing!==null)throw new Error('Draw settings are only accepted for automatic presentation.');
  if(normalized.model==='auto') {
    if(!['chat','auto'].includes(normalized.mode)||![null,'auto'].includes(normalized.reasoningEffort))throw new Error('Auto model and effort are available together for chat only.');
    if(normalized.autoScope && normalized.autoScope!=='all' && normalized.autoScope!==normalized.provider)throw new Error('Auto scope must match the selected provider.');
    return {...normalized,reasoningEffort:'auto',autoScope:normalized.autoScope??'all'};
  }
  if(normalized.autoScope!==null)throw new Error('Auto scope is only available with Auto chat models.');
  const {model,reasoningEffort}=(normalized.mode==='draw'?drawingSettings:chatSettings)(normalized);
  return {...normalized,model,reasoningEffort};
}
export function decodeImage(url) {
  if (!url) return null;
  const match = /^data:image\/(png|jpeg);base64,([A-Za-z0-9+/=]+)$/.exec(url);
  if (!match) throw new Error('Only PNG and JPEG images are supported.');
  const data = Buffer.from(match[2],'base64');
  const valid = match[1]==='png' ? data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) : data[0]===255&&data[1]===216&&data[2]===255;
  if (!valid || data.length > 5_000_000) throw new Error('Invalid image or image exceeds 5 MB.');
  return {data,extension:match[1]==='png'?'png':'jpg'};
}
