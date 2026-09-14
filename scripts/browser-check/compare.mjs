export const SCHEMA = 1;
export const MAX_EVENTS = 5000;
export const MAX_TEXT = 4096;
const TYPES = new Set(['keydown', 'keyup', 'beforeinput', 'input', 'compositionstart', 'compositionupdate', 'compositionend', 'selectionchange']);
const SIGNATURE_FIELDS = ['type', 'key', 'code', 'location', 'repeat', 'shiftKey', 'altKey', 'ctrlKey', 'metaKey', 'isComposing', 'inputType', 'data', 'isTrusted'];

export function validateCapture(sample) {
  if (!sample || sample.schemaVersion !== SCHEMA) throw new Error('Unsupported capture format.');
  if (!['physical-keyboard-labelled', 'typer-native', 'browser-automation'].includes(sample.source)) throw new Error('Missing input provenance.');
  for (const field of ['scenario', 'expectedText', 'text', 'userAgent', 'keyboardLayout', 'editor']) {
    if (typeof sample[field] !== 'string' || sample[field].length > MAX_TEXT) throw new Error(`Invalid ${field}.`);
  }
  if (typeof sample.completed !== 'boolean' || typeof sample.interrupted !== 'boolean' || typeof sample.truncated !== 'boolean' || typeof sample.pasted !== 'boolean') throw new Error('Missing capture completion flags.');
  if (!Array.isArray(sample.events) || sample.events.length > MAX_EVENTS) throw new Error('Invalid event count.');
  let previous = -Infinity;
  for (const event of sample.events) {
    if (!event || !TYPES.has(event.type) || !Number.isFinite(event.time) || event.time < 0 || event.time < previous) throw new Error('Invalid event type or timestamp.');
    previous = event.time;
    if (typeof event.isTrusted !== 'boolean') throw new Error('Missing event trust value.');
    for (const key of ['key', 'code', 'inputType', 'data']) {
      if (event[key] != null && (typeof event[key] !== 'string' || event[key].length > MAX_TEXT)) throw new Error(`Invalid event ${key}.`);
    }
    if (event.type === 'keydown' || event.type === 'keyup') {
      if (typeof event.code !== 'string' || typeof event.key !== 'string' || !Number.isInteger(event.location) || event.location < 0 || event.location > 3) throw new Error('Invalid keyboard identity.');
      for (const key of ['repeat', 'shiftKey', 'altKey', 'ctrlKey', 'metaKey', 'isComposing']) {
        if (typeof event[key] !== 'boolean') throw new Error(`Missing keyboard ${key}.`);
      }
    }
  }
  return sample;
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
function summary(values) {
  const center = median(values);
  return {count: values.length, median: center, mad: center == null ? null : median(values.map(x => Math.abs(x - center)))};
}

export function analyzeCapture(input) {
  const sample = validateCapture(input), held = new Map(), pairs = [], changedKeyValues = [];
  let unmatchedUps = 0, repeatedDowns = 0, repeats = 0, untrusted = 0, inputOrderErrors = 0;
  let pendingBeforeInput = 0;
  const counts = {};
  for (const event of sample.events) {
    counts[event.type] = (counts[event.type] || 0) + 1;
    if (!event.isTrusted) untrusted++;
    if (event.type === 'beforeinput') pendingBeforeInput++;
    if (event.type === 'input') {
      if (!pendingBeforeInput) inputOrderErrors++;
      else pendingBeforeInput--;
    }
    const id = `${event.code}:${event.location}`;
    if (event.type === 'keydown') {
      if (event.repeat) { repeats++; continue; }
      if (held.has(id)) repeatedDowns++;
      else held.set(id, event);
    }
    if (event.type === 'keyup') {
      const down = held.get(id);
      if (!down) unmatchedUps++;
      else {
        if (down.key !== event.key) changedKeyValues.push({code: event.code, down: down.key, up: event.key});
        if (!['Shift', 'Alt', 'Control', 'Meta', 'CapsLock', 'Escape'].includes(down.key)) pairs.push({down, up: event});
        held.delete(id);
      }
    }
  }
  pairs.sort((a, b) => a.down.time - b.down.time);
  const holds = pairs.map(x => x.up.time - x.down.time), intervals = [], flights = [];
  for (let i = 1; i < pairs.length; i++) {
    // Describe continuous motor bouts only; do not learn idle gaps as rhythm.
    const interval = pairs[i].down.time - pairs[i - 1].down.time;
    if (interval <= 2500) {
      intervals.push(interval);
      flights.push(pairs[i].down.time - pairs[i - 1].up.time);
    }
  }
  const reasons = [];
  if (!sample.completed || sample.interrupted) reasons.push('Recording did not finish without interruption.');
  if (sample.truncated) reasons.push('Recording reached its size limit.');
  if (sample.pasted || sample.events.some(event => /^insertFrom(Paste|Drop)/.test(event.inputType || ''))) reasons.push('Pasted or dropped text is not a keyboard reference.');
  if (sample.text !== sample.expectedText) reasons.push('Final text differs from the passage.');
  if (!counts.keydown || !counts.input) reasons.push('Keyboard and text-input evidence is required.');
  if (unmatchedUps || held.size || repeatedDowns) reasons.push('Key presses and releases are unbalanced.');
  if (untrusted) reasons.push('The trace contains script-dispatched events.');
  if (sample.source === 'typer-native' && sample.native?.completed !== true) reasons.push('Native playback did not report successful completion.');
  return {
    usable: reasons.length === 0, reasons, textMatches: sample.text === sample.expectedText,
    counts, unmatchedUps, unreleasedKeys: held.size, repeatedDowns, repeats, untrusted, inputOrderErrors, changedKeyValues,
    timing: {hold: summary(holds), interval: summary(intervals), flight: summary(flights), rollover: flights.length ? flights.filter(x => x < 0).length / flights.length : null},
    distributions: {hold: holds, interval: intervals, flight: flights}
  };
}

// Exact empirical one-dimensional Wasserstein distance, including unequal Ns.
export function wasserstein(a, b) {
  if (!a.length || !b.length) return null;
  const left = [...a].sort((x, y) => x - y), right = [...b].sort((x, y) => x - y);
  let i = 0, j = 0, prior = Math.min(left[0], right[0]), area = 0;
  while (i < left.length || j < right.length) {
    const next = Math.min(left[i] ?? Infinity, right[j] ?? Infinity);
    area += Math.abs(i / left.length - j / right.length) * (next - prior);
    while (left[i] === next && i < left.length) i++;
    while (right[j] === next && j < right.length) j++;
    prior = next;
  }
  return area;
}

function structuralEvents(sample) {
  // Selection notifications can be coalesced by the browser event loop. Keep
  // them in raw exports, but do not impose key-for-key equality on them.
  return sample.events.filter(x => x.type !== 'selectionchange');
}

export function compareCaptures(reference, playback) {
  const a = analyzeCapture(reference), b = analyzeCapture(playback);
  const reasons = [...a.reasons.map(x => `Reference: ${x}`), ...b.reasons.map(x => `Typer: ${x}`)];
  if (reference.source !== 'physical-keyboard-labelled') reasons.push('Reference is automated; a physical-keyboard-labelled sample is still required.');
  if (playback.source !== 'typer-native') reasons.push('Playback must use the native Typer checker.');
  for (const field of ['scenario', 'expectedText', 'userAgent', 'keyboardLayout', 'editor']) {
    if (reference[field] !== playback[field]) reasons.push(`Samples have different ${field}.`);
  }
  const left = structuralEvents(reference), right = structuralEvents(playback), differences = [];
  // A bounded, positional diff deliberately does not hide inserted/dropped
  // events through realignment. Report the first differences and total count.
  let differingEvents = 0;
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const fields = !left[i] || !right[i] ? ['event missing'] : SIGNATURE_FIELDS.filter(key => (left[i][key] ?? null) !== (right[i][key] ?? null));
    if (fields.length) {
      differingEvents++;
      if (differences.length < 30) differences.push({index: i, fields, reference: left[i] ?? null, playback: right[i] ?? null});
    }
  }
  const timing = {};
  for (const field of ['hold', 'interval', 'flight']) {
    const av = a.distributions[field], bv = b.distributions[field];
    timing[field] = {reference: a.timing[field], playback: b.timing[field], sufficient: av.length >= 20 && bv.length >= 20,
      wassersteinMilliseconds: av.length >= 20 && bv.length >= 20 ? wasserstein(av, bv) : null};
  }
  return {
    schemaVersion: SCHEMA, comparable: reasons.length === 0, reasons,
    eventPropertiesMatch: reasons.length === 0 ? differingEvents === 0 : null,
    differingEvents, differences, reference: a, playback: b, timing,
    limitations: [
      'Physical provenance is the user’s label; a webpage cannot authenticate keyboard hardware.',
      'Matching recorded properties does not establish indistinguishability to other observers or applications.',
      'Timing distances are descriptive, with no human probability or universal pass threshold; one passage is not a held-out human study.',
      'Corrections and composition methods can legitimately change the sequence. Selection events are retained but excluded from exact sequence equality.'
    ]
  };
}
