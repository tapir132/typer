import {SCHEMA, MAX_EVENTS, MAX_TEXT, analyzeCapture, compareCaptures} from './compare.mjs';
const $ = id => document.getElementById(id);
const editor = $('editor'), owner = crypto.randomUUID(), samples = new Map();
let config, current = null, lastReport = null, heartbeatTimer, deadlineTimer, pollTimer, endingNative = false;

async function request(route, data) {
  const response = await fetch(route, data === undefined ? {cache: 'no-store'} : {
    method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Local checker returned ${response.status}.`);
  return result;
}
function status(message, error = false) { $('status').textContent = message; $('status').classList.toggle('error', error); }
function fixture() { return config.fixtures.find(x => x.id === $('scenario').value); }
function pair() { return samples.get(fixture().id) || {}; }
function render() {
  $('scenario').disabled = !!current;
  $('variant').disabled = !!current || fixture().variants.length === 1;
  $('reference').disabled = !!current; $('native').disabled = !!current; $('stop').disabled = !current;
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
  $('passage').textContent = fixture().text; editor.value = '';
  $('variant').replaceChildren(...fixture().variants.map(value => {
    const option = document.createElement('option'); option.value = value.id; option.textContent = value.title; return option;
  }));
  changeVariant(); render();
}
function changeVariant() {
  $('variant-help').textContent = $('variant').value === 'fixed'
    ? 'Steady timing checks key delivery. It does not test the rhythm generator.'
    : 'Uses Natural mode at 64 WPM with default variation and corrections. Your sample is not used for training.';
  resetReport();
}
function start(source) {
  if (current) throw new Error('Finish the current recording first.');
  const f = fixture();
  editor.readOnly = false; editor.value = ''; editor.focus();
  if (!document.hasFocus() || document.activeElement !== editor) {
    editor.readOnly = true;
    throw new Error('Focus the Safari test page before starting.');
  }
  current = {
    schemaVersion: SCHEMA, runID: crypto.randomUUID(), source, scenario: f.id,
    expectedText: f.text, text: '', userAgent: navigator.userAgent,
    keyboardLayout: config.keyboardLayout, editor: 'textarea;spellcheck=false;autocorrect=off',
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
  capture.text = editor.value.slice(0, MAX_TEXT);
  capture.completed = completed; capture.interrupted = !completed; capture.reason = reason;
  delete capture.start;
  const value = pair();
  if (capture.source === 'typer-native') {
    value.playback = capture;
    request('stop', {owner, runID: capture.runID}).catch(() => {});
    request('native/capture', {owner, runID: capture.runID, capture}).catch(error => status(`Report could not be saved: ${error.message}`, true));
  } else { value.reference = capture; }
  samples.set(capture.scenario, value);
  editor.readOnly = true;
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
  if (current.events.length >= MAX_EVENTS || editor.value.length > MAX_TEXT) {
    current.truncated = true; finish(false, 'Recording reached its size limit.'); return;
  }
  const row = {type: event.type, time: performance.now() - current.start, eventTimeStamp: event.timeStamp, isTrusted: event.isTrusted};
  if (event instanceof KeyboardEvent) {
    for (const key of ['key', 'code', 'location', 'repeat', 'shiftKey', 'altKey', 'ctrlKey', 'metaKey', 'isComposing']) row[key] = event[key];
  }
  if (event instanceof InputEvent) { row.inputType = event.inputType; row.data = event.data; row.isComposing = event.isComposing; }
  if (event instanceof CompositionEvent) row.data = event.data;
  row.selectionStart = editor.selectionStart; row.selectionEnd = editor.selectionEnd;
  if (event.type === 'input') row.textLength = editor.value.length;
  current.events.push(row);
}
for (const type of ['keydown', 'keyup', 'beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend']) editor.addEventListener(type, record);
document.addEventListener('selectionchange', event => { if (current && document.activeElement === editor) record(event); });
for (const type of ['paste', 'drop']) editor.addEventListener(type, event => {
  if (current) { current.pasted = true; event.preventDefault(); finish(false, 'Pasted or dropped text cannot be used as a keyboard sample.'); }
});
editor.addEventListener('blur', () => { if (current) finish(false, 'Recording interrupted: focus left the editor.'); });
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
  title.textContent = !lastReport.comparable ? 'Comparison needs another sample' : lastReport.eventPropertiesMatch ? 'Complete event sequence matches' : 'Complete event sequences differ';
  box.append(title);
  const list = document.createElement('ul');
  const rollover = value => value == null ? 'unavailable' : `${(value * 100).toFixed(0)}%`;
  const messages = lastReport.comparable ? [
    `Final text matches in both samples.`,
    `${lastReport.keyProperties.matchingGroups} of ${lastReport.keyProperties.sharedGroups} shared key groups have matching properties. ${lastReport.keyProperties.referenceOnly.length + lastReport.keyProperties.playbackOnly.length} groups appear in only one sample.`,
    `Overlapping keys: ${rollover(lastReport.reference.timing.rollover)} keyboard / ${rollover(lastReport.playback.timing.rollover)} Typer. Corrections and overlap can change event order.`,
    `Typer run: ${playback.native?.variant?.title ?? 'Fixed delivery check'}.`,
    ...Object.entries(lastReport.timing).map(([key, value]) => value.sufficient ? `${key}: ${value.wassersteinMilliseconds.toFixed(1)} ms distribution distance (${value.reference.count}/${value.playback.count} observations).` : `${key}: more input needed for a timing comparison (${value.reference.count}/${value.playback.count}; at least 20 each).`),
    'This describes the captured passage, not a probability of human input.'
  ] : lastReport.reasons;
  for (const text of messages) { const li = document.createElement('li'); li.textContent = text; list.append(li); }
  box.append(list); $('event-details').textContent = JSON.stringify(lastReport, null, 2);
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
  config = await request('config'); editor.setAttribute('aria-label', `${config.label} ${owner}`);
  $('scenario').replaceChildren(...config.fixtures.map(f => { const option = document.createElement('option'); option.value = f.id; option.textContent = f.title; return option; }));
  const query = new URLSearchParams(location.search);
  if (config.fixtures.some(f => f.id === query.get('scenario'))) $('scenario').value = query.get('scenario');
  changePassage(); status('Ready. Record a keyboard sample or run Typer.');
  if (fixture().variants.some(x => x.id === query.get('variant'))) { $('variant').value = query.get('variant'); changeVariant(); }
  // The command-line verifier opens a dedicated regular Safari tab. This is
  // still a fixed native fixture, never a browser-generated keyboard reference.
  if (query.get('run') === 'native') setTimeout(() => runNative().catch(error => status(error.message, true)), 750);
} catch (error) { status(`Cannot start: ${error.message}`, true); }
