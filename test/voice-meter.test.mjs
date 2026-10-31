import test from 'node:test';
import assert from 'node:assert/strict';
import {VoiceMeter, voiceLevel} from '../public/voice-meter.js';

test('voice level ignores room noise, follows signal energy and clamps peaks', () => {
  assert.equal(voiceLevel(new Float32Array(512)), 0);
  assert.equal(voiceLevel(new Float32Array(512).fill(0.004)), 0);
  assert.ok(voiceLevel(new Float32Array(512).fill(0.05)) > 0.2);
  assert.equal(voiceLevel(new Float32Array(512).fill(1)), 1);
  assert.equal(voiceLevel(new Float32Array([NaN, Infinity])), 0);
});
test('meter combines input and output, suppresses muted output and tears down without stopping tracks', () => {
  const levels = [], sources = []; let tick, cancelled, closed = 0;
  class Context {
    destination = {};
    createGain() { return {gain:{value:1}, connect(){}, disconnect(){}}; }
    createMediaStreamSource(stream) {
      const source = {stream, connect(node){ node.stream = stream; }, disconnect(){ this.disconnected = true; }};
      sources.push(source); return source;
    }
    createAnalyser() { return {connect(){}, disconnect(){}, getFloatTimeDomainData(data){ data.fill(this.stream.amplitude); }}; }
    async resume() {} async close() { closed++; }
  }
  const meter = new VoiceMeter(level => levels.push(level), {Context, schedule:fn=>{tick=fn;return 42;},cancel:id=>{cancelled=id;}});
  meter.attach('input', {amplitude:0.004});meter.attach('output', {amplitude:0.1});tick();
  assert.ok(levels.at(-1).output > 0.6);assert.equal(levels.at(-1).input,0);
  meter.muted = true; tick();assert.deepEqual(levels.at(-1),{input:0,output:0});
  meter.attach('input', {amplitude:0.05});tick();assert.ok(levels.at(-1).input>0.2);
  assert.equal(sources[0].disconnected,true);
  meter.stop();assert.equal(cancelled,42);assert.equal(closed,1);
  assert.ok(sources.every(s=>s.disconnected));assert.equal(meter.nodes.size,0);
  meter.stop();assert.equal(closed,1);
});
test('missing audio context leaves voice metering optional', () => {
  const meter = new VoiceMeter(()=>assert.fail('no synthetic levels'),{Context:null});
  meter.attach('input',{});meter.stop();
});
