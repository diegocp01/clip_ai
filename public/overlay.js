import { createScene, renderDiagram, sample } from './scene.js';
import { VoiceConversation } from './voice.js';

const $ = id => document.getElementById(id);
let current = null, part = null, streaming = false, liveVoice = false;
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
  const preserveCamera = streaming; streaming = preview;
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
window.clippyRender = render;
window.clippyRollback = result => { streaming = false; if(result)render(result);else $('overlay').hidden=true; };
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
  setVisual: result => { voice.previous=result; },
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
  const control = element?.closest('.overlay-tools, .scene-label, .explanation-card, #diagram-frame, #part, #caption, .scene-fallback');
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
$('close').addEventListener('click', () => { $('overlay').hidden = true; post('closeOverlay'); });
$('part-close').addEventListener('click', hidePart);
$('part-ask').addEventListener('click', () => {
  if (!part) return;
  post('followup', { text: `Explain ${part.label} in ${current?.title || 'this visual'}. Highlight it in the visual.` }); hidePart();
});
$('drag-handle').addEventListener('mousedown', event => { if (event.button === 0) { event.preventDefault(); post('dragOverlay'); } });
document.addEventListener('keydown', event => {
  if (event.key === 'Escape') { if (!$('part').hidden) hidePart(); else { $('overlay').hidden = true; post('closeOverlay'); } }
});
if (new URLSearchParams(location.search).get('demo') === 'water') { render(sample); $('demo-label').hidden = false; }
post('ready');
