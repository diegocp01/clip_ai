import {HTMLPanel,htmlParts} from './html-panel.js';
import { createScene, renderDiagram, sample } from './scene.js';
import { VoiceConversation } from './voice.js';
import { VoiceCursor,visualParts } from './cursor.js';

const $ = id => document.getElementById(id);
let current = null, part = null, streaming = false, liveVoice = false;
const htmlPanel=new HTMLPanel($('html-panel'));
let htmlResult=null;
function clearHTML(){htmlResult=null;htmlPanel.clear();}
const viewer = createScene($('scene-host'), selectPart);
function post(action, extra = {}) { window.webkit?.messageHandlers?.clippy?.postMessage({ action, ...extra }); }
function hidePart() { part = null; $('part').hidden = true; viewer.clearSelection(); }
function selectPart(selected) {
  part = selected; $('part-name').textContent = selected.label;
  $('part-description').textContent = selected.description; $('part').hidden = false;
}
function view(kind) {
  const scene = kind === 'scene'; $('scene-host').hidden = !scene; $('diagram-frame').hidden = scene;
  $('scene-tab').classList.toggle('active', scene); $('scene-tab').setAttribute('aria-pressed', String(scene));
  $('diagram-tab').classList.toggle('active', !scene); $('diagram-tab').setAttribute('aria-pressed', String(!scene));
  $('fit').hidden = !scene; $('scene-hint').hidden = !scene; hidePart();
}
function render(result, preview = false) {
  clearHTML();$('overlay').classList.remove('html-explanation');
  const preserveCamera = streaming; streaming = preview;
  // Marks made on the last visual don't belong on a new one.
  if (!preview && !preserveCamera) cursor.clear();
  current = result; $('overlay').hidden = false; $('demo-label').hidden = true;
  $('visual-title').textContent = (result.title || 'Clip') + (preview ? ' · Drawing…' : '');
  if(!liveVoice) {
    $('caption-text').textContent = result.reply || '';
    $('caption').hidden = !result.reply || Boolean(window.clippyCaptionManaged);
  }
  $('overlay').classList.toggle('no-caption', $('caption').hidden);
  const objects = result.scene?.objects || [], diagram = result.diagram || { nodes: [], links: [] };
  const cards = (result.cards || []).slice(0, 3);
  $('cards').replaceChildren();
  cards.forEach((card, i) => {
    const article = document.createElement('article'); article.className = 'explanation-card glass-surface';
    const number = document.createElement('span'); number.className = 'card-number'; number.textContent = String(i + 1).padStart(2, '0');
    const title = document.createElement('h2'); title.textContent = card.title;
    const body = document.createElement('p'); body.textContent = card.body;
    article.append(number, title, body); $('cards').append(article);
  });
  $('overlay').classList.toggle('has-cards', cards.length > 0);
  const hasScene = objects.length > 0, hasDiagram = diagram.nodes.length > 0;
  $('view-tabs').hidden = !(hasScene && hasDiagram);
  viewer.update(objects, false, preserveCamera, preview); renderDiagram($('diagram-host'), diagram, selectPart);
  view(hasScene ? 'scene' : 'diagram');
  if (!hasScene && !hasDiagram) { $('diagram-frame').hidden = true; $('fit').hidden = true; }
}
function renderHTML(result,preview=false){
  $('overlay').hidden=false;$('overlay').classList.add('html-explanation');
  $('visual-title').textContent=result.title+(preview?' · Building…':'');
  for(const id of ['scene-host','diagram-frame','view-tabs','fit','scene-hint','part','demo-label'])$(id).hidden=true;
  viewer.update([]);$('cards').replaceChildren();$('overlay').classList.remove('has-cards');
  htmlResult=result;if(!preview)cursor.clear();
  htmlPanel.render(result,preview);
}
window.clippyDismissVisual=()=>{voice.cancelVisual();cursor.reset();clearHTML();$('overlay').hidden=true;post('visualCleared');};
// The red cursor's coordinates are relative to the overlay, which is what it draws on.
function toOverlay(place) {
  const root = $('overlay').getBoundingClientRect();
  return { x: place.x - root.left, y: place.y - root.top, r: place.r };
}
function locatePart(id) {
  if (htmlResult) { const place = htmlPanel.locate(id); return place ? { ...toOverlay(place), rx: place.rx, ry: place.ry, noteX: place.noteX, noteY: place.noteY } : null; }
  const showing = !$('scene-host').hidden;
  if (showing) { const place = viewer.locate(id); if (place) return toOverlay(place); }
  else {
    const node = [...$('diagram-host').querySelectorAll('[data-part]')].find(item => item.dataset.part === id);
    if (node) {
      const rect = node.getBoundingClientRect();
      return toOverlay({ x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, r: Math.max(rect.width, rect.height) / 2 });
    }
  }
  return null;
}
const cursor = new VoiceCursor({
  root: $('overlay'), locate: locatePart,
  orbit: (yaw, pitch) => viewer.orbit(yaw, pitch), zoom: factor => viewer.zoom(factor),
  reveal: id => { if (htmlResult) htmlPanel.reveal(id); },
  center: () => {
    const root = $('overlay').getBoundingClientRect();
    if (!htmlResult) return { x: root.width / 2, y: root.height / 2 };
    const panel = $('html-panel').getBoundingClientRect();
    return { x: panel.left - root.left + panel.width / 2, y: panel.top - root.top + panel.height / 2 };
  },
});
const hasScene = () => !htmlResult && Boolean(current?.scene?.objects?.length);
// A part the voice names may be in the other view, so show the one that has it.
function showPartView(steps) {
  if (!hasScene() || !current?.diagram?.nodes?.length) return;
  const inScene = new Set(current.scene.objects.map(part => part.id));
  const wanted = steps.find(step => step.target || step.action === 'rotate' || step.action === 'zoom');
  if (!wanted) return;
  const scene = wanted.action === 'rotate' || wanted.action === 'zoom' || inScene.has(wanted.target);
  if (scene === $('scene-host').hidden) view(scene ? 'scene' : 'diagram');
}
const voiceCursor = {
  parts: () => ($('overlay').hidden ? [] : htmlResult ? htmlParts(htmlResult) : visualParts(current)),
  canOrbit: () => !$('overlay').hidden && hasScene(),
  play: steps => { showPartView(steps); cursor.play(steps); },
  cancel: () => cursor.cancel(),
  reset: () => cursor.reset(),
};
window.clippyCursor = voiceCursor;
// If the person takes hold of the drawing themselves, the cursor gets out of the way.
$('scene-host').addEventListener('pointerdown', () => cursor.cancel());
$('html-panel').addEventListener('load', () => {
  for (const type of ['pointerdown', 'wheel']) $('html-panel').contentDocument?.addEventListener(type, () => cursor.cancel(), { passive: true });
});
window.clippyRender = render;
window.clippyRollback = result => { streaming = false; if(result)render(result);else{$('overlay').hidden=true;post('visualCleared');} };
let voiceGeneration = 0;
const pendingScreens = new Map();
let screenRequestID = 0;
function captureScreen({signal}) {
  if(!window.webkit?.messageHandlers?.clippy) return Promise.reject(new Error('Automatic screen capture requires the native Clip app.'));
  return new Promise((resolve,reject)=>{
    const id = String(++screenRequestID);
    const finish=(image,error)=>{clearTimeout(timer);signal.removeEventListener('abort',abort);pendingScreens.delete(id);error?reject(new Error(error)):resolve(image);};
    const abort=()=>finish(null,'Voice ended before the screenshot was shared.');
    const timer=setTimeout(()=>finish(null,'Screen capture timed out.'),10000);
    if(signal.aborted){abort();return;}
    signal.addEventListener('abort',abort,{once:true});pendingScreens.set(id,finish);
    post('voiceCaptureScreen',{id,generation:voiceGeneration});
  });
}
const voice = new VoiceConversation({
  captureScreen,
  cursor: voiceCursor,
  renderHTML:result=>{renderHTML(result);post('voicePreview',{generation:voiceGeneration});},
  previewHTML:result=>{renderHTML(result,true);post('voicePreview',{generation:voiceGeneration});},
  rollbackHTML:result=>{if(result)renderHTML(result);else{clearHTML();$('overlay').hidden=true;post('visualCleared');}},
  notify: event => {
    if(event.state==='connecting')liveVoice=true;
    if(['ended','error'].includes(event.state))liveVoice=false;
    if(event.state==='transcript') {
      $('caption-text').textContent=event.message;
      $('caption').hidden=Boolean(window.clippyCaptionManaged)||!event.message;
    }
    if(['transcript-start','transcript-cleared'].includes(event.state))$('caption').hidden=true;
    $('overlay').classList.toggle('no-caption', $('caption').hidden);
    post('voiceState',{...event,generation:voiceGeneration});
  },
  render: result => { render(result); post('voiceVisual',{result,generation:voiceGeneration}); },
  preview: result => { render(result,true); post('voicePreview',{generation:voiceGeneration}); },
  rollback: result => window.clippyRollback(result),
});
window.clippyVoice = {
  start: generation => {voiceGeneration=generation;return voice.start();}, stop: () => voice.stop(),
  shareScreen: image => voice.shareScreen(image),
  setPointSharing: enabled => voice.setPointSharing(enabled),
  sharePoint: (image,context) => voice.sharePoint(image,context),
  finishScreenCapture: (id,image,error) => pendingScreens.get(id)?.(image,error),
  setVisual: result => { voice.previous=result;if(!result){voice.previousHTML=null;clearHTML();} },
  setMuted: value => voice.setMuted(value),
  setProvider: value => voice.setProvider(value),
  setDrawingSettings: value => voice.setDrawingSettings(value),
};
window.addEventListener('pagehide',()=>voice.stop());
window.clippyHitTest = (x, y) => {
  if (!Number.isFinite(x) || !Number.isFinite(y) || $('overlay').hidden) return false;
  // elementFromPoint also respects clipping and hidden ancestors. Only real
  // painted controls/cards count; the transparent stage and its canvas do not.
  const element = document.elementFromPoint(x, y);
  const control = element?.closest('.overlay-tools, .scene-label, .explanation-card, #diagram-frame, #html-panel, #part, #caption, .scene-fallback');
  if (control) {
    const style = getComputedStyle(control);
    if (style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0' &&
      [...control.getClientRects()].some(rect => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom)) return true;
  }
  return !$('scene-host').hidden && viewer.hitTest(x, y);
};
$('scene-tab').addEventListener('click', () => view('scene'));
$('diagram-tab').addEventListener('click', () => view('diagram'));
$('fit').addEventListener('click', () => viewer.reset());
$('part-close').addEventListener('click', hidePart);
$('part-ask').addEventListener('click', () => {
  if (!part) return;
  post('followup', { text: `Explain ${part.label} in ${current?.title || 'this visual'}. Highlight it in the visual.` }); hidePart();
});
$('drag-handle').addEventListener('mousedown', event => { if (event.button === 0) { event.preventDefault(); post('dragOverlay'); } });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') { if (!$('part').hidden) hidePart(); else { window.clippyDismissVisual(); post('closeOverlay'); } }
});
if (new URLSearchParams(location.search).get('demo') === 'water') { render(sample); $('demo-label').hidden = false; }
if(new URLSearchParams(location.search).get('demo')==='html')renderHTML({title:'Inputs and targets',sections:[{html:'<h1>Make a question and its answer</h1><p>A language model learns from a sequence by predicting the next token.</p>'},{html:'<table><thead><tr><th>Input tensor</th><th>Target: known answer</th></tr></thead><tbody><tr><td>[18]</td><td>47</td></tr><tr><td>[18, 47]</td><td>56</td></tr></tbody></table><details><summary>Why does the input grow?</summary><p>Each step adds the previous token as context. The target is the next token in the original sequence.</p></details>'}],summary:'Illustrative token prediction example.'});
// A way to see the cursor without a live voice session: /overlay.html?demo=water&cursor=1 or demo=html&cursor=1
if (new URLSearchParams(location.search).get('cursor') === '1' && htmlResult) {
  const parts = voiceCursor.parts();
  setTimeout(() => voiceCursor.play([{ action: 'point', target: parts[0].id }, { action: 'circle', target: parts[1].id }, { action: 'write', text: 'Next token', target: parts[1].id }, { action: 'circle', target: parts.at(-1).id }]), 800);
}
if (new URLSearchParams(location.search).get('cursor') === '1' && current) {
  setTimeout(() => voiceCursor.play([{ action: 'point', target: 'oxygen' }, { action: 'circle', target: 'oxygen' }, { action: 'write', text: 'Pulls electrons', target: 'oxygen' }, { action: 'rotate', yaw: 70, pitch: -15 }, { action: 'circle', target: 'hydrogen-1' }, { action: 'write', text: 'Slightly positive', target: 'hydrogen-1' }]), 800);
}
post('ready');
