#!/usr/bin/env node
// Checks of the Imaginaire runtime in headless Chromium (software WebGL), for every scene:
//   - start() posts "ready", keeps only the scene's decor ids (unknown ids ignored), no error;
//   - setDecor() eases a level over about 1 s and refuses an id the scene does not have;
//   - setPaused(true) stops drawing, setPaused(false) resumes; at most 30 images per second;
//   - recording mode: the image at t = 30 s is the image at t = 0 (the period loops exactly).
//
// Usage: node tools/imaginaire/check.js [--scene id,...]     exit code 1 on any failure

'use strict';

const { chromium } = require('playwright');
const { start } = require('./serve');

const ALLOWED = {
  'foret-lucioles': ['lucioles', 'brume', 'pluie', 'etoiles'],
  'lac-lune': ['brume', 'etoiles', 'etoiles-filantes', 'lucioles', 'neige'],
  aurore: ['neige', 'etoiles', 'etoiles-filantes', 'brume'],
  'jardin-zen': ['petales', 'rayons-soleil', 'brume', 'pluie'],
  'mer-nuages': ['oiseaux-vol', 'etoiles', 'etoiles-filantes', 'brume', 'rayons-soleil'],
  ondes: ['etoiles', 'brume', 'pluie'],
};

async function checkScene(browser, port, id) {
  const failures = [];
  const fail = (msg) => failures.push(msg);
  const page = await browser.newPage({ viewport: { width: 360, height: 780 }, deviceScaleFactor: 2 });
  const messages = [];
  page.on('console', (m) => {
    const text = m.text();
    if (text.startsWith('[EventideScene]')) messages.push(JSON.parse(text.slice(15).trim()));
  });
  page.on('pageerror', (e) => fail(`page error: ${e}`));
  await page.goto(`http://127.0.0.1:${port}/imaginaire/index.html`);
  const first = ALLOWED[id][0];
  await page.evaluate(([sceneId, decor]) => window.eventide.start(sceneId, { decor, quality: 'high', fps: 30 }),
    [id, { [first]: 40, eclairs: 80, inconnu: 10 }]);
  if (!messages.some((m) => m.type === 'ready')) fail('no "ready" message after start()');

  const d = await page.evaluate(() => window.eventide.describe());
  if (JSON.stringify(d.decors) !== JSON.stringify(ALLOWED[id])) fail(`decors ${d.decors} != spec ${ALLOWED[id]}`);
  let info = await page.evaluate(() => window.eventide.info());
  if ('eclairs' in info.decor || 'inconnu' in info.decor) fail('an unknown decor id was kept');
  if (info.decor[first] !== 40) fail(`start level of ${first} is ${info.decor[first]}, expected 40`);
  if (info.pixelRatio > 1.5) fail(`pixel ratio ${info.pixelRatio} > 1.5`);

  // transition ~1 s
  const refused = await page.evaluate(() => window.eventide.setDecor('eclairs', 50));
  if (refused !== false) fail('setDecor accepted an id the scene does not have');
  await page.evaluate((decorId) => window.eventide.setDecor(decorId, 100), first);
  await page.waitForTimeout(350);
  const mid = (await page.evaluate(() => window.eventide.info())).decor[first];
  // software WebGL queues frames and then stalls for seconds while it catches up: wait for the
  // end of the transition (real time drives it) rather than sampling at a fixed instant
  let end = mid;
  const deadline = Date.now() + 12000;
  while (end !== 100 && Date.now() < deadline) {
    await page.waitForTimeout(250);
    end = (await page.evaluate(() => window.eventide.info())).decor[first];
  }
  if (!(mid > 40 && mid < 100)) fail(`level after 0.35 s is ${mid}, expected between 40 and 100 (eased)`);
  if (end !== 100) fail(`level is ${end} after 12 s, expected 100`);

  // frame cap and pause
  const count = () => page.evaluate(() => window.eventide.info().frames);
  const c0 = await count();
  await page.waitForTimeout(2000);
  const c1 = await count();
  const fps = (c1 - c0) / 2;
  if (fps > 31) fail(`${fps} images per second, above the 30 cap`);
  await page.evaluate(() => window.eventide.setPaused(true));
  const p0 = await count();
  await page.waitForTimeout(1000);
  const p1 = await count();
  if (p1 !== p0) fail(`${p1 - p0} images drawn while paused`);
  await page.evaluate(() => window.eventide.setPaused(false));
  // as for the transition: software WebGL may still be drawing the images queued before the pause
  // (a few seconds for the heavy HDR scenes), so the first new image is awaited up to 6 s
  let resumed = false;
  const resumeDeadline = Date.now() + 6000;
  while (!resumed && Date.now() < resumeDeadline) {
    await page.waitForTimeout(200);
    resumed = (await count()) > p1;
  }
  if (!resumed) fail('no image within 6 s after setPaused(false)');
  await page.evaluate(() => window.eventide.dispose());
  if (await page.evaluate(() => document.querySelector('canvas') !== null)) fail('canvas left after dispose()');
  if (messages.some((m) => m.type === 'error')) fail(`error message: ${JSON.stringify(messages.filter((m) => m.type === 'error'))}`);
  await page.close();

  // recording mode: t = 30 s gives the image of t = 0
  const rec = await browser.newPage({ viewport: { width: 180, height: 320 } });
  await rec.goto(`http://127.0.0.1:${port}/imaginaire/index.html?record=1&scene=${id}&t=0&w=180&h=320`);
  await rec.waitForFunction(() => window.eventideFrameReady === true, null, { timeout: 120000 });
  const diff = await rec.evaluate(async () => {
    const grab = async (t) => {
      await window.eventideRenderAt(t);
      const gl = window.eventide.debug().renderer.getContext();
      const px = new Uint8Array(180 * 320 * 4);
      gl.readPixels(0, 0, 180, 320, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return px;
    };
    const a = await grab(0);
    const b = await grab(30);
    let s = 0;
    for (let i = 0; i < a.length; i++) s += Math.abs(a[i] - b[i]);
    return s / a.length;
  });
  if (diff > 0.01) fail(`image at t=30 s differs from t=0 (mean ${diff.toFixed(3)})`);
  await rec.close();
  return { id, fps, ok: failures.length === 0, failures };
}

async function main() {
  const args = process.argv.slice(2);
  const i = args.indexOf('--scene');
  const ids = i >= 0 ? args[i + 1].split(',') : Object.keys(ALLOWED);
  const server = await start(8779);
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  let ok = true;
  try {
    for (const id of ids) {
      const r = await checkScene(browser, 8779, id);
      ok = ok && r.ok;
      console.log(`${r.ok ? 'OK  ' : 'FAIL'} ${id}${r.failures.length ? ': ' + r.failures.join('; ') : ''}`);
    }
  } finally {
    await browser.close();
    server.close();
  }
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
