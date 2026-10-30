import { writeFile,mkdir } from 'node:fs/promises';
import { generate,authStatus } from '../server/codex.mjs';
import { normalizeRequest } from '../server/schema.mjs';

if(!await authStatus())throw new Error('Codex ChatGPT login is required. Run codex login.');
const request=normalizeRequest({message:'Explain a water molecule with a small labeled 3D ball-and-stick model. State that it is a schematic.',tier:process.env.CLIPPY_SMOKE_TIER||'fast'});
const output=await generate(request,{signal:AbortSignal.timeout(120000),onStatus:message=>console.log(message)});
await mkdir('research/evidence',{recursive:true});
await writeFile(`research/evidence/live-${output.model}-${request.tier}.json`,JSON.stringify(output,null,2));
console.log(JSON.stringify({title:output.result.title,parts:output.result.scene.objects.length,elapsedMs:output.elapsedMs,model:output.model,reasoningEffort:output.reasoningEffort,requestedTier:output.requestedTier,usage:output.usage},null,2));
