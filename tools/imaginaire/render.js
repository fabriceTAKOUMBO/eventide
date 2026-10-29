#!/usr/bin/env node
// Offline renders of the Imaginaire 3D scenes, from their recording mode (headless Chromium,
// Playwright, software WebGL), and ffmpeg:
//
//   node tools/imaginaire/render.js sheet [--scene id,...]      contact sheets (review)
//   node tools/imaginaire/render.js shot --scene id --t 0,12 [--decor default|zero|max|JSON]
//   node tools/imaginaire/render.js stats [--scene id,...]      draw calls, triangles, fps
//   node tools/imaginaire/render.js video [--scene id,...]      poster + 30 s loop -> app/content
//   node tools/imaginaire/render.js seam [--scene id,...]       loop seam of the published mp4
//   node tools/imaginaire/render.js all                         everything + out/report.{json,md}
//
// Outputs: free scenes in app/assets/landscapes/<id>.{jpg,mp4}, Premium scenes in
// content/images/paysages/<id>.jpg and content/videos/paysages/<id>.mp4, then
// app/assets/landscapes/remote.json is rewritten (tools/media/remote_manifest.py).
// Work files (frames, lossless masters, sheets, report): tools/imaginaire/out/ (not in git).

'use strict';

const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');
const { chromium } = require('playwright');
const { start } = require('./serve');

const REPO = path.resolve(__dirname, '..', '..');
const OUT = path.join(__dirname, 'out');
const PERIOD = 30;
// Wallpaper loops: 24 images per second (as the filmed landscapes), rendered at 720x1280 in
// software WebGL (about 2.3 times faster than 1080x1920) and scaled to 1080x1920 (Lanczos) in
// the final encode; at 2.5 MB for 30 s the codec keeps no finer detail anyway.
const FPS = 24;
const RENDER_W = 720;
const RENDER_H = 1280;
const W = 1080;
const H = 1920;
// Contract § 8 (video of a landscape: 2.5 MB at most); the shared spec of the Imaginaire loops
// allows 4 MB: encodeFinal stays under 2.5 MB when CRF <= 30 can, else under 4 MB.
const VIDEO_LIMIT = 2.5 * 1000 * 1000;
const VIDEO_HARD_LIMIT = 4 * 1000 * 1000;

// Free (bundled in the app) or Premium (content server), as in the catalog.
const SCENES = {
  'foret-lucioles': { free: true },
  'lac-lune': { free: false },
  aurore: { free: false },
  'jardin-zen': { free: false },
  'mer-nuages': { free: false },
  ondes: { free: false },
};

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) args[key] = true;
      else { args[key] = next; i++; }
    } else args._.push(argv[i]);
  }
  return args;
}

function sceneList(args) {
  const ids = args.scene ? String(args.scene).split(',') : Object.keys(SCENES);
  ids.forEach((id) => { if (!SCENES[id]) throw new Error(`unknown scene ${id}`); });
  return ids.filter((id) => fs.existsSync(path.join(REPO, 'app', 'assets', 'imaginaire', 'scenes', `${id}.js`)));
}

// Every poster is bundled in the app (free users see real tiles for the Premium scenes); the
// wallpaper loop of the free scene is bundled, the Premium loops go to the content server.
function mediaPaths(id) {
  const bundled = path.join(REPO, 'app', 'assets', 'landscapes');
  return {
    poster: path.join(bundled, `${id}.jpg`),
    video: SCENES[id].free
      ? path.join(bundled, `${id}.mp4`)
      : path.join(REPO, 'content', 'videos', 'paysages', `${id}.mp4`),
  };
}
const POSTER_LIMIT = 300 * 1000;

function rel(p) {
  return path.relative(REPO, p);
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

// ------------------------------------------------------------------ browser
async function launch() {
  return chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
}

async function openRecorder(browser, port, id, w = W, h = H, decor = null) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') errors.push(m.text());
  });
  const q = new URLSearchParams({ record: '1', scene: id, t: '0', w: String(w), h: String(h) });
  if (decor) q.set('decor', JSON.stringify(decor));
  await page.goto(`http://127.0.0.1:${port}/imaginaire/index.html?${q}`);
  await page.waitForFunction(() => window.eventideFrameReady === true, null, { timeout: 300000 });
  const meta = await page.evaluate(() => window.eventide.describe());
  return { page, errors, meta };
}

async function frameAt(page, t, decor) {
  const info = await page.evaluate(([time, levels]) => window.eventideRenderAt(time, levels), [t, decor]);
  const png = await page.locator('canvas#scene').screenshot({ type: 'png' });
  return { png, info };
}

function decorSets(meta) {
  const max = {};
  meta.decors.forEach((d) => { max[d] = 100; });
  return { zero: {}, default: meta.defaults, max };
}

function resolveDecor(meta, spec) {
  if (!spec || spec === 'default') return meta.defaults;
  if (spec === 'zero') return {};
  if (spec === 'max') return decorSets(meta).max;
  return JSON.parse(spec);
}

// ------------------------------------------------------------------ ffmpeg helpers
function ffmpeg(args, input) {
  const res = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { input, maxBuffer: 1 << 30 });
  if (res.status !== 0) throw new Error(`ffmpeg ${args.join(' ')}: ${res.stderr}`);
  return res.stdout;
}

function ffprobe(file) {
  const res = spawnSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file]);
  return JSON.parse(res.stdout.toString());
}

// Grey 270x480 frames of a video, decoded: [Buffer]
function decodeGrey(file, w = 270, h = 480) {
  const raw = ffmpeg(['-i', file, '-vf', `scale=${w}:${h}:flags=area,format=gray`, '-f', 'rawvideo', '-']);
  const size = w * h;
  const frames = [];
  for (let off = 0; off + size <= raw.length; off += size) frames.push(raw.subarray(off, off + size));
  return frames;
}

function mad(a, b) {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += Math.abs(a[i] - b[i]);
  return s / a.length;
}

// Loop seam: mean absolute difference (grey levels, 0-255) between the last and the first image,
// against the steps between consecutive images. In the H.264 file every keyframe (each 2 s)
// refreshes what the P-frames left behind, so the steps into a keyframe are compared too: the
// seam is one of them (the first image is a keyframe).
function seamOf(frames, gop) {
  const steps = [];
  const keySteps = [];
  for (let i = 1; i < frames.length; i++) {
    const s = mad(frames[i - 1], frames[i]);
    steps.push(s);
    if (gop && i % gop === 0) keySteps.push(s);
  }
  const med = (list) => list.slice().sort((x, y) => x - y)[Math.floor(list.length / 2)];
  const median = med(steps);
  const seam = mad(frames[frames.length - 1], frames[0]);
  const result = {
    frames: frames.length,
    seam_mad: +seam.toFixed(4),
    step_median_mad: +median.toFixed(4),
    step_max_mad: +Math.max(...steps).toFixed(4),
    seam_ratio: +(seam / Math.max(median, 1e-6)).toFixed(3),
  };
  if (keySteps.length) {
    result.keyframe_step_median_mad = +med(keySteps).toFixed(4);
    result.seam_vs_keyframe_ratio = +(seam / Math.max(med(keySteps), 1e-6)).toFixed(3);
  }
  return result;
}

// ------------------------------------------------------------------ commands
async function cmdShot(browser, port, args) {
  const id = sceneList(args)[0];
  const times = String(args.t || '0').split(',').map(Number);
  const w = Number(args.w || W), h = Number(args.h || H);
  const outDir = args.out ? path.resolve(args.out) : path.join(OUT, 'shots');
  ensureDir(outDir);
  const { page, errors, meta } = await openRecorder(browser, port, id, w, h);
  const decor = resolveDecor(meta, args.decor);
  for (const t of times) {
    const { png, info } = await frameAt(page, t, decor);
    const file = path.join(outDir, `${id}-t${String(t).replace('.', '_')}-${args.decor || 'default'}.png`);
    fs.writeFileSync(file, png);
    console.log(`${rel(file)}  calls=${info.calls} tris=${info.triangles} points=${info.points}`);
  }
  if (errors.length) console.log('page errors:', errors.join('\n'));
  await page.close();
}

async function cmdSheet(browser, port, args) {
  ensureDir(OUT);
  const results = {};
  for (const id of sceneList(args)) {
    const t0 = Date.now();
    const { page, errors, meta } = await openRecorder(browser, port, id);
    const sets = decorSets(meta);
    const times = [0, 7.5, 15, 22.5];
    const cells = [];
    for (const name of ['default', 'zero', 'max']) {
      for (const t of times) {
        const { png, info } = await frameAt(page, t, sets[name]);
        cells.push({ label: `${name} · t=${t}s · ${info.calls} draws`, png });
      }
    }
    for (const d of meta.decors) {
      const { png, info } = await frameAt(page, 10, { [d]: 100 });
      cells.push({ label: `${d} 100 · t=10s · ${info.calls} draws`, png });
    }
    await page.close();
    const sheet = await composeSheet(browser, `${id}`, cells, 4);
    const file = path.join(OUT, `${id}-sheet.jpg`);
    fs.writeFileSync(file, sheet);
    // full-size default frame at t=0 for close review
    results[id] = { sheet: rel(file), errors, seconds: Math.round((Date.now() - t0) / 1000) };
    console.log(`${rel(file)} (${results[id].seconds} s)${errors.length ? ' errors: ' + errors.join(' | ') : ''}`);
  }
  return results;
}

async function composeSheet(browser, title, cells, columns) {
  const tw = 270, th = 480;
  const page = await browser.newPage({ viewport: { width: columns * (tw + 8) + 8, height: 200 }, deviceScaleFactor: 1 });
  const html = `<!doctype html><html><body style="margin:0;background:#111;color:#ddd;font:13px sans-serif">
    <div style="padding:8px 8px 0">${title}</div>
    <div style="display:grid;grid-template-columns:repeat(${columns},${tw}px);gap:8px;padding:8px">
    ${cells.map((c) => `<figure style="margin:0"><img style="display:block;width:${tw}px;height:${th}px" src="data:image/png;base64,${c.png.toString('base64')}"><figcaption style="padding:3px 0 0">${c.label}</figcaption></figure>`).join('')}
    </div></body></html>`;
  await page.setContent(html);
  await page.evaluate(() => Promise.all(Array.from(document.images).map((i) => i.decode())));
  const buf = await page.screenshot({ type: 'jpeg', quality: 88, fullPage: true });
  await page.close();
  return buf;
}

// Draw calls / triangles per decor set (540x960 recording frame), the software-GL time of a
// phone-sized frame, and the real-time loop
// measured in a phone-sized page (360x780 CSS px, device pixel ratio 3 -> capped to 1.5).
async function cmdStats(browser, port, args) {
  const results = {};
  for (const id of sceneList(args)) {
    const { page, meta } = await openRecorder(browser, port, id, 540, 960);
    const sets = decorSets(meta);
    const counters = {};
    for (const name of ['zero', 'default', 'max']) {
      const { info } = await frameAt(page, 10, sets[name]);
      counters[name] = { calls: info.calls, triangles: info.triangles, points: info.points, programs: info.programs };
    }
    await page.close();
    // GPU cost proxy: software-GL time of one frame (default decor) at a phone's buffer size
    // (540x1170, the S24 at pixel ratio 1.5), forced to finish with a 1-pixel readback
    const probe = await openRecorder(browser, port, id, 540, 1170);
    const swMs = await probe.page.evaluate((levels) => {
      window.eventideRenderAt(10, levels);
      const d = window.eventide.debug();
      const gl = d.renderer.getContext();
      const px = new Uint8Array(4);
      const once = () => { d.renderer.render(d.scene, d.camera); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); };
      once();
      const t0 = performance.now();
      for (let i = 0; i < 4; i++) once();
      return Math.round((performance.now() - t0) / 4);
    }, meta.defaults);
    await probe.page.close();
    // real-time loop, phone-sized
    const live = await browser.newPage({ viewport: { width: 360, height: 780 }, deviceScaleFactor: 3 });
    const stats = [];
    live.on('console', (m) => {
      const text = m.text();
      if (text.startsWith('[EventideScene]')) {
        const msg = JSON.parse(text.slice('[EventideScene]'.length).trim());
        if (msg.type === 'stats') stats.push(msg);
      }
    });
    await live.goto(`http://127.0.0.1:${port}/imaginaire/index.html`);
    await live.evaluate(([sceneId, decor]) => window.eventide.start(sceneId, { decor, quality: 'high', fps: 30 }), [id, meta.defaults]);
    const t0 = Date.now();
    while (stats.length < 1 && Date.now() - t0 < 40000) await live.waitForTimeout(500);
    const liveInfo = await live.evaluate(() => window.eventide.info());
    await live.close();
    results[id] = {
      counters,
      live: { buffer: `${liveInfo.width}x${liveInfo.height}`, pixelRatio: liveInfo.pixelRatio, ...(stats[0] || {}) },
      software_gl_ms_540x1170: swMs,
    };
    console.log(id, JSON.stringify(results[id]));
  }
  return results;
}

async function cmdVideo(browser, port, args) {
  ensureDir(OUT);
  const results = {};
  for (const id of sceneList(args)) {
    const t0 = Date.now();
    const master = path.join(OUT, `${id}-master.mkv`);
    if (args['reuse-master'] && fs.existsSync(master)) {
      // re-encode only (e.g. another size limit), the frames are unchanged
      results[id] = publish(id, master, null, [], t0, Boolean(args.strict));
      continue;
    }
    const { page, errors, meta } = await openRecorder(browser, port, id, RENDER_W, RENDER_H);
    // lossless master (x264 qp 0, RGB -> yuv444) fed with the PNG frames
    const enc = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS),
      '-c:v', 'png', '-i', '-', '-c:v', 'libx264rgb', '-qp', '0', '-preset', 'ultrafast', master],
    { stdio: ['pipe', 'inherit', 'inherit'] });
    const done = new Promise((ok, ko) => enc.on('close', (code) => (code === 0 ? ok() : ko(new Error(`ffmpeg exit ${code}`)))));
    const frames = PERIOD * FPS;
    let info = null;
    for (let i = 0; i < frames; i++) {
      const f = await frameAt(page, i / FPS, meta.defaults);
      if (i === 0) info = f.info;
      if (!enc.stdin.write(f.png)) await new Promise((ok) => enc.stdin.once('drain', ok));
      if (i % 150 === 0) process.stdout.write(`  ${id}: frame ${i}/${frames}\n`);
    }
    enc.stdin.end();
    await done;
    await page.close();
    results[id] = publish(id, master, info, errors, t0, Boolean(args.strict));
  }
  writeManifest();
  return results;
}

// Final H.264 loop and its poster, from the lossless master.
function publish(id, master, info, errors, t0, strict) {
  const out = mediaPaths(id);
  ensureDir(path.dirname(out.video));
  ensureDir(path.dirname(out.poster));
  const encoded = encodeFinal(master, out.video, strict);
  // the poster is exactly the first decoded image of the published video (contract § 8),
  // JPEG at the best quality that fits POSTER_LIMIT
  let posterQ = null;
  for (const q of [2, 3, 4, 5, 6, 8, 10]) {
    ffmpeg(['-i', out.video, '-frames:v', '1', '-q:v', String(q), out.poster]);
    posterQ = q;
    if (fs.statSync(out.poster).size <= POSTER_LIMIT) break;
  }
  // a Premium poster is bundled, never on the content server (the APK check forbids both)
  const stale = path.join(REPO, 'content', 'images', 'paysages', `${id}.jpg`);
  if (fs.existsSync(stale)) fs.unlinkSync(stale);
  const result = {
    video: rel(out.video), poster: rel(out.poster), master: rel(master),
    video_bytes: fs.statSync(out.video).size, poster_bytes: fs.statSync(out.poster).size, poster_q: posterQ,
    encode: encoded, draws_t0: info, errors, seconds: Math.round((Date.now() - t0) / 1000),
  };
  console.log(id, JSON.stringify(result));
  return result;
}

// H.264 High, yuv420p, 1080x1920, 24 fps, keyframe every 2 s, no B-frames, no audio (as the filmed
// landscapes): the lowest CRF that fits under the contract's 2.5 MB while the quality stays good
// (CRF <= 30); otherwise (moving water costs bits) the lowest CRF under the spec's 4 MB.
// strict (--strict): the lowest CRF under 2.5 MB whatever the quality.
function encodeFinal(master, outFile, strict = false) {
  // work file in out/, never next to the published file (remote.json lists every *.mp4 there)
  const tmp = path.join(OUT, `${path.basename(outFile, '.mp4')}.encode.mp4`);
  const encode = (crf) => {
    ffmpeg(['-i', master, '-an', '-vf', `scale=${W}:${H}:flags=lanczos`, '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-preset', 'slower',
      '-crf', String(crf), '-r', String(FPS), '-g', String(2 * FPS), '-keyint_min', String(2 * FPS), '-sc_threshold', '0', '-bf', '0',
      '-x264-params', 'aq-mode=3:aq-strength=0.9:deblock=1,1', '-movflags', '+faststart', tmp]);
    return { crf, bytes: fs.statSync(tmp).size };
  };
  let chosen = null;
  for (const crf of [20, 22, 24, 26, 28, 30]) {
    chosen = encode(crf);
    if (chosen.bytes <= VIDEO_LIMIT) break;
  }
  const limit = strict ? VIDEO_LIMIT : VIDEO_HARD_LIMIT;
  if (chosen.bytes > VIDEO_LIMIT) {
    for (const crf of [31, 32, 33, 34, 35, 36, 37, 38, 40, 42]) {
      chosen = encode(crf);
      if (chosen.bytes <= limit) break;
    }
  }
  if (chosen.bytes > limit) throw new Error(`${outFile}: ${chosen.bytes} bytes even at CRF ${chosen.crf}`);
  chosen.over_contract_limit = chosen.bytes > VIDEO_LIMIT;
  fs.renameSync(tmp, outFile);
  return chosen;
}

function cmdSeam(args) {
  const results = {};
  for (const id of sceneList(args)) {
    const out = mediaPaths(id);
    const master = path.join(OUT, `${id}-master.mkv`);
    const res = {};
    if (fs.existsSync(master)) res.master = seamOf(decodeGrey(master));
    if (fs.existsSync(out.video)) {
      res.published = seamOf(decodeGrey(out.video), 2 * FPS);
      const probe = ffprobe(out.video);
      const v = probe.streams.find((s) => s.codec_type === 'video');
      res.video = {
        bytes: fs.statSync(out.video).size, codec: v.codec_name, profile: v.profile, pix_fmt: v.pix_fmt,
        size: `${v.width}x${v.height}`, fps: v.r_frame_rate, duration: Number(probe.format.duration),
        audio: probe.streams.some((s) => s.codec_type === 'audio'),
      };
      // the poster equals the first decoded frame (JPEG aside)
      const first = decodeGrey(out.video)[0];
      const poster = ffmpeg(['-i', out.poster, '-vf', 'scale=270:480:flags=area,format=gray', '-f', 'rawvideo', '-']);
      res.poster_vs_first_mad = +mad(first, poster).toFixed(3);
    }
    results[id] = res;
    console.log(id, JSON.stringify(res));
  }
  return results;
}

function writeManifest() {
  const res = spawnSync('python3', ['-c',
    'import sys; sys.path.insert(0, "tools/media"); import remote_manifest; print(remote_manifest.write_remote_manifest())'],
  { cwd: REPO });
  if (res.status !== 0) throw new Error(`remote_manifest: ${res.stderr}`);
  console.log(`rewrote app/assets/landscapes/remote.json`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] || 'sheet';
  const preview = require('./build-preview');
  if (command === 'all') preview.build();
  else if (!preview.upToDate()) console.warn('tools/imaginaire/preview/ differs from app/assets/imaginaire/: run node tools/imaginaire/build-preview.js');
  ensureDir(OUT);
  if (command === 'seam') {
    cmdSeam(args);
    return;
  }
  const server = await start(Number(args.port) || 8766);
  const port = server.address().port;
  const browser = await launch();
  try {
    if (command === 'shot') await cmdShot(browser, port, args);
    else if (command === 'sheet') await cmdSheet(browser, port, args);
    else if (command === 'stats') await cmdStats(browser, port, args);
    else if (command === 'video') await cmdVideo(browser, port, args);
    else if (command === 'all') {
      const report = { generated: new Date().toISOString(), three: require('./node_modules/three/package.json').version };
      report.sheets = await cmdSheet(browser, port, args);
      report.stats = await cmdStats(browser, port, args);
      report.videos = await cmdVideo(browser, port, args);
      report.seams = cmdSeam(args);
      fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2));
      console.log(`wrote ${rel(path.join(OUT, 'report.json'))}`);
    } else throw new Error(`unknown command ${command}`);
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
