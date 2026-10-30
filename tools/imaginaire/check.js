#!/usr/bin/env node
// Checks of the Imaginaire runtime in headless Chromium (software WebGL), for every scene:
//   - start() posts "ready", keeps only the scene's decor ids (unknown ids ignored), no error;
//   - setDecor() eases a level over about 1 s and refuses an id the scene does not have;
//   - setPaused(true) stops drawing, setPaused(false) resumes; at most 30 images per second;
//   - recording mode: the image at t = 30 s is the image at t = 0 (the period loops exactly);
//   - HDR safety: for a scene drawn through the HDR finish (post.js), its half-float target holds
//     no NaN, no Inf and no value near the half-float limit (> 60000) at t = 0, 7.5, 15, 22.5 s,
//     with the default decor and with every element at 100 (one such pixel spreads through the
//     bloom into black blocks on a phone GPU); the largest value is reported.
//     --mediump runs the scan a second time with the renderer forced to mediump (served by a
//     patched runtime.js): it catches shaders that fail to compile or link at that precision.
//     Software WebGL computes in 32-bit floats whatever the qualifier, so only a real phone GPU
//     shows the rounding of mediump.
//
// Usage: node tools/imaginaire/check.js [--scene id,...] [--port n] [--mediump]   exit 1 on failure

'use strict';

const { chromium } = require('playwright');
const { start } = require('./serve');

let MEDIUMP = false;

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
  // a small phone page (pixel ratio 2, capped to 1.5): the API checks need frames, not pixels, and
  // a heavy scene drawn in software WebGL at full size stalls for seconds between two frames
  const page = await browser.newPage({ viewport: { width: 180, height: 390 }, deviceScaleFactor: 2 });
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
  // (software WebGL may stall a few seconds before the next frame: wait for it)
  let resumed = false;
  for (const until = Date.now() + 10000; !resumed && Date.now() < until;) {
    await page.waitForTimeout(300);
    resumed = (await count()) !== p1;
  }
  if (!resumed) fail('no image after setPaused(false)');
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

  const scans = [await scanHdr(browser, port, id, 'highp')];
  if (MEDIUMP) scans.push(await scanHdr(browser, port, id, 'mediump'));
  scans.forEach((r) => {
    if (r.errors.length) fail(`${r.precision}: ${r.errors.join(' | ')}`);
    if (!r.hdr) return;
    if (r.nan || r.inf || r.big) fail(`${r.precision} HDR target: ${r.nan} NaN, ${r.inf} Inf, ${r.big} > 60000 pixels over ${r.frames} frames`);
  });
  return { id, fps, ok: failures.length === 0, failures, scans };
}

const PROBE = [
  'precision highp float;',
  'uniform sampler2D tSrc;',
  'void main() {',
  '  vec3 c = texelFetch(tSrc, ivec2(gl_FragCoord.xy), 0).rgb;',
  '  bool nan = isnan(c.r) || isnan(c.g) || isnan(c.b) || !(c.r == c.r) || !(c.g == c.g) || !(c.b == c.b);',
  '  bool inf = isinf(c.r) || isinf(c.g) || isinf(c.b);',
  '  float m = (nan || inf) ? 0.0 : max(c.r, max(c.g, c.b));',
  '  float lo = (nan || inf) ? 0.0 : min(c.r, min(c.g, c.b));',
  '  gl_FragColor = vec4(nan ? 1.0 : 0.0, inf ? 1.0 : 0.0, m > 60000.0 ? 1.0 : (lo < -0.01 ? 0.5 : 0.0),',
  '    clamp(log2(1.0 + max(m, 0.0)) / 17.0, 0.0, 1.0));',
  '}',
].join('\n');

// Scans the HDR target of the scene's finish (post.js), see the header.
async function scanHdr(browser, port, id, precision) {
  const page = await browser.newPage({ viewport: { width: 270, height: 480 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 300)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 300)); });
  if (precision === 'mediump') {
    await page.route('**/imaginaire/runtime.js', async (route) => {
      const res = await route.fetch();
      const hook = "powerPreference: 'default',";
      const body = await res.text();
      if (!body.includes(hook)) errors.push('runtime.js: renderer options not found, mediump not forced');
      await route.fulfill({ response: res, body: body.replace(hook, `${hook} precision: 'mediump',`) });
    });
  }
  await page.goto(`http://127.0.0.1:${port}/imaginaire/index.html?record=1&scene=${id}&t=0&w=270&h=480`);
  await page.waitForFunction(() => window.eventideFrameReady === true, null, { timeout: 300000 });
  const r = await page.evaluate(async (probe) => {
    const post = window.EventidePost && window.EventidePost.last;
    if (!post || !post.hdrTarget) return { hdr: false };
    const d = window.eventide.debug();
    const THREE = d.THREE, renderer = d.renderer;
    const meta = window.eventide.describe();
    const all = {};
    meta.decors.forEach((k) => { all[k] = 100; });
    const scene = new THREE.Scene(), cam = new THREE.PerspectiveCamera();
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute([-1, -1, 0, 3, -1, 0, -1, 3, 0], 3));
    const mat = new THREE.ShaderMaterial({
      uniforms: { tSrc: { value: null } }, depthTest: false, depthWrite: false,
      vertexShader: 'void main() { gl_Position = vec4(position.xy, 0.0, 1.0); }', fragmentShader: probe,
    });
    const mesh = new THREE.Mesh(geo, mat);
    mesh.frustumCulled = false;
    scene.add(mesh);
    const out = { hdr: true, renderer: renderer.capabilities.precision, frames: 0, nan: 0, inf: 0, big: 0, neg: 0, max: 0 };
    for (const levels of [meta.defaults, all]) {
      for (const t of [0, 7.5, 15, 22.5]) {
        await window.eventideRenderAt(t, levels);
        const hdr = post.hdrTarget();
        const w = hdr.width, h = hdr.height;
        const rt = new THREE.WebGLRenderTarget(w, h, { depthBuffer: false });
        mat.uniforms.tSrc.value = hdr.texture;
        renderer.setRenderTarget(rt);
        renderer.render(scene, cam);
        renderer.setRenderTarget(null);
        const px = new Uint8Array(w * h * 4);
        renderer.readRenderTargetPixels(rt, 0, 0, w, h, px);
        rt.dispose();
        for (let i = 0; i < px.length; i += 4) {
          if (px[i] > 127) out.nan++;
          if (px[i + 1] > 127) out.inf++;
          if (px[i + 2] > 200) out.big++;
          else if (px[i + 2] > 100) out.neg++;
          out.max = Math.max(out.max, px[i + 3]);
        }
        out.frames++;
      }
    }
    out.max = Math.round(Math.pow(2, out.max / 255 * 17) - 1);
    geo.dispose();
    mat.dispose();
    return out;
  }, PROBE);
  await page.close();
  return Object.assign({ precision, errors }, r);
}

async function main() {
  const args = process.argv.slice(2);
  const i = args.indexOf('--scene');
  const ids = i >= 0 ? args[i + 1].split(',') : Object.keys(ALLOWED);
  // --port: another free port when two checks run side by side (default 8779)
  MEDIUMP = args.includes('--mediump');
  const j = args.indexOf('--port');
  const port = j >= 0 ? Number(args[j + 1]) : 8779;
  const server = await start(port);
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  let ok = true;
  try {
    for (const id of ids) {
      const r = await checkScene(browser, port, id);
      ok = ok && r.ok;
      console.log(`${r.ok ? 'OK  ' : 'FAIL'} ${id}${r.failures.length ? ': ' + r.failures.join('; ') : ''}`);
      r.scans.forEach((sc) => {
        console.log(sc.hdr
          ? `     HDR ${sc.precision} (renderer ${sc.renderer}): ${sc.frames} frames, NaN ${sc.nan}, Inf ${sc.inf}, >60000 ${sc.big}, negative ${sc.neg}, max ${sc.max}`
          : `     HDR ${sc.precision}: no HDR finish (8-bit canvas)`);
      });
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
