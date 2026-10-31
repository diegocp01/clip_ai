// A virtual red cursor the voice can use to explain a visual. It only ever draws on the
// overlay page and moves its camera: the person's real mouse is never touched.
const clamp = (value, low, high) => Math.min(Math.max(value, low), high);
const ease = t => t * t * (3 - 2 * t);
const lerp = (a, b, t) => a + (b - a) * t;
const number = (value, fallback = 0) => (typeof value === 'number' && Number.isFinite(value) ? value : fallback);
const TAIL_LIFE = 650;
export const CURSOR_LIMIT = 6;

// What the voice is told it can point at, drawn from the visual on screen.
export function visualParts(result) {
  const parts = [...(result?.scene?.objects || []), ...(result?.diagram?.nodes || [])];
  const seen = new Set();
  return parts.filter(part => part?.id && !seen.has(part.id) && seen.add(part.id)).slice(0, 40).map(part => ({ id: part.id, label: part.label || part.id }));
}

// Tool arguments come from the model, so nothing runs until they are checked and bounded.
export function normalizeCursorSteps(args, { targets = [], canOrbit = false } = {}) {
  if (!args || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).some(key => key !== 'steps')) throw new Error('Invalid cursor request.');
  if (!Array.isArray(args.steps) || !args.steps.length || args.steps.length > CURSOR_LIMIT) throw new Error(`Send 1 to ${CURSOR_LIMIT} cursor steps.`);
  const known = new Set(targets);
  const target = step => {
    if (!known.has(step.target)) throw new Error(`Unknown part "${String(step.target).slice(0, 50)}". Known parts: ${[...known].slice(0, 40).join(', ')}.`);
    return step.target;
  };
  return args.steps.map(step => {
    if (!step || typeof step !== 'object') throw new Error('Invalid cursor step.');
    switch (step.action) {
      case 'point': case 'circle': case 'reveal': return { action: step.action, target: target(step) };
      case 'write': {
        const text = typeof step.text === 'string' ? step.text.trim() : '';
        if (!text || text.length > 60) throw new Error('Write 1 to 60 characters.');
        return { action: 'write', text, target: step.target === undefined ? null : target(step) };
      }
      case 'rotate': {
        if (!canOrbit) throw new Error('Only a 3D model can be rotated.');
        const yaw = clamp(number(step.yaw), -180, 180), pitch = clamp(number(step.pitch), -60, 60);
        if (!yaw && !pitch) throw new Error('Rotate needs a yaw or pitch in degrees.');
        return { action: 'rotate', yaw, pitch };
      }
      case 'zoom': {
        if (!canOrbit) throw new Error('Only a 3D model can be zoomed.');
        return { action: 'zoom', factor: clamp(number(step.factor, 1), 0.5, 2) };
      }
      case 'clear': return { action: 'clear' };
      default: throw new Error('Unknown cursor action.');
    }
  });
}

export function stepDuration(step) {
  switch (step.action) {
    case 'point': case 'reveal': return 700;
    case 'circle': return 1200;
    case 'write': return 450 + Math.min(step.text.length, 60) * 55;
    case 'rotate': return clamp(700 + Math.max(Math.abs(step.yaw), Math.abs(step.pitch)) * 9, 900, 2400);
    case 'zoom': return 800;
    default: return 120;
  }
}

// Plays steps over time. It knows nothing about the page, so it can be tested without one.
export class CursorPlayer {
  constructor({ locate = () => null, orbit = () => {}, zoom = () => {}, center = () => ({ x: 0, y: 0 }), reveal = () => {}, reducedMotion = false } = {}) {
    Object.assign(this, { locate, orbit, zoom, center, reveal, reducedMotion });
    this.queue = []; this.step = null; this.position = null; this.ink = []; this.tail = []; this.opacity = 0; this.idleSince = null;
    this.nextInk = 1;
  }
  get playing() { return Boolean(this.step || this.queue.length); }
  // A new request replaces what's still queued. Ink already on the visual stays.
  play(steps) { this.finishStep(); this.queue = [...steps]; this.idleSince = null; }
  // Stops moving right away without leaving a half-applied rotation to catch up on.
  cancel() { this.queue = []; this.step = null; }
  clearInk() { this.ink = []; }
  anchor(step) {
    if (step.target) {
      const place = this.locate(step.target);
      if (place) return place;
      // Out of view for now, such as while a panel scrolls to it: wait where it is.
      if (this.position) return { x: this.position.x, y: this.position.y, r: 24 };
    }
    const middle = this.center();
    return { x: middle.x, y: middle.y, r: 24 };
  }
  begin(now) {
    const step = this.queue.shift();
    const start = this.position || (() => { const middle = this.center(); return { x: middle.x + 60, y: middle.y + 60 }; })();
    this.step = { ...step, began: now, duration: this.reducedMotion ? 1 : stepDuration(step), from: { ...start }, progress: 0 };
    if (step.target) this.reveal(step.target, step.action === 'reveal');
    if (step.action === 'clear') this.clearInk();
    if (step.action === 'circle') { this.step.ink = { id: this.nextInk++, kind: 'circle', target: step.target, progress: 0 }; this.ink.push(this.step.ink); }
    if (step.action === 'write') {
      const place = this.anchor(step);
      this.step.ink = { id: this.nextInk++, kind: 'write', target: step.target, text: step.text, progress: 0, offsetX: place.noteX ?? (step.target ? place.r + 16 : -60), offsetY: place.noteY ?? (step.target ? -place.r * 0.4 : 0), x: place.x, y: place.y };
      this.ink.push(this.step.ink);
    }
    while (this.ink.length > 12) this.ink.shift();
  }
  // Applies whatever is left of the step, so skipping or replacing it still ends in the right place.
  apply(step, progress) {
    const eased = ease(progress), previous = step.progress;
    step.progress = eased;
    if (step.action === 'rotate') this.orbit((step.yaw * (eased - previous)) * Math.PI / 180, (step.pitch * (eased - previous)) * Math.PI / 180);
    if (step.action === 'zoom') this.zoom(Math.pow(step.factor, eased - previous));
    if (step.ink) step.ink.progress = clamp((progress - 0.35) / 0.65, 0, 1);
  }
  finishStep() {
    if (!this.step) return;
    this.apply(this.step, 1);
    this.step = null;
  }
  place(step, progress) {
    const eased = ease(progress);
    if (step.action === 'point' || step.action === 'reveal') {
      const place = this.anchor(step);
      return { x: lerp(step.from.x, place.x, eased), y: lerp(step.from.y, place.y, eased) };
    }
    if (step.action === 'circle' || step.action === 'write') {
      const place = this.anchor(step);
      const approach = ease(clamp(progress / 0.35, 0, 1)), drawn = ease(clamp((progress - 0.35) / 0.65, 0, 1));
      if (step.action === 'circle') {
        const angle = -Math.PI / 2 + drawn * Math.PI * 2;
        const onCircle = { x: place.x + Math.cos(angle) * ((place.rx ?? place.r) + 12), y: place.y + Math.sin(angle) * ((place.ry ?? place.r) + 12) };
        return { x: lerp(step.from.x, onCircle.x, approach), y: lerp(step.from.y, onCircle.y, approach) };
      }
      const width = step.text.length * 11, left = place.x + step.ink.offsetX;
      const onText = { x: left + drawn * width, y: place.y + step.ink.offsetY + 6 };
      return { x: lerp(step.from.x, onText.x, approach), y: lerp(step.from.y, onText.y, approach) };
    }
    if (step.action === 'rotate') {
      const middle = this.center(), sweep = clamp(step.yaw * 1.2, -170, 170), lift = clamp(step.pitch * 1.2, -70, 70);
      const grab = { x: middle.x - sweep / 2, y: middle.y - lift / 2 }, drop = { x: middle.x + sweep / 2, y: middle.y + lift / 2 };
      const approach = ease(clamp(progress / 0.25, 0, 1)), drag = ease(clamp((progress - 0.25) / 0.75, 0, 1));
      return { x: lerp(lerp(step.from.x, grab.x, approach), drop.x, drag), y: lerp(lerp(step.from.y, grab.y, approach), drop.y, drag) };
    }
    if (step.action === 'zoom') {
      const middle = this.center(), lift = step.factor > 1 ? -40 : 40;
      return { x: lerp(step.from.x, middle.x, ease(clamp(progress / 0.3, 0, 1))), y: lerp(step.from.y, middle.y + lift, eased) };
    }
    return { ...step.from };
  }
  // Advances to a moment in time and reports what should be on screen.
  advance(now) {
    if (!this.step && this.queue.length) this.begin(now);
    if (this.step) {
      const step = this.step, progress = clamp((now - step.began) / step.duration, 0, 1);
      this.apply(step, progress);
      this.position = this.place(step, progress);
      this.idleSince = null;
      if (progress >= 1) { this.step = null; if (this.queue.length) this.begin(now); else this.idleSince = now; }
    }
    if (this.position) { this.tail.push({ x: this.position.x, y: this.position.y, at: now }); }
    this.tail = this.tail.filter(point => now - point.at < TAIL_LIFE).slice(-80);
    const fading = this.idleSince === null ? 0 : clamp((now - this.idleSince - 1600) / 400, 0, 1);
    this.opacity = this.position ? 1 - fading : 0;
    if (fading >= 1) { this.position = null; this.idleSince = null; }
    return { position: this.position, opacity: this.opacity, tail: this.tail, ink: this.ink, now };
  }
  get active() { return this.playing || Boolean(this.position) || this.tail.length > 0 || this.ink.length > 0; }
}

const SVG = 'http://www.w3.org/2000/svg';
// Paints the player's state onto the overlay. Nothing here takes clicks.
export class VoiceCursor {
  constructor({ root, locate, orbit, zoom, center, reveal, schedule = callback => requestAnimationFrame(callback), clock = () => performance.now(), reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches }) {
    this.player = new CursorPlayer({ locate, orbit, zoom, center, reveal, reducedMotion });
    this.locate = locate; this.schedule = schedule; this.clock = clock; this.running = false;
    this.layer = document.createElement('div'); this.layer.id = 'voice-cursor'; this.layer.setAttribute('aria-hidden', 'true');
    this.canvas = document.createElement('canvas');
    this.inkLayer = document.createElementNS(SVG, 'svg');
    this.arrow = document.createElement('div'); this.arrow.className = 'voice-cursor-arrow';
    this.arrow.innerHTML = '<svg viewBox="0 0 24 24" width="24" height="24"><path d="M3 2 L20 11 L12.2 13.2 L8.6 21 Z" fill="#ff3b30" stroke="#fff" stroke-width="1.3" stroke-linejoin="round"/></svg>';
    this.layer.append(this.canvas, this.inkLayer, this.arrow); root.append(this.layer);
    this.drawn = new Map();
  }
  play(steps) { this.player.play(steps); this.wake(); }
  cancel() { this.player.cancel(); }
  clear() { this.player.clearInk(); this.wake(); }
  reset() { this.player.cancel(); this.player.clearInk(); this.wake(); }
  wake() { if (!this.running) { this.running = true; this.schedule(() => this.frame()); } }
  frame() {
    const state = this.player.advance(this.clock());
    this.paint(state);
    if (this.player.active) this.schedule(() => this.frame()); else this.running = false;
  }
  paint({ position, opacity, tail, ink, now }) {
    this.arrow.style.opacity = String(opacity);
    if (position) this.arrow.style.transform = `translate(${position.x - 3}px, ${position.y - 2}px)`;
    this.paintTail(tail, now); this.paintInk(ink);
  }
  paintTail(tail, now) {
    const { canvas } = this, ratio = window.devicePixelRatio || 1, width = this.layer.clientWidth, height = this.layer.clientHeight;
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) { canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio); }
    const context = canvas.getContext('2d');
    context.setTransform(ratio, 0, 0, ratio, 0, 0); context.clearRect(0, 0, width, height);
    context.lineCap = 'round';
    for (let i = 1; i < tail.length; i++) {
      const life = 1 - (now - tail[i].at) / TAIL_LIFE;
      context.strokeStyle = `rgba(255, 59, 48, ${(life * life * 0.75).toFixed(3)})`;
      context.lineWidth = 1 + life * 4.5;
      context.beginPath(); context.moveTo(tail[i - 1].x, tail[i - 1].y); context.lineTo(tail[i].x, tail[i].y); context.stroke();
    }
  }
  paintInk(ink) {
    const alive = new Set(ink.map(item => item.id));
    for (const [id, element] of this.drawn) if (!alive.has(id)) { element.remove(); this.drawn.delete(id); }
    for (const item of ink) {
      const place = item.target ? this.locate(item.target) : { x: item.x, y: item.y, r: 24 };
      let element = this.drawn.get(item.id);
      if (!element) {
        element = item.kind === 'circle' ? document.createElementNS(SVG, 'path') : document.createElementNS(SVG, 'text');
        element.setAttribute('class', `voice-ink voice-ink-${item.kind}`);
        // Plain text content only: the model's words are never parsed as markup.
        if (item.kind === 'circle') element.setAttribute('pathLength', '1'); else element.textContent = item.text;
        this.inkLayer.append(element); this.drawn.set(item.id, element);
      }
      element.style.display = place ? '' : 'none';
      if (!place) continue;
      if (item.kind === 'circle') {
        const rx = (place.rx ?? place.r) + 12, ry = (place.ry ?? place.r) + 12;
        element.setAttribute('d', `M ${place.x} ${place.y - ry} a ${rx} ${ry} 0 1 1 -0.01 0`);
        element.style.strokeDasharray = `${item.progress} 1`;
      } else {
        element.setAttribute('x', place.x + item.offsetX); element.setAttribute('y', place.y + item.offsetY);
        const shown = Math.ceil(item.text.length * item.progress);
        if (element.textContent.length !== shown) element.textContent = item.text.slice(0, shown);
      }
    }
  }
}
