import test from 'node:test';
import assert from 'node:assert/strict';
import {analyzeCapture, compareCaptures, validateCapture, wasserstein, MAX_EVENTS} from './compare.mjs';

// Constructed fixtures test the analyzer; none are physical observations.
function sample(source = 'physical-keyboard-labelled', text = 'abc') {
  const events = [];
  let time = 0;
  for (const key of text) {
    const base = {key, code: `Key${key.toUpperCase()}`, location: 0, repeat: false,
      shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, isComposing: false, isTrusted: true};
    events.push({type: 'keydown', time, ...base},
      {type: 'beforeinput', time: time + 1, isTrusted: true, inputType: 'insertText', data: key, isComposing: false},
      {type: 'input', time: time + 2, isTrusted: true, inputType: 'insertText', data: key, isComposing: false},
      {type: 'keyup', time: time + 70, ...base});
    time += 120;
  }
  return {schemaVersion: 1, source, scenario: 'plain', expectedText: text, text,
    userAgent: 'fixture-browser', keyboardLayout: 'US', editor: 'textarea',
    completed: true, interrupted: false, truncated: false, pasted: false, events,
    native: source === 'typer-native' ? {completed: true} : null};
}
test('equal observed properties match while sparse timing remains unavailable', () => {
  const result = compareCaptures(sample(), sample('typer-native'));
  assert.equal(result.comparable, true); assert.equal(result.eventPropertiesMatch, true);
  assert.equal(result.timing.hold.sufficient, false);
  assert.equal(result.timing.hold.wassersteinMilliseconds, null);
});
test('automated reference cannot establish physical comparison', () => {
  const result = compareCaptures(sample('browser-automation'), sample('typer-native'));
  assert.equal(result.comparable, false); assert.equal(result.eventPropertiesMatch, null);
  assert.match(result.reasons.join(' '), /Reference is automated/);
});
test('empty and unfinished samples never pass', () => {
  const empty = sample('physical-keyboard-labelled', '');
  assert.equal(analyzeCapture(empty).usable, false);
  for (const field of ['interrupted', 'truncated', 'pasted']) {
    const value = sample(); value[field] = true; assert.equal(analyzeCapture(value).usable, false);
  }
  const value = sample(); value.completed = false; assert.equal(analyzeCapture(value).usable, false);
});
test('paste input events cannot pass by omitting the paste flag', () => {
  const value = sample(); value.events[2].inputType = 'insertFromPaste';
  assert.equal(analyzeCapture(value).usable, false);
  value.events[2].inputType = 'insertFromDrop';
  assert.equal(analyzeCapture(value).usable, false);
});
test('missing releases, orphan releases and double presses are found', () => {
  const missing = sample(); missing.events.pop(); assert.equal(analyzeCapture(missing).unreleasedKeys, 1);
  const orphan = sample(); orphan.events.shift(); assert.equal(analyzeCapture(orphan).unmatchedUps, 1);
  const doubled = sample(); doubled.events.splice(1, 0, {...doubled.events[0]});
  assert.equal(analyzeCapture(doubled).repeatedDowns, 1);
  for (const value of [missing, orphan, doubled]) assert.equal(analyzeCapture(value).usable, false);
});
test('legitimate auto-repeat is counted without adding a second held key', () => {
  const value = sample(); value.events.splice(1, 0, {...value.events[0], repeat: true});
  assert.equal(analyzeCapture(value).repeats, 1);
  assert.equal(analyzeCapture(value).repeatedDowns, 0);
});
test('modifier and key-code differences are exposed even when text matches', () => {
  const value = sample('typer-native');
  value.events[0].shiftKey = true;
  const result = compareCaptures(sample(), value);
  assert.equal(result.comparable, true); assert.equal(result.eventPropertiesMatch, false);
  assert.deepEqual(result.differences[0].fields, ['shiftKey']);
  value.events[0].code = 'KeyZ'; value.events[3].code = 'KeyZ';
  assert.ok(compareCaptures(sample(), value).differences[0].fields.includes('code'));
});
test('selection notification coalescing does not falsify key-event equality', () => {
  const value = sample('typer-native'); value.events.splice(1, 0, {type: 'selectionchange', time: 0, isTrusted: true});
  assert.equal(compareCaptures(sample(), value).eventPropertiesMatch, true);
});
test('changed key values are reported without mistaking them for missing releases', () => {
  const value = sample(); value.events[0].key = 'é';
  const result = analyzeCapture(value);
  assert.deepEqual(result.changedKeyValues, [{code: 'KeyA', down: 'é', up: 'a'}]);
  assert.equal(result.unreleasedKeys, 0);
});
test('different browser, layout, fixture or editor prevents pooled comparison', () => {
  for (const field of ['scenario', 'expectedText', 'userAgent', 'keyboardLayout', 'editor']) {
    const value = sample('typer-native'); value[field] += '-different';
    assert.equal(compareCaptures(sample(), value).comparable, false);
  }
});
test('untrusted input, wrong final text and failed native result are rejected', () => {
  const untrusted = sample(); untrusted.events[0].isTrusted = false;
  assert.equal(analyzeCapture(untrusted).usable, false);
  const wrong = sample(); wrong.text += 'x'; assert.equal(analyzeCapture(wrong).textMatches, false);
  const failed = sample('typer-native'); failed.native.completed = false;
  assert.equal(analyzeCapture(failed).usable, false);
});
test('malformed data and nonmonotonic clocks fail validation', () => {
  assert.throws(() => validateCapture(null));
  for (const bad of [NaN, Infinity, -1, '12']) {
    const value = sample(); value.events[0].time = bad; assert.throws(() => validateCapture(value));
  }
  const backward = sample(); backward.events[1].time = 500; assert.throws(() => validateCapture(backward));
  const oversized = sample(); oversized.events = Array(MAX_EVENTS + 1).fill(oversized.events[0]); assert.throws(() => validateCapture(oversized));
  const modifiers = sample(); delete modifiers.events[0].altKey; assert.throws(() => validateCapture(modifiers));
  const unknown = sample(); unknown.source = 'human-certified'; assert.throws(() => validateCapture(unknown));
});
test('composition is retained as an observable sequence difference', () => {
  const value = sample('typer-native');
  value.events.splice(1, 0, {type: 'compositionstart', time: 0, isTrusted: true, data: ''});
  const result = compareCaptures(sample(), value);
  assert.equal(result.eventPropertiesMatch, false);
  assert.equal(result.playback.counts.compositionstart, 1);
});
test('holds, signed flight and overlap are measured using arrival clocks', () => {
  const value = sample();
  for (let i = 4; i < 8; i++) value.events[i].time -= 80;
  value.events.sort((a, b) => a.time - b.time);
  const result = analyzeCapture(value);
  assert.deepEqual(result.distributions.hold, [70, 70, 70]);
  assert.deepEqual(result.distributions.flight, [-30, 130]);
  assert.equal(result.timing.rollover, 0.5);
});
test('idle gaps do not become motor intervals', () => {
  const value = sample(); for (let i = 4; i < value.events.length; i++) value.events[i].time += 3000;
  assert.equal(analyzeCapture(value).timing.interval.count, 1);
});
test('empirical Wasserstein uses unequal sample weights and exposes sample counts', () => {
  assert.equal(wasserstein([], [1]), null);
  assert.equal(wasserstein([0, 2], [1]), 1);
  assert.ok(Math.abs(wasserstein([0, 0, 3], [0, 3]) - 0.5) < 1e-10);
  const value = sample('typer-native', 'abcdefghijklmnopqrstuvw');
  for (const event of value.events) if (event.type === 'keyup') event.time += 10;
  const result = compareCaptures(sample('physical-keyboard-labelled', value.text), value);
  assert.equal(result.timing.hold.sufficient, true);
  assert.equal(result.timing.hold.reference.count, 23);
  assert.ok(Math.abs(result.timing.hold.wassersteinMilliseconds - 10) < 1e-10);
});
