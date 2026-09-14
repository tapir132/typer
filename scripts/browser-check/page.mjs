import {SCHEMA, CAPTURE_FEATURES, MAX_EVENTS, MAX_TEXT, validateCapture, analyzeCapture, compareCaptures} from './compare.mjs';
const $ = id => document.getElementById(id);
let editor = $('editor');
const owner = crypto.randomUUID(), samples = new Map();
let config, current = null, lastReport = null, heartbeatTimer, deadlineTimer, pollTimer, endingNative = false;

async function request(route, data) {
  const response = await fetch(route, data === undefined ? {cache: 'no-store'} : {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Local checker returned ${response.status}.`);
  return result;
}
function textValue() {
  if (editor.tagName === 'TEXTAREA') return editor.value;
  // Safari innerText adds a newline after a final block even without a final
  // Enter. Derive lines from this fixture's div/p/br editing structure. Keep
  // the untouched innerHTML in the export so the projection is reviewable.
  function contents(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.data;
    if (node.nodeName === 'BR') return '\n';
    const children = [...node.childNodes];
    if (['DIV', 'P'].includes(node.nodeName) && children.length === 1 && children[0].nodeName === 'BR') return '';
    let value = '', previousBlock = false;
    for (const [index, child] of children.entries()) {
      const block = ['DIV', 'P'].includes(child.nodeName);
      if (index > 0 && (block || previousBlock)) value += '\n';
      value += contents(child); previousBlock = block;
    }
    return value;
  }
  return contents(editor);
}
function setText(value) { if (editor.tagName === 'TEXTAREA') editor.value = value; else editor.textContent = value; }
function editable(enabled) { if (editor.tagName === 'TEXTAREA') editor.readOnly = !enabled; else editor.contentEditable = String(enabled); }
function selection() {
  if (editor.tagName === 'TEXTAREA') return {selectionStart: editor.selectionStart, selectionEnd: editor.selectionEnd};
  const s = getSelection();
  if (!s?.rangeCount || !editor.contains(s.anchorNode) || !editor.contains(s.focusNode)) return {};
  function offset(node, index) { const r = document.createRange(); r.selectNodeContents(editor); r.setEnd(node, index); return r.toString().length; }
  return {selectionStart: offset(s.anchorNode, s.anchorOffset), selectionEnd: offset(s.focusNode, s.focusOffset)};
}
function status(message, error = false) { $('status').textContent = message; $('status').classList.toggle('error', error); }
function fixture() { return config.fixtures.find(x => x.id === $('scenario').value); }
function pair() { return samples.get(fixture().id) || {}; }
function render() {
  $('scenario').disabled = !!current;
  $('variant').disabled = !!current || fixture().variants.length === 1;
  $('import').disabled = !!current; $('reference').disabled = !!current; $('native').disabled = !!current; $('stop').disabled = !current;
  const value = pair();
  $('reference-status').textContent = value.reference ? describe(value.reference) : 'Not recorded';
  $('native-status').textContent = value.playback ? describe(value.playback) : 'Not run';
  $('compare').disabled = !!current || !value.reference || !value.playback;
  $('export').disabled = !!current || (!value.reference && !value.playback);
}
function describe(capture) {
  const result = analyzeCapture(capture);
  const label = capture.source === 'typer-native' ? `${capture.native?.variant?.title ?? 'Fixed delivery check'} · ` : '';
  return result.usable ? `${label}${capture.events.length} events · text matches` : result.reasons[0];
}
function resetReport() {
  lastReport = null; $('report').replaceChildren();
  const p = document.createElement('p'); p.textContent = 'Compare both samples to see event differences and timing.'; $('report').append(p);
}
function changePassage() {
  $('instructions').textContent = fixture().instructions;
  $('passage').textContent = fixture().text;
  editor = fixture().editorKind === 'contenteditable' ? $('rich-editor') : $('editor');
  $('editor').hidden = editor !== $('editor'); $('rich-editor').hidden = editor !== $('rich-editor');
  $('editor-label').htmlFor = editor.id;
  setText(''); editable(false);
  $('variant').replaceChildren(...fixture().variants.map(value => {
    const option = document.createElement('option'); option.value = value.id; option.textContent = value.title; return option;
  }));
  changeVariant(); render();
}
function changeVariant() {
  $('variant-help').textContent = $('variant').value === 'fixed'
    ? 'Steady timing checks key delivery. It does not test the rhythm generator.'
    : `${fixture().variants.find(x => x.id === $('variant').value)?.title}. The physical reference is excluded from training.`;
  resetReport();
}
function start(source) {
  if (current) throw new Error('Finish the current recording first.');
  const f = fixture();
  editable(true); setText(''); editor.focus();
  if (!document.hasFocus() || document.activeElement !== editor) {
    editable(false);
    throw new Error('Focus the Safari test page before starting.');
  }
  current = {
    schemaVersion: SCHEMA, runID: crypto.randomUUID(), source, scenario: f.id,
    expectedText: f.text, text: '', userAgent: navigator.userAgent,
    keyboardLayout: config.keyboardLayout, editor: `${f.editorKind || 'textarea'};spellcheck=false;autocorrect=off`,
    captureFeatures: {...CAPTURE_FEATURES}, writingSuggestions: false,
    textProjection: f.editorKind === 'contenteditable' ? 'div-p-br-v1' : 'textarea-value',
    createdAt: new Date().toISOString(), completed: false, interrupted: false, truncated: false, pasted: false,
    events: [], start: performance.now(), reason: '', native: null
  };
  resetReport(); render();
  status(source === 'typer-native' ? 'Typer is starting. Keep this editor focused.' : 'Recording this editor. Type the passage, then press Esc.');
  deadlineTimer = setTimeout(() => finish(false, 'The 90-second recording limit was reached.'), 90_000);
  return current.runID;
}
function finish(completed, reason = '') {
  if (!current) return;
  const capture = current; current = null;
  clearInterval(heartbeatTimer); clearInterval(pollTimer); clearTimeout(deadlineTimer); endingNative = false;
  capture.text = textValue().slice(0, MAX_TEXT);
  if (editor.tagName !== 'TEXTAREA') capture.editorHTML = editor.innerHTML.slice(0, MAX_TEXT * 4);
  capture.completed = completed; capture.interrupted = !completed; capture.reason = reason;
  delete capture.start;
  const value = pair();
  if (capture.source === 'typer-native') {
    value.playback = capture;
    request('stop', {owner, runID: capture.runID}).catch(() => {});
    request('native/capture', {owner, runID: capture.runID, capture}).catch(error => status(`Report could not be saved: ${error.message}`, true));
  } else { value.reference = capture; }
  samples.set(capture.scenario, value);
  editable(false);
  const analysis = analyzeCapture(capture);
  $('event-details').textContent = JSON.stringify({source: capture.source, ...analysis}, null, 2);
  status(reason || (analysis.usable ? 'Sample complete. The final text matches.' : analysis.reasons.join(' ')), !analysis.usable);
  render();
}
async function runNative() {
  if (!/Version\/.+Safari\//.test(navigator.userAgent)) throw new Error('Open this local page in Safari to run the native check.');
  const runID = start('typer-native');
  try {
    await request('native/start', {owner, runID, scenario: current.scenario, variant: $('variant').value});
    if (current?.runID !== runID) { await request('stop', {owner, runID}); return; }
    heartbeatTimer = setInterval(() => {
      request('heartbeat', {owner, runID, focused: document.hasFocus() && document.activeElement === editor && !document.hidden})
        .catch(error => { if (current?.runID === runID) finish(false, `Connection lost: ${error.message}`); });
    }, 150);
    pollTimer = setInterval(async () => {
      try {
        const state = await request('status');
        if (current?.runID !== runID || endingNative) return;
        if (state.nativeResult?.runID === runID) {
          current.native = state.nativeResult; endingNative = true;
          // The native result is written just after the last post. Let Safari
          // drain its event queue before closing the recording.
          setTimeout(() => { if (current?.runID === runID) finish(state.nativeResult.completed, state.nativeResult.error); }, 250);
        }
      } catch (error) { if (current?.runID === runID) finish(false, error.message); }
    }, 200);
  } catch (error) { if (current?.runID === runID) finish(false, error.message); }
}
function record(event) {
  if (!current || document.activeElement !== editor) return;
  if (event.type === 'keydown' && event.key === 'Escape') {
    event.preventDefault(); event.stopPropagation();
    finish(current.source !== 'typer-native', current.source === 'typer-native' ? 'Playback stopped with Esc.' : ''); return;
  }
  if (event.type === 'keyup' && event.key === 'Escape') return;
  if (current.events.length >= MAX_EVENTS || textValue().length > MAX_TEXT) {
    current.truncated = true; finish(false, 'Recording reached its size limit.'); return;
  }
  const row = {type: event.type, time: performance.now() - current.start, eventTimeStamp: event.timeStamp, isTrusted: event.isTrusted};
  for (const field of ['defaultPrevented', 'bubbles', 'cancelable', 'composed']) row[field] = event[field];
  if (event instanceof KeyboardEvent) {
    for (const key of ['key', 'code', 'location', 'repeat', 'shiftKey', 'altKey', 'ctrlKey', 'metaKey', 'isComposing', 'keyCode', 'charCode', 'which']) row[key] = event[key];
    row.modifierStates = Object.fromEntries(['Shift', 'Alt', 'Control', 'Meta', 'CapsLock', 'NumLock', 'AltGraph', 'Fn'].map(key => [key, event.getModifierState(key)]));
  }
  if (event instanceof InputEvent) { row.inputType = event.inputType; row.data = event.data; row.isComposing = event.isComposing; }
  if (event instanceof CompositionEvent) row.data = event.data;
  Object.assign(row, selection());
  if (event.type === 'input') row.textLength = textValue().length;
  current.events.push(row);
}
for (const input of [$('editor'), $('rich-editor')]) {
  for (const type of ['keydown', 'keyup', 'keypress', 'beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend']) input.addEventListener(type, record);
}
document.addEventListener('selectionchange', event => { if (current && document.activeElement === editor) record(event); });
for (const input of [$('editor'), $('rich-editor')]) for (const type of ['paste', 'drop']) input.addEventListener(type, event => {
  if (current) { current.pasted = true; event.preventDefault(); finish(false, 'Pasted or dropped text cannot be used as a keyboard sample.'); }
});
for (const input of [$('editor'), $('rich-editor')]) input.addEventListener('blur', () => { if (current) finish(false, 'Recording interrupted: focus left the editor.'); });
window.addEventListener('blur', () => { if (current) finish(false, 'Recording interrupted: Safari lost focus.'); });
document.addEventListener('visibilitychange', () => { if (current && document.hidden) finish(false, 'Recording interrupted: the page became hidden.'); });
window.addEventListener('pagehide', () => {
  if (current?.source === 'typer-native') fetch('stop', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({owner, runID: current.runID}), keepalive: true}).catch(() => {});
});
$('stop').addEventListener('pointerdown', event => event.preventDefault());
$('stop').addEventListener('click', () => { if (current) finish(current.source !== 'typer-native', current.source === 'typer-native' ? 'Playback stopped.' : ''); });
$('reference').addEventListener('click', () => { try { start('physical-keyboard-labelled'); } catch (error) { status(error.message, true); } });
$('native').addEventListener('click', () => runNative().catch(error => status(error.message, true)));
$('scenario').addEventListener('change', changePassage);
$('variant').addEventListener('change', changeVariant);
$('compare').addEventListener('click', () => {
  const {reference, playback} = pair(); lastReport = compareCaptures(reference, playback);
  const box = $('report'); box.replaceChildren();
  const title = document.createElement('strong');
  title.textContent = !lastReport.comparable ? 'Comparison needs another sample' : lastReport.eventPropertiesMatch ? 'Recorded fields match' : 'Recorded event sequences differ';
  box.append(title);
  const list = document.createElement('ul');
  const rollover = value => value == null ? 'unavailable' : `${(value * 100).toFixed(0)}%`;
  const messages = lastReport.comparable ? [
    `Final text matches in both samples.`,
    lastReport.completeCaptureCoverage ? 'Both captures include the expanded event fields.' : 'Some fields were not recorded in the older sample; those comparisons remain unavailable.',
    `${lastReport.keyProperties.matchingGroups} of ${lastReport.keyProperties.sharedGroups} shared key groups have matching properties. ${lastReport.keyProperties.referenceOnly.length + lastReport.keyProperties.playbackOnly.length} groups appear in only one sample.`,
    `Overlapping keys: ${rollover(lastReport.reference.timing.rollover)} keyboard / ${rollover(lastReport.playback.timing.rollover)} Typer. Corrections and overlap can change event order.`,
    `Typer run: ${playback.native?.variant?.title ?? 'Fixed delivery check'}.`,
    ...Object.entries(lastReport.timing).map(([key, value]) => value.sufficient ? `${key}: ${value.wassersteinMilliseconds.toFixed(1)} ms distribution distance (${value.reference.count}/${value.playback.count} observations).` : `${key}: more input needed for a timing comparison (${value.reference.count}/${value.playback.count}; at least 20 each).`),
    'This describes the captured passage, not a probability of human input.'
  ] : lastReport.reasons;
  for (const text of messages) { const li = document.createElement('li'); li.textContent = text; list.append(li); }
  box.append(list); $('event-details').textContent = JSON.stringify(lastReport, null, 2);
});
$('import').addEventListener('click', () => $('import-file').click());
$('import-file').addEventListener('change', async event => {
  try {
    if (current) throw new Error('Finish recording before loading a sample.');
    const file = event.target.files?.[0];
    if (!file) return;
    if (file.size > 4_000_000) throw new Error('This sample file is too large.');
    const data = JSON.parse(await file.text());
    if (current) throw new Error('Finish recording before loading a sample.');
    const capture = validateCapture(data.reference ?? data);
    if (capture.source !== 'physical-keyboard-labelled') throw new Error('Load an exported physical keyboard sample. Automated traces cannot be references.');
    const found = config.fixtures.find(f => f.id === capture.scenario && f.text === capture.expectedText);
    if (!found) throw new Error('This sample uses a different test passage.');
    const analysis = analyzeCapture(capture);
    if (!analysis.usable) throw new Error(analysis.reasons.join(' '));
    $('scenario').value = found.id; changePassage();
    const saved = pair(); saved.reference = capture; samples.set(found.id, saved);
    render(); status('Saved keyboard sample loaded. Run Typer, then compare. Older fields may be unavailable.');
  } catch (error) { status(error.message, true); }
  finally { event.target.value = ''; }
});
$('export').addEventListener('click', () => {
  const blob = new Blob([JSON.stringify({schemaVersion: SCHEMA, ...pair(), comparison: lastReport}, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob), a = document.createElement('a');
  a.href = url; a.download = `typer-safari-${fixture().id}.json`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
});

// Explicit diagnostic entry points. Browser automation must identify itself;
// these are never treated as a hardware reference by the comparison function.
window.typerCheck = {
  startAutomation: () => start('browser-automation'),
  finishAutomation: () => finish(true),
  runNative,
  snapshot: () => ({current, samples: [...samples.entries()], lastReport})
};
try {
  config = await request('config');
  for (const input of [$('editor'), $('rich-editor')]) input.setAttribute('aria-label', `${config.label} ${owner}`);
  $('scenario').replaceChildren(...config.fixtures.map(f => { const option = document.createElement('option'); option.value = f.id; option.textContent = f.title; return option; }));
  const query = new URLSearchParams(location.search);
  if (config.fixtures.some(f => f.id === query.get('scenario'))) $('scenario').value = query.get('scenario');
  changePassage(); status('Ready. Record a keyboard sample or run Typer.');
  if (fixture().variants.some(x => x.id === query.get('variant'))) { $('variant').value = query.get('variant'); changeVariant(); }
  // The command-line verifier opens a dedicated regular Safari tab. This is
  // still a fixed native fixture, never a browser-generated keyboard reference.
  if (query.get('run') === 'native') setTimeout(() => runNative().catch(error => status(error.message, true)), 750);
} catch (error) { status(`Cannot start: ${error.message}`, true); }
