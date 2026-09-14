import http from 'node:http';
import {randomBytes} from 'node:crypto';
import {readFile, writeFile, rename, mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {validateCapture} from './compare.mjs';

const args = process.argv.slice(2);
const app = args[0], fixturesPath = args[1], scratch = args[2], output = args[3];
if (!app || !fixturesPath || !scratch || !output) throw new Error('Use scripts/verify-safari.sh to build and start this checker.');
const root = path.dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(await readFile(fixturesPath, 'utf8'));
const token = randomBytes(24).toString('hex');
const label = `Typer browser check ${token}`;
const statePath = path.join(scratch, 'state.json'), resultPath = path.join(scratch, 'native-result.json');
const assets = {'': ['index.html', 'text/html'], 'page.mjs': ['page.mjs', 'text/javascript'], 'compare.mjs': ['compare.mjs', 'text/javascript'], 'style.css': ['style.css', 'text/css']};
let active = null, origin = '', lastCapture = null, nativeResult = null;
await mkdir(output, {recursive: true});
async function saveState() {
  await writeFile(`${statePath}.new`, JSON.stringify(active || {active: false}));
  await rename(`${statePath}.new`, statePath);
}
// Serialize state writes so heartbeats and Stop cannot reorder atomic renames.
let writes = Promise.resolve();
function stateChanged() { writes = writes.then(saveState); return writes; }
async function body(req) {
  let text = '';
  for await (const chunk of req) {
    text += chunk;
    if (text.length > 4_000_000) throw new Error('Request is too large.');
  }
  return JSON.parse(text || '{}');
}
function reply(res, code, value) { res.writeHead(code, {'Content-Type': 'application/json'}); res.end(JSON.stringify(value)); }
function validID(value) { return typeof value === 'string' && /^[a-zA-Z0-9-]{1,80}$/.test(value); }

const server = http.createServer(async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
  try {
    if (req.headers.host !== new URL(origin).host) return reply(res, 403, {error: 'Invalid host.'});
    const url = new URL(req.url, origin), prefix = `/${token}/`;
    if (!url.pathname.startsWith(prefix)) return reply(res, 404, {error: 'Unknown session.'});
    const route = url.pathname.slice(prefix.length);
    if (req.method === 'GET' && Object.hasOwn(assets, route)) {
      const [file, type] = assets[route];
      res.writeHead(200, {'Content-Type': `${type}; charset=utf-8`}); res.end(await readFile(path.join(root, file))); return;
    }
    if (req.method === 'GET' && route === 'config') return reply(res, 200, {fixtures, label, output, keyboardLayout: 'com.apple.keylayout.US'});
    if (req.method === 'GET' && route === 'status') {
      try {
        const result = JSON.parse(await readFile(resultPath, 'utf8'));
        if (result.runID === active?.runID) nativeResult = result;
      } catch { /* Native process has not finished. */ }
      return reply(res, 200, {active, nativeResult, lastCapture});
    }
    if (req.method !== 'POST') return reply(res, 405, {error: 'Method not allowed.'});
    // Same-origin browser requests only; no cross-site control of native input.
    if (req.headers.origin !== origin || req.headers['content-type'] !== 'application/json') return reply(res, 403, {error: 'Same-origin JSON request required.'});
    const data = await body(req);
    if (route === 'native/start') {
      const fixture = fixtures.find(x => x.id === data.scenario);
      if (!validID(data.runID) || !validID(data.owner) || !fixture?.variants.some(x => x.id === data.variant)) throw new Error('Invalid fixture request.');
      if (active && !nativeResult && Date.now() < active.expiresAt) throw new Error('The previous native check is still finishing. Try again in a moment.');
      active = {runID: data.runID, owner: data.owner, active: true, heartbeat: Date.now(), expiresAt: Date.now() + 90_000, scenario: data.scenario, variant: data.variant};
      nativeResult = null; lastCapture = null;
      await stateChanged();
      const child = spawn('/usr/bin/open', ['-g', '-n', app, '--args', statePath, resultPath, data.scenario, data.runID, `${label} ${data.owner}`, args.includes('--global-hid') ? 'hid' : 'process', data.variant, args[4] || ''], {stdio: 'ignore'});
      const failedLaunch = () => { if (active?.runID === data.runID) {
        active.active = false; nativeResult = {runID: data.runID, completed: false, error: 'The native checker could not be opened.'}; stateChanged().catch(() => {});
      } };
      child.on('error', failedLaunch);
      child.on('exit', code => { if (code !== 0) failedLaunch(); });
      return reply(res, 200, {started: true});
    }
    if (route === 'heartbeat' || route === 'stop') {
      if (active?.runID === data.runID && active.owner === data.owner) {
        active.heartbeat = Date.now();
        // A stopped run cannot be revived by a delayed heartbeat.
        active.active = active.active && route !== 'stop' && data.focused === true;
        await stateChanged();
      }
      return reply(res, 200, {ok: true});
    }
    if (route === 'native/capture') {
      if (data.owner !== active?.owner || data.runID !== active?.runID || data.capture?.source !== 'typer-native') throw new Error('Capture does not belong to this run.');
      validateCapture(data.capture);
      lastCapture = data.capture;
      await writeFile(path.join(output, `${active.scenario}-${active.runID}.json`), JSON.stringify(lastCapture, null, 2));
      return reply(res, 200, {saved: true});
    }
    return reply(res, 404, {error: 'Unknown action.'});
  } catch (error) { reply(res, 400, {error: error.message}); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
const url = `${origin}/${token}/`;
await writeFile(path.join(output, 'session.json'), JSON.stringify({url, label, pid: process.pid}, null, 2));
console.log(`Safari check: ${url}\nNative reports: ${output}\nPhysical samples stay in the page until you export them. Press Control-C to stop the server.`);
if (args.includes('--open')) spawn('/usr/bin/open', ['-a', 'Safari', url], {stdio: 'ignore'});
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
  if (active) active.active = false;
  await stateChanged().catch(() => {});
  server.close(); process.exit(0);
});
