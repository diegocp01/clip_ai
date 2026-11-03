import test from 'node:test';
import assert from 'node:assert/strict';
import {VoiceTranscript} from '../public/voice-transcript.js';
const delta=(text,extra={})=>({type:'response.output_audio_transcript.delta',delta:text,response_id:'r1',...extra});
test('full audio transcript survives beyond former 500 and 1500 character limits',()=>{
 const t=new VoiceTranscript();t.begin('r1');const full='Molecules form bonds. '.repeat(180)+'Final sentence.';
 for(let i=0;i<full.length;i+=17)t.update(delta(full.slice(i,i+17)));
 assert.equal(t.text(),full);
});
test('authoritative done transcript replaces deltas without repeating words',()=>{
 const t=new VoiceTranscript();t.begin('r1');t.update(delta('Water has too'));
 assert.equal(t.update({type:'response.output_audio_transcript.done',response_id:'r1',transcript:'Water has two hydrogen atoms.'}),'Water has two hydrogen atoms.');
 assert.equal(t.finish({id:'r1',status:'completed',output:[{type:'message',content:[{type:'audio',transcript:'Water has two hydrogen atoms.'}]}]}),'Water has two hydrogen atoms.');
});
test('ordered content parts stay distinct and stale or interrupted speech cannot replace the next reply',()=>{
 const t=new VoiceTranscript();t.begin('r1');t.update(delta('Second',{output_index:1}));t.update(delta('First',{output_index:0}));assert.equal(t.text(),'First\n\nSecond');
 t.interrupt();assert.equal(t.update(delta('unplayed')),null);assert.equal(t.finish({id:'r1',status:'completed',output:[{content:[{type:'audio',transcript:'late'}]}]}),null);
 t.begin('r2');assert.equal(t.update(delta('old')),null);assert.equal(t.update(delta('New',{response_id:'r2'})),'New');
 assert.equal(t.finish({id:'r2',status:'cancelled',output:[{content:[{type:'audio',transcript:'unspoken ending'}]}]}),null);
});
test('text summaries and drawing function output never become spoken captions',()=>{
 const t=new VoiceTranscript();t.begin('r1');t.update(delta('These atoms share electrons.'));
 assert.equal(t.finish({id:'r1',status:'completed',output:[{type:'function_call',name:'draw_visual',arguments:'summary'},{type:'message',content:[{type:'output_text',text:'Different drawing summary'}]}]}),null);
 assert.equal(t.text(),'These atoms share electrons.');
});
