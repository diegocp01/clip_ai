import { readEvents } from './stream.js';
import { createScene, renderDiagram, sample } from './scene.js';

const $ = id => document.getElementById(id);
const state = { result: null, history: [], image: null, controller: null, token: null, part: null, start: 0, timer: null, listening: false };
const viewer = createScene($('scene-host'), selectPart);
viewer.update(sample.scene.objects, true);

function error(message) { $('error-text').textContent = message; $('error').hidden = false; }
function clearError() { $('error').hidden = true; }
function setStatus(message) { $('progress-text').textContent = message; }
function native() { return window.clippyNative && window.webkit?.messageHandlers?.clippy; }
function nativeAction(action, text) { native()?.postMessage({ action, ...(text ? { text } : {}) }); }
function resizePrompt() { $('prompt').style.height = 'auto'; $('prompt').style.height = `${Math.min($('prompt').scrollHeight, 130)}px`; }
function busy(value) {
  $('send-button').hidden = value; $('cancel-button').hidden = !value; $('progress').hidden = !value;
  $('tier').disabled = value; $('reset-button').disabled = value; $('prompt').readOnly = value; $('composer').setAttribute('aria-busy', String(value));
  for (const button of document.querySelectorAll('#starters button, #attach-button, #screen-button, #part-ask')) button.disabled = value;
  if (value) {
    state.start = performance.now(); $('elapsed').textContent = '0s';
    state.timer = setInterval(() => { $('elapsed').textContent = `${Math.floor((performance.now() - state.start) / 1000)}s`; }, 1000);
  } else { clearInterval(state.timer); state.timer = null; }
}
function updateHistory() {
  $('history-count').textContent = String(state.history.filter(m => m.role === 'user').length);
  $('conversation-items').replaceChildren();
  for (const message of state.history) {
    const block = document.createElement('div'); block.className = `history-message ${message.role}`;
    const label = document.createElement('strong'); label.textContent = message.role === 'user' ? 'You' : 'Clip';
    const text = document.createElement('span'); text.textContent = message.content; block.append(label, text); $('conversation-items').append(block);
  }
}
function switchView(kind) {
  const is3d = kind === 'scene'; $('scene-host').hidden = !is3d; $('diagram-host').hidden = is3d;
  $('scene-tab').classList.toggle('active', is3d); $('diagram-tab').classList.toggle('active', !is3d);
  $('scene-tab').setAttribute('aria-pressed', String(is3d)); $('diagram-tab').setAttribute('aria-pressed', String(!is3d));
  $('fit-button').hidden = !is3d;
  $('visual-hint').textContent = is3d ? '↔  Drag to orbit · Scroll to zoom · Pick a part' : 'Choose a part to explore it';
  closePart();
}
function selectPart(part) { state.part = part; $('part-title').textContent = part.label; $('part-description').textContent = part.description; $('part-detail').hidden = false; }
function closePart() { state.part = null; $('part-detail').hidden = true; viewer.clearSelection(); }
function renderResult(result, metadata = {}) {
  if(!metadata.preview)state.result = result;
  $('result-title').textContent = result.title; $('result-reply').textContent = result.reply;
  $('result-label').textContent = metadata.preview ? 'DRAWING…' : 'LET’S MAKE SENSE OF IT'; $('sample-badge').hidden = true; $('starters').hidden = true;
  $('visual-label').textContent = 'A NEW WAY TO LOOK AT IT';
  $('answer-cards').replaceChildren();
  result.cards.forEach((card, i) => {
    const article = document.createElement('article'); article.className = 'answer-card glass-surface';
    const title = document.createElement('h3'); const number = document.createElement('span'); number.className = 'number'; number.textContent = String(i + 1).padStart(2, '0');
    title.append(number, document.createTextNode(card.title)); const body = document.createElement('p'); body.textContent = card.body; article.append(title, body); $('answer-cards').append(article);
  });
  const hasScene = result.scene.objects.length > 0, hasDiagram = result.diagram.nodes.length > 0;
  viewer.update(result.scene.objects, false, Boolean(metadata.preserveCamera), Boolean(metadata.preview)); renderDiagram($('diagram-host'), result.diagram, selectPart);
  $('scene-tab').hidden = !hasScene; $('diagram-tab').hidden = !hasDiagram; $('visual-empty').hidden = hasScene || hasDiagram;
  switchView(hasScene ? 'scene' : 'diagram');
  $('scene-count').textContent = hasScene ? `${result.scene.objects.length} parts to explore` : `${result.diagram.nodes.length} connected ideas`;
  if (!hasScene && !hasDiagram) $('visual-hint').textContent = 'Ask a follow-up to explore the idea';
  $('speak-button').disabled = !canSpeak();
  $('result-meta').hidden = false;
  const seconds = metadata.elapsedMs ? `${(metadata.elapsedMs / 1000).toFixed(1)}s` : '';
  $('result-meta').textContent = [metadata.model || 'GPT-6.1 Terra', metadata.reasoningEffort ? `${metadata.reasoningEffort} reasoning` : '', metadata.requestedTier ? `${metadata.requestedTier} requested` : '', seconds].filter(Boolean).join(' · ');
}
async function loadSession() {
  const [sessionResponse, statusResponse] = await Promise.all([fetch('/api/session'), fetch('/api/status')]);
  if (!sessionResponse.ok || !statusResponse.ok) throw new Error('Could not connect to the local Clip server.');
  const session = await sessionResponse.json(), status = await statusResponse.json(); state.token = session.token;
  const connected = Boolean(status.authenticated);
  $('connection').className = `connection ${connected ? 'connected' : 'disconnected'}`;
  $('connection').lastElementChild.textContent = connected ? 'Codex is connected' : 'Codex sign-in needed';
  if (!connected) error('Sign in with ChatGPT using “codex login” in Terminal, then reload Clip.');
}
async function send(message) {
  message = message.trim(); if (!message || state.controller) return;
  clearError(); closePart(); window.speechSynthesis?.cancel(); nativeAction('stopSpeaking');
  if (!state.token) { try { await loadSession(); } catch (e) { error(e.message); return; } }
  const history = state.history.slice(-12).map(m => ({ role: m.role, content: m.content.slice(0, 4000) }));
  const previous = state.result; const image = state.image;
  state.controller = new AbortController(); busy(true); setStatus('Thinking it through…');
  let received = false, previewing = false;
  try {
    const response = await fetch('/api/chat', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Clippy-Session': state.token }, body: JSON.stringify({ message, tier: $('tier').value, history, previous, image }), signal: state.controller.signal });
    if (!response.ok) {
      let reason = `Request failed (${response.status})`;
      try { const data = await response.json(); reason = data.error || data.message || reason; } catch { /* Keep HTTP status. */ }
      throw new Error(reason);
    }
    if (!response.body) throw new Error('The server returned no response stream.');
    function handle(event) {
      if(event.type === 'preview'){renderResult(event.result,{preview:true,preserveCamera:previewing});previewing=true;}
      if (event.type === 'status') setStatus(event.message);
      if (event.type === 'error') throw new Error(event.message);
      if (event.type === 'result') {
        renderResult(event.result, {...event,preserveCamera:previewing}); received = true; previewing=false;
        state.history.push({ role: 'user', content: message + (image ? '\n[Image attached]' : '') }, { role: 'assistant', content: event.result.reply });
        updateHistory(); $('prompt').value = ''; resizePrompt(); removeImage();
      }
    }
    for await(const event of readEvents(response))handle(event);
    if (!received) throw new Error('Codex finished without a visual answer. Your question is still here; try again.');
  } catch (e) {
    if(previewing){if(previous)renderResult(previous);else{viewer.update([]);renderDiagram($('diagram-host'),{nodes:[],links:[]},selectPart);$('result-title').textContent='Drawing stopped';}}
    if (e.name === 'AbortError') error('Stopped. Your previous answer and question are still here.');
    else error(e.message || 'Something went wrong. Please try again.');
  } finally { state.controller = null; busy(false); }
}
function removeImage() { state.image = null; $('attachment').hidden = true; $('attachment-preview').removeAttribute('src'); $('image-input').value = ''; }
function attachImage(data) { state.image = data; $('attachment-preview').src = data; $('attachment').hidden = false; clearError(); }
function canvasImage(source, width, height) {
  const ratio = Math.min(1, 1800 / Math.max(width, height)); const canvas = document.createElement('canvas');
  canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
  const context = canvas.getContext('2d'); context.fillStyle = '#ffffff'; context.fillRect(0, 0, canvas.width, canvas.height); context.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas.toDataURL('image/jpeg', .88);
}
async function uploadImage(file) {
  if (!file) return;
  if (!['image/png', 'image/jpeg'].includes(file.type)) { error('Choose a PNG or JPEG image.'); return; }
  if (file.size > 15 * 1024 * 1024) { error('Choose an image smaller than 15 MB.'); return; }
  const url = URL.createObjectURL(file);
  try { const image = new Image(); image.src = url; await image.decode(); attachImage(canvasImage(image, image.naturalWidth, image.naturalHeight)); }
  catch { error('That image could not be opened. Try another PNG or JPEG.'); }
  finally { URL.revokeObjectURL(url); }
}
async function captureScreen() {
  if (!navigator.mediaDevices?.getDisplayMedia) { error('Screen sharing is unavailable here. Attach a screenshot with the Image button instead.'); return; }
  let stream;
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
    const video = document.createElement('video'); video.muted = true; video.srcObject = stream; await video.play();
    if (!video.videoWidth) await new Promise(resolve => video.addEventListener('loadeddata', resolve, { once: true }));
    attachImage(canvasImage(video, video.videoWidth, video.videoHeight)); video.pause(); video.srcObject = null;
  } catch (e) { if (e.name !== 'NotAllowedError') error('Could not capture a screenshot. Use Image to attach one instead.'); }
  finally { for (const track of stream?.getTracks() || []) track.stop(); }
}
function localVoice() { return window.speechSynthesis?.getVoices().find(v => v.localService && v.lang.startsWith('en')) || window.speechSynthesis?.getVoices().find(v => v.localService); }
function canSpeak() { return Boolean(native() || localVoice()); }
function speak() {
  if (!state.result) return;
  const text = [state.result.reply, ...state.result.cards.map(c => `${c.title}. ${c.body}`)].join('\n');
  if (native()) { nativeAction('speak', text); return; }
  const voice = localVoice(); if (!voice) { error('No local speech voice is available. You can still read the explanation here.'); return; }
  window.speechSynthesis.cancel(); const utterance = new SpeechSynthesisUtterance(text); utterance.voice = voice; utterance.rate = 1; window.speechSynthesis.speak(utterance);
}
function syncNative() { $('mic-button').hidden = !native(); if (state.result) $('speak-button').disabled = !canSpeak(); }
window.clippyReceiveTranscript = text => { $('prompt').value = String(text).slice(0, 6000); resizePrompt(); $('prompt').focus(); };
window.clippyNativeStatus = text => {
  state.listening = String(text).startsWith('Listening'); $('mic-button').classList.toggle('listening', state.listening);
  $('mic-button').lastElementChild.textContent = state.listening ? 'Stop dictation' : 'Dictate';
  $('mic-button').setAttribute('aria-pressed', String(state.listening));
  $('footnote').textContent = String(text); $('footnote').setAttribute('role', 'status');
};
$('composer').addEventListener('submit', e => { e.preventDefault(); send($('prompt').value); });
$('prompt').addEventListener('input', resizePrompt);
$('prompt').addEventListener('keydown', e => { if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); send($('prompt').value); } });
$('cancel-button').addEventListener('click', () => state.controller?.abort());
$('reset-button').addEventListener('click', () => { window.speechSynthesis?.cancel(); nativeAction('stopSpeaking'); window.location.reload(); });
$('error-close').addEventListener('click', clearError);
$('attach-button').addEventListener('click', () => $('image-input').click());
$('image-input').addEventListener('change', e => uploadImage(e.target.files[0]));
$('remove-image').addEventListener('click', removeImage);
$('screen-button').addEventListener('click', captureScreen);
$('speak-button').addEventListener('click', speak);
$('mic-button').addEventListener('click', () => nativeAction(state.listening ? 'stopDictation' : 'dictate'));
$('scene-tab').addEventListener('click', () => switchView('scene'));
$('diagram-tab').addEventListener('click', () => switchView('diagram'));
$('fit-button').addEventListener('click', () => viewer.reset());
$('part-close').addEventListener('click', closePart);
$('part-ask').addEventListener('click', () => { if (!state.part) return; const message = `Explain ${state.part.label} in this ${state.result ? state.result.title : 'sample water molecule'}. Highlight it in the visual.`; $('prompt').value = message; resizePrompt(); send(message); });
for (const button of document.querySelectorAll('[data-prompt]')) button.addEventListener('click', () => { $('prompt').value = button.dataset.prompt; resizePrompt(); send(button.dataset.prompt); });
function showHistory(show) { $('conversation').hidden = !show; $('history-button').setAttribute('aria-expanded', String(show)); }
$('history-button').addEventListener('click', () => showHistory($('conversation').hidden));
$('history-close').addEventListener('click', () => showHistory(false));
document.addEventListener('keydown', e => { if (e.key === 'Escape') { closePart(); showHistory(false); if (state.controller) state.controller.abort(); } });
window.speechSynthesis?.addEventListener('voiceschanged', syncNative);
window.addEventListener('beforeunload', () => { state.controller?.abort(); window.speechSynthesis?.cancel(); });
syncNative(); loadSession().catch(e => { $('connection').className = 'connection disconnected'; $('connection').lastElementChild.textContent = 'Server unavailable'; error(e.message); });
