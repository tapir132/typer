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
for (const fixture of config.fixtures) {
  const before = await (await fetch(new URL('status', url))).json();
  const next = new URL(base); next.searchParams.set('scenario', fixture.id); next.searchParams.set('run', 'native');
  // Session URLs and numeric IDs are strictly validated above; user text never
  // becomes AppleScript. Only navigate the window if it still owns this page.
  await run('/usr/bin/osascript', ['-e', `tell application "Safari"
    if URL of current tab of window id ${windowID} does not start with "${base}" then error "The check window was navigated elsewhere."
    set URL of current tab of window id ${windowID} to "${next.href}"
    set index of window id ${windowID} to 1
    activate
  end tell`]);
  let capture = null;
  const deadline = Date.now() + Math.max(15_000, fixture.duration + 10_000);
  while (Date.now() < deadline) {
    await delay(300);
    const state = await (await fetch(new URL('status', url))).json();
    if (state.lastCapture && state.lastCapture.runID !== before.lastCapture?.runID && state.lastCapture.scenario === fixture.id) {
      capture = state.lastCapture; break;
    }
  }
  if (!capture) throw new Error(`No native Safari capture arrived for ${fixture.id}.`);
  const analysis = analyzeCapture(capture);
  const result = {scenario: fixture.id, ...analysis, nativeCompleted: capture.native?.completed === true,
    browser: capture.userAgent, source: capture.source, reason: capture.reason};
  results.push(result);
  await writeFile(path.join(folder, `${fixture.id}.json`), JSON.stringify(capture, null, 2));
  console.log(JSON.stringify({scenario: fixture.id, usable: result.usable, textMatches: result.textMatches,
    events: capture.events.length, reasons: result.reasons, nativeError: capture.native?.error}));
}
await writeFile(path.join(folder, 'summary.json'), JSON.stringify({passed: results.every(x => x.usable), results,
  physicalReference: 'pending', limitations: 'Fixed native Safari fixtures; no human indistinguishability conclusion.'}, null, 2));
process.exitCode = results.every(x => x.usable) ? 0 : 1;
