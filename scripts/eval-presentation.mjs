// Opt-in live regression check. Uses the existing local API key and makes one
// Decisions request per fixture; never run this as part of offline tests/CI.
import {readFile} from 'node:fs/promises';
import {choosePresentation} from '../server/presentation.mjs';
import {voiceKey} from '../server/realtime.mjs';

if(!await voiceKey())throw new Error('Presentation evaluation needs the existing local OpenAI API key.');
const cases=JSON.parse(await readFile(new URL('../test/fixtures/presentation-cases.json',import.meta.url),'utf8'));
let failed=0;
for(const {message,expected} of cases){
  const actual=await choosePresentation({message});
  const passed=actual===expected;if(!passed)failed++;
  console.log(JSON.stringify({passed,expected,actual,message}));
}
console.log(`${cases.length-failed}/${cases.length} live presentation cases passed.`);
if(failed)process.exitCode=1;
