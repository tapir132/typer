import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {writeFile, mkdir} from 'node:fs/promises';
import {setTimeout as delay} from 'node:timers/promises';
import path from 'node:path';
import {analyzeCapture} from './compare.mjs';

// Uses a caller-owned Safari window and the page's fixed-fixture mode. No
// Safari JavaScript permission, WebDriver, or generated "human" reference.
const [base, windowID, folder] = process.argv.slice(2);
const url = new URL(base);
if (url.hostname !== '127.0.0.1' || !/^\/[a-f0-9]{48}\/$/.test(url.pathname) || !/^\d+$/.test(windowID || '') || !folder) {
  throw new Error('Usage: node run-safari.mjs SESSION_URL OWNED_SAFARI_WINDOW_ID OUTPUT_FOLDER');
}
const run = promisify(execFile);
const config = await (await fetch(new URL('config', url))).json();
await mkdir(folder, {recursive: true});
const results = [];
scenarios: for (const fixture of config.fixtures) {
 for (const variant of fixture.variants) {
  const before = await (await fetch(new URL('status', url))).json();
  const next = new URL(base); next.searchParams.set('scenario', fixture.id); next.searchParams.set('run', 'native');
  next.searchParams.set('variant', variant.id);
  // Session URLs and numeric IDs are strictly validated above; user text never
  // becomes AppleScript. Only navigate the window if it still owns this page.
  await run('/usr/bin/osascript', ['-e', `tell application "Safari"
    if URL of current tab of window id ${windowID} does not start with "${base}" then error "The check window was navigated elsewhere."
    set URL of current tab of window id ${windowID} to "${next.href}"
    set index of window id ${windowID} to 1
    activate
  end tell`]);
  let capture = null;
  const deadline = Date.now() + Math.max(15_000, variant.duration + 10_000);
  while (Date.now() < deadline) {
    await delay(300);
    const state = await (await fetch(new URL('status', url))).json();
    if (state.lastCapture && state.active?.runID !== before.active?.runID && state.lastCapture.runID === state.active?.runID &&
        state.lastCapture.scenario === fixture.id && state.lastCapture.native?.variant?.id === variant.id &&
        state.nativeResult?.runID === state.lastCapture.runID) {
      capture = state.lastCapture; break;
    }
  }
  if (!capture) throw new Error(`No native Safari capture arrived for ${fixture.id}.`);
  const analysis = analyzeCapture(capture);
  const result = {scenario: fixture.id, variant: capture.native?.variant, ...analysis, nativeCompleted: capture.native?.completed === true,
    browser: capture.userAgent, source: capture.source, reason: capture.reason};
  results.push(result);
  await writeFile(path.join(folder, `${fixture.id}${variant.id === 'fixed' ? '' : `-${variant.id}`}.json`), JSON.stringify(capture, null, 2));
  console.log(JSON.stringify({scenario: fixture.id, variant: variant.id, usable: result.usable, textMatches: result.textMatches,
    events: capture.events.length, reasons: result.reasons, nativeError: capture.native?.error}));
  if (!result.usable) break scenarios;
 }
}
const complete = results.length === config.fixtures.reduce((count, fixture) => count + fixture.variants.length, 0);
const passed = complete && results.every(x => x.usable);
await writeFile(path.join(folder, 'summary.json'), JSON.stringify({passed, complete, results,
  physicalReference: 'not included in this automated suite', limitations: 'Fixed delivery fixtures and seeded production-generator runs; no human indistinguishability conclusion.'}, null, 2));
process.exitCode = passed ? 0 : 1;
