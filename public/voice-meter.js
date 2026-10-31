// Local level-only metering. Audio stays in the existing WebRTC session;
// the native animation receives separate normalized input/output levels, never samples.
export function voiceLevel(samples) {
  if (!samples.length) return 0;
  let sum = 0;
  for (const value of samples) sum += Number.isFinite(value) ? value * value : 0;
  return Math.min(1, Math.max(0, (Math.sqrt(sum / samples.length) - 0.008) * 7));
}
export class VoiceMeter {
  constructor(notify, {Context = globalThis.AudioContext || globalThis.webkitAudioContext,
    schedule = setInterval, cancel = clearInterval} = {}) {
    this.notify = notify; this.cancel = cancel; this.nodes = new Map(); this.muted = false;
    if (!Context) return;
    try {
      this.context = new Context();
      this.silent = this.context.createGain(); this.silent.gain.value = 0;
      this.silent.connect(this.context.destination);
      this.context.resume().catch(() => {});
      this.timer = schedule(() => this.sample(), 1000 / 30);
    } catch { this.stop(); }
  }
  attach(name, stream) {
    if (!this.context) return;
    try {
      const old = this.nodes.get(name); old?.source.disconnect(); old?.analyser.disconnect();
      this.nodes.delete(name);
      const source = this.context.createMediaStreamSource(stream), analyser = this.context.createAnalyser();
      analyser.fftSize = 512; source.connect(analyser); analyser.connect(this.silent);
      this.nodes.set(name, {source, analyser, data: new Float32Array(analyser.fftSize)});
    } catch { /* Optional decoration must never interrupt Talk. */ }
  }
  sample() {
    const levels = {input:0, output:0};
    for (const [name, node] of this.nodes) {
      if (name === 'output' && this.muted) continue;
      try { node.analyser.getFloatTimeDomainData(node.data); if(name==='input'||name==='output')levels[name] = voiceLevel(node.data); }
      catch { /* A detached stream settles to zero. */ }
    }
    this.notify(levels);
  }
  stop() {
    if (this.timer !== undefined) this.cancel(this.timer);
    this.timer = undefined;
    for (const node of this.nodes.values()) { node.source.disconnect(); node.analyser.disconnect(); }
    this.nodes.clear(); this.silent?.disconnect();
    if (this.context) void this.context.close().catch(() => {});
    this.context = null;
  }
}
