#!/usr/bin/env node
// Generate Eventide brand assets (logo, Play Store icon, Android launcher icons,
// wordmark) from the mockup's icon SVG, rendered with Playwright + Chromium.
//
// The mockup used an external photo inside the drop and behind the glass; it is
// replaced here by a synthetic forest / waterfall scene drawn in SVG, so every
// asset is generated from scratch.
//
// Usage (from the repository root):  node tools/media/generate_icons.js

'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const REPO = path.resolve(__dirname, '..', '..');
const BRAND = path.join(REPO, 'app', 'assets', 'brand');
const RES = path.join(REPO, 'app', 'android', 'app', 'src', 'main', 'res');
const FONT = path.join(REPO, 'app', 'assets', 'fonts', 'Fraunces-Variable.ttf');

const DENSITIES = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };

// --------------------------------------------------------------------------
// Synthetic scene (400 x 600, portrait): light through a forest, a small
// waterfall, a teal pool and mossy banks. Inside the drop it is shown upside
// down, like a lens.
// --------------------------------------------------------------------------

function rand(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

// A row of pine silhouettes standing on `base`, as one closed path.
function pines(seed, base, x0, x1, minH, maxH, minW, maxW) {
  const r = rand(seed);
  let d = `M${x0} ${base}`;
  let x = x0;
  while (x < x1) {
    const w = minW + r() * (maxW - minW);
    const h = minH + r() * (maxH - minH);
    const cx = x + w / 2;
    const top = base - h;
    const tiers = 3 + Math.floor(r() * 3);
    // left flank going up with tiers, then right flank going down
    const left = [];
    const right = [];
    for (let i = 0; i < tiers; i++) {
      const yy = base - (h * (i + 1)) / (tiers + 0.6);
      const half = (w / 2) * (1 - (i + 1) / (tiers + 1.2));
      left.push(`L${(cx - half - w * 0.08).toFixed(1)} ${(yy + h * 0.06).toFixed(1)}`);
      left.push(`L${(cx - half * 0.55).toFixed(1)} ${yy.toFixed(1)}`);
      right.unshift(`L${(cx + half + w * 0.08).toFixed(1)} ${(yy + h * 0.06).toFixed(1)}`);
      right.unshift(`L${(cx + half * 0.55).toFixed(1)} ${yy.toFixed(1)}`);
    }
    d += ` L${x.toFixed(1)} ${base} ${left.join(' ')} L${cx.toFixed(1)} ${top.toFixed(1)} ${right.join(' ')} L${(x + w).toFixed(1)} ${base}`;
    x += w * (0.55 + r() * 0.35);
  }
  return `${d} L${x1} ${base + 40} L${x0} ${base + 40} Z`;
}

const SCENE_DEFS = `
<linearGradient id="scSky" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#eef3df"/><stop offset=".18" stop-color="#b9d9bf"/>
  <stop offset=".36" stop-color="#5f8f6f"/><stop offset=".5" stop-color="#26493a"/>
  <stop offset="1" stop-color="#10261d"/>
</linearGradient>
<radialGradient id="scSun" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(215 115) scale(175)">
  <stop offset="0" stop-color="#fff7dc" stop-opacity=".95"/><stop offset=".45" stop-color="#f3e7bd" stop-opacity=".35"/>
  <stop offset="1" stop-color="#f3e7bd" stop-opacity="0"/>
</radialGradient>
<linearGradient id="scWater" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#5fb3a6"/><stop offset=".25" stop-color="#2f7f7a"/>
  <stop offset=".7" stop-color="#17494b"/><stop offset="1" stop-color="#0b2623"/>
</linearGradient>
<linearGradient id="scFall" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#d9f4ea" stop-opacity="0"/><stop offset=".35" stop-color="#e6f8f0" stop-opacity=".55"/>
  <stop offset="1" stop-color="#ffffff" stop-opacity=".85"/>
</linearGradient>
<linearGradient id="scRefl" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#e9fbe9" stop-opacity=".55"/><stop offset="1" stop-color="#e9fbe9" stop-opacity="0"/>
</linearGradient>
<filter id="scSoft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
<filter id="scHaze" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.5"/></filter>
`;

const SCENE = `
<g id="scene">
  <rect width="400" height="600" fill="url(#scSky)"/>
  <circle cx="215" cy="115" r="175" fill="url(#scSun)"/>
  <g fill="#fff3d2" opacity=".12">
    <path d="M205 70 L120 330 L158 330 Z"/><path d="M225 70 L230 330 L262 330 Z"/><path d="M240 80 L330 320 L352 312 Z"/>
  </g>
  <path d="${pines(7, 250, -20, 420, 40, 85, 26, 44)}" fill="#46765c" opacity=".75" filter="url(#scHaze)"/>
  <path d="${pines(11, 285, -20, 420, 60, 120, 30, 52)}" fill="#2a5341"/>
  <g filter="url(#scHaze)">
    <path d="M176 232 C181 262 172 292 176 322 L200 322 C197 292 205 262 198 232 Z" fill="url(#scFall)"/>
    <path d="M214 262 C216 284 212 304 215 322 L222 322 C220 304 223 284 220 262 Z" fill="url(#scFall)" opacity=".7"/>
  </g>
  <path d="M184 250 C186 276 182 300 185 322" stroke="#ffffff" stroke-opacity=".5" stroke-width="1.5" fill="none"/>
  <rect y="312" width="400" height="288" fill="url(#scWater)"/>
  <ellipse cx="190" cy="322" rx="78" ry="16" fill="#effff7" opacity=".7" filter="url(#scSoft)"/>
  <rect x="150" y="326" width="96" height="190" fill="url(#scRefl)"/>
  <g stroke="#c8f5e8" stroke-opacity=".4" stroke-width="2" stroke-linecap="round">
    <path d="M70 352 H160"/><path d="M230 362 H330"/><path d="M110 386 H190"/><path d="M220 404 H290"/>
    <path d="M60 430 H130"/><path d="M250 446 H350"/>
  </g>
  <path d="${pines(23, 330, -40, 95, 150, 250, 46, 70)}" fill="#163628"/>
  <path d="${pines(31, 335, 300, 440, 140, 240, 46, 70)}" fill="#14322a"/>
  <path d="M0 430 C55 410 110 438 138 474 C160 504 152 560 126 600 L0 600 Z" fill="#103122"/>
  <path d="M400 452 C352 430 300 458 282 494 C270 530 290 570 312 600 L400 600 Z" fill="#0f2c22"/>
  <ellipse cx="128" cy="470" rx="26" ry="12" fill="#29473b"/><ellipse cx="292" cy="492" rx="22" ry="10" fill="#26423a"/>
  <path d="M0 430 C55 410 110 438 138 474" stroke="#6fae7d" stroke-opacity=".45" stroke-width="5" fill="none"/>
</g>`;

// --------------------------------------------------------------------------
// Icon parts, from the mockup (viewBox 0 0 512 512)
// --------------------------------------------------------------------------

const DROP = 'M256 108 C259 108 262 112 266 118 C300 170 368 244 368 318 C368 380 318 412 256 412 C194 412 144 380 144 318 C144 244 212 170 246 118 C250 112 253 108 256 108 Z';

const ICON_DEFS = `
<clipPath id="rr"><rect width="512" height="512" rx="112"/></clipPath>
<clipPath id="dp"><path d="${DROP}"/></clipPath>
<filter id="bl" filterUnits="userSpaceOnUse" x="-400" y="-400" width="1312" height="1312"><feGaussianBlur stdDeviation="16"/></filter>
<filter id="b14" filterUnits="userSpaceOnUse" x="-100" y="-100" width="712" height="712"><feGaussianBlur stdDeviation="14"/></filter>
<filter id="b8" filterUnits="userSpaceOnUse" x="-100" y="-100" width="712" height="712"><feGaussianBlur stdDeviation="8"/></filter>
<filter id="b3" filterUnits="userSpaceOnUse" x="-100" y="-100" width="712" height="712"><feGaussianBlur stdDeviation="2.4"/></filter>
<filter id="lens"><feColorMatrix type="saturate" values="1.7"/><feComponentTransfer><feFuncR type="linear" slope="1.35" intercept="0.03"/><feFuncG type="linear" slope="1.35" intercept="0.03"/><feFuncB type="linear" slope="1.3" intercept="0.03"/></feComponentTransfer></filter>
<radialGradient id="rim" gradientUnits="userSpaceOnUse" cx="256" cy="316" r="132"><stop offset=".5" stop-color="#000" stop-opacity="0"/><stop offset=".82" stop-color="#000" stop-opacity=".38"/><stop offset="1" stop-color="#000" stop-opacity=".78"/></radialGradient>
<radialGradient id="vg" gradientUnits="userSpaceOnUse" cx="256" cy="235.52" r="399.36"><stop offset=".35" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".62"/></radialGradient>
<linearGradient id="sh" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="td" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#000" stop-opacity=".28"/><stop offset=".4" stop-color="#000" stop-opacity="0"/></linearGradient>
<radialGradient id="sd" cx=".5" cy=".62" r=".6"><stop offset="0" stop-color="#cdeee0" stop-opacity=".34"/><stop offset=".6" stop-color="#1b3d35" stop-opacity=".25"/><stop offset="1" stop-color="#000" stop-opacity=".55"/></radialGradient>
<linearGradient id="st" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset=".5" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity=".5"/></linearGradient>
${SCENE_DEFS}
${SCENE}`;

// Small droplets on the glass: [cx, cy, r, opacity]
const DROPLETS = [
  [92, 128, 11, 0.8], [428, 98, 7, 0.75], [74, 392, 13, 0.8], [444, 410, 9, 0.8], [420, 292, 5, 0.7],
  [150, 70, 5.5, 0.7], [400, 462, 4.5, 0.6], [60, 250, 5, 0.6], [448, 48, 19, 0.85], [58, 66, 8, 0.75],
  [210, 50, 9, 0.8], [300, 38, 6, 0.7], [366, 64, 12, 0.85], [474, 176, 6, 0.7], [462, 336, 10, 0.8],
  [408, 372, 17, 0.85], [40, 178, 9, 0.8], [116, 304, 7, 0.7], [62, 448, 21, 0.85], [180, 468, 12, 0.8],
  [296, 466, 7, 0.7], [346, 440, 10, 0.8], [36, 332, 5, 0.65], [480, 254, 8, 0.75], [132, 204, 15, 0.85],
  [398, 206, 11, 0.8], [252, 494, 5, 0.6], [140, 410, 6, 0.7], [470, 470, 7, 0.7], [30, 110, 4, 0.6],
  [210, 100, 4, 0.6], [448, 140, 4.5, 0.65],
];

function droplet([cx, cy, r, op]) {
  const hl = Math.max(1.6, r * 0.2);
  return `<g opacity="${op}"><ellipse cx="${(cx + r * 0.12).toFixed(2)}" cy="${(cy + r * 0.28).toFixed(2)}" rx="${r}" ry="${(r * 1.05).toFixed(2)}" fill="#000" fill-opacity=".4" filter="url(#b3)"/>`
    + `<circle cx="${cx}" cy="${cy}" r="${r}" fill="url(#sd)" stroke="#ffffff" stroke-opacity=".28" stroke-width="1.2"/>`
    + `<circle cx="${(cx - r * 0.36).toFixed(2)}" cy="${(cy - r * 0.4).toFixed(2)}" r="${hl.toFixed(2)}" fill="#ffffff" fill-opacity=".85"/></g>`;
}

// The scene as the blurred photo behind the glass, covering [x0, x0 + size].
function sceneCover(x0, size) {
  const k = Math.max(size / 400, size / 600);
  const tx = x0 + (size - 400 * k) / 2;
  const ty = x0 + (size - 600 * k) / 2;
  return `<g filter="url(#bl)"><use href="#scene" transform="translate(${tx.toFixed(2)} ${ty.toFixed(2)}) scale(${k.toFixed(4)})"/></g>`;
}

function glass(x0, size) {
  // The mockup's photo covered -60..572; the adaptive background covers the whole 108 dp canvas.
  const cover = size === 512 ? sceneCover(-60, 632) : sceneCover(x0, size);
  return cover
    + `<rect x="${x0}" y="${x0}" width="${size}" height="${size}" fill="#04140f" fill-opacity=".74"/>`
    + `<rect x="${x0}" y="${x0}" width="${size}" height="${size}" fill="url(#vg)"/>`
    + DROPLETS.map(droplet).join('')
    + '<circle cx="120" cy="210" r="54" fill="#8fd3b0" fill-opacity="0.1" filter="url(#b8)"/>'
    + '<circle cx="400" cy="170" r="44" fill="#f2c98a" fill-opacity="0.1" filter="url(#b8)"/>'
    + '<circle cx="380" cy="380" r="64" fill="#7fc6c0" fill-opacity="0.09" filter="url(#b8)"/>'
    + '<circle cx="130" cy="330" r="40" fill="#f2c98a" fill-opacity="0.07" filter="url(#b8)"/>';
}

// The big drop: shadow, upside-down scene seen through it, rim, sheen, highlights.
const BIG_DROP = `<g transform="translate(256 260) scale(.9) translate(-256 -260)">
<path d="${DROP}" transform="translate(10 16)" fill="#000" fill-opacity=".6" filter="url(#b14)"/>
<g clip-path="url(#dp)">
  <g filter="url(#lens)"><use href="#scene" transform="rotate(180 256 259) translate(91 42) scale(.825 .976667)"/></g>
  <rect x="120" y="90" width="280" height="340" fill="url(#rim)"/>
  <rect x="120" y="90" width="280" height="340" fill="url(#td)"/>
  <ellipse cx="262" cy="388" rx="86" ry="28" fill="#f2ffd9" fill-opacity=".62" filter="url(#b14)"/>
  <path d="${DROP}" fill="url(#sh)" fill-opacity=".55"/>
</g>
<path d="${DROP}" fill="none" stroke="url(#st)" stroke-width="3" stroke-linejoin="round"/>
<ellipse cx="190" cy="280" rx="8" ry="46" transform="rotate(10 190 280)" fill="#ffffff" fill-opacity=".4" filter="url(#b3)"/>
<ellipse cx="190" cy="280" rx="3.8" ry="38" transform="rotate(10 190 280)" fill="#ffffff" fill-opacity=".9"/>
<circle cx="238" cy="200" r="5" fill="#ffffff" fill-opacity=".85"/>
<ellipse cx="332" cy="366" rx="6" ry="17" transform="rotate(34 332 366)" fill="#ffffff" fill-opacity=".5" filter="url(#b3)"/>
</g>`;

// Themed-icon silhouette: white drop with its highlight streak cut out.
const MONO_DROP = `<defs><mask id="mono" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">
<path d="${DROP}" fill="#fff"/>
<ellipse cx="190" cy="280" rx="7" ry="40" transform="rotate(10 190 280)" fill="#000"/></mask></defs>
<g transform="translate(256 260) scale(.9) translate(-256 -260)"><rect width="512" height="512" fill="#ffffff" mask="url(#mono)"/></g>`;

/**
 * kind: 'logo'   rounded square, as in the mockup (0..512)
 *       'square' full-bleed square (store icons, no transparency)
 *       'background' | 'foreground' | 'monochrome'  adaptive icon layers:
 *       108 dp canvas, the 512 logo maps onto the inner 72 dp (-128..640).
 */
function iconSvg(kind, px) {
  const adaptive = ['background', 'foreground', 'monochrome'].includes(kind);
  const vb = adaptive ? '-128 -128 768 768' : '0 0 512 512';
  const size = px ? ` width="${px}" height="${px}"` : '';
  let body;
  if (kind === 'logo') body = `<g clip-path="url(#rr)">${glass(0, 512)}${BIG_DROP}</g>`;
  else if (kind === 'square') body = glass(0, 512) + BIG_DROP;
  else if (kind === 'background') body = glass(-128, 768);
  else if (kind === 'foreground') body = BIG_DROP;
  else body = MONO_DROP;
  const defs = kind === 'monochrome' ? '' : `<defs>${ICON_DEFS}</defs>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}"${size}>${defs}${body}</svg>`;
}

// --------------------------------------------------------------------------
// Wordmark: "Eventide" in Fraunces 500, with a drop as the dot of the i
// (dotless i U+0131 + drop), positioned like the mockup's CSS.
// --------------------------------------------------------------------------

const WORD = 'Eventıde';
const FONT_SIZE = 160;
const WORD_COLOR = '#f4f1ea';

function wordmarkSvg(fontUrl, geo, px) {
  const { x0, y0, w, h, baseline, dropX, dropBottom } = geo;
  const em = FONT_SIZE;
  const dw = 0.21 * em;
  const dh = 0.29 * em;
  const sx = dw / 20;
  const sy = dh / 28;
  const size = px ? ` width="${px}" height="${Math.round((px * h) / w)}"` : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${x0.toFixed(1)} ${y0.toFixed(1)} ${w.toFixed(1)} ${h.toFixed(1)}"${size}>
<!-- Font: Fraunces (SIL OFL), app/assets/fonts/Fraunces-Variable.ttf, weight 500. Text is not converted to paths. -->
<defs>
<style>@font-face{font-family:"Fraunces";src:url("${fontUrl}") format("truetype");font-weight:100 900;}
.wm{font-family:"Fraunces",Georgia,serif;font-weight:500;font-size:${em}px;letter-spacing:0}</style>
<linearGradient id="wmg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#eafcf3"/><stop offset="1" stop-color="#74c4ab"/></linearGradient>
</defs>
<text class="wm" x="0" y="${baseline}" fill="${WORD_COLOR}">${WORD}</text>
<g transform="translate(${(dropX - dw / 2).toFixed(2)} ${(dropBottom - dh).toFixed(2)}) scale(${sx.toFixed(4)} ${sy.toFixed(4)})">
<path d="M10 1 C10 1 2 11 2 18 a8 8 0 0 0 16 0 C18 11 10 1 10 1 Z" fill="url(#wmg)"/>
<ellipse cx="7" cy="17" rx="1.6" ry="3.2" fill="#fff" fill-opacity=".85" transform="rotate(12 7 17)"/>
</g>
<title>Eventide</title>
</svg>`;
}

// --------------------------------------------------------------------------
// Rendering
// --------------------------------------------------------------------------

async function render(page, svg, w, h, out, { opaque = false } = {}) {
  await page.setViewportSize({ width: w, height: h });
  await page.setContent(`<!doctype html><html><head><style>html,body{margin:0;background:transparent}svg{display:block}</style></head><body>${svg}</body></html>`);
  await page.evaluate(() => document.fonts.ready);
  fs.mkdirSync(path.dirname(out), { recursive: true });
  await page.screenshot({ path: out, omitBackground: !opaque, clip: { x: 0, y: 0, width: w, height: h } });
  return out;
}

async function measureWordmark(page, fontDataUrl) {
  await page.setViewportSize({ width: 1600, height: 400 });
  await page.setContent(`<!doctype html><html><body style="margin:0">
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="400" viewBox="0 -300 1600 400">
<style>@font-face{font-family:"Fraunces";src:url("${fontDataUrl}") format("truetype");font-weight:100 900;}
.wm{font-family:"Fraunces";font-weight:500;font-size:${FONT_SIZE}px;letter-spacing:0}</style>
<text id="t" class="wm" x="0" y="0">${WORD}</text></svg></body></html>`);
  await page.evaluate(() => document.fonts.ready);
  return page.evaluate(() => {
    const t = document.getElementById('t');
    const b = t.getBBox();
    const i = t.getExtentOfChar(5); // the dotless i
    const ok = document.fonts.check('500 160px Fraunces');
    return { bbox: { x: b.x, y: b.y, width: b.width, height: b.height }, iEnd: i.x + i.width, fontLoaded: ok };
  });
}

async function main() {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  const outputs = [];

  // Master SVG (as in the mockup: rounded square)
  fs.mkdirSync(BRAND, { recursive: true });
  fs.writeFileSync(path.join(BRAND, 'logo.svg'), `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Eventide app icon. Synthetic placeholder scene (no photo). Generated by tools/media/generate_icons.js -->\n${iconSvg('logo')}\n`);
  outputs.push(path.join(BRAND, 'logo.svg'));

  // Store / high-res icons: full-bleed, opaque (stores apply their own mask)
  for (const px of [1024, 512]) {
    outputs.push(await render(page, iconSvg('square', px), px, px, path.join(BRAND, `logo_${px}.png`), { opaque: true }));
  }

  // Android launcher icons
  for (const [dir, k] of Object.entries(DENSITIES)) {
    const legacy = Math.round(48 * k);
    const layer = Math.round(108 * k);
    const pad = Math.round(legacy / 24); // 1 dp margin around the legacy square
    const inner = legacy - 2 * pad;
    const legacySvg = `<div style="width:${legacy}px;height:${legacy}px;padding:${pad}px;box-sizing:border-box">${iconSvg('logo', inner)}</div>`;
    const mip = path.join(RES, `mipmap-${dir}`);
    outputs.push(await render(page, legacySvg, legacy, legacy, path.join(mip, 'ic_launcher.png')));
    outputs.push(await render(page, iconSvg('background', layer), layer, layer, path.join(mip, 'ic_launcher_background.png'), { opaque: true }));
    outputs.push(await render(page, iconSvg('foreground', layer), layer, layer, path.join(mip, 'ic_launcher_foreground.png')));
    outputs.push(await render(page, iconSvg('monochrome', layer), layer, layer, path.join(mip, 'ic_launcher_monochrome.png')));
  }
  const anydpi = path.join(RES, 'mipmap-anydpi-v26');
  fs.mkdirSync(anydpi, { recursive: true });
  fs.writeFileSync(path.join(anydpi, 'ic_launcher.xml'), `<?xml version="1.0" encoding="utf-8"?>
<!-- Adaptive launcher icon (Android 8+); monochrome layer for themed icons (Android 13+).
     Generated by tools/media/generate_icons.js -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
`);
  outputs.push(path.join(anydpi, 'ic_launcher.xml'));

  // Wordmark
  const fontDataUrl = `data:font/ttf;base64,${fs.readFileSync(FONT).toString('base64')}`;
  const m = await measureWordmark(page, fontDataUrl);
  if (!m.fontLoaded) throw new Error('Fraunces did not load');
  const em = FONT_SIZE;
  const dropX = m.iEnd - 0.155 * em; // mockup: left -.26em, width .21em from the end of the i
  const dropBottom = -0.54 * em; // mockup: bottom .54em above the baseline
  const top = Math.min(m.bbox.y, dropBottom - 0.29 * em);
  const margin = 0.08 * em;
  const geo = {
    x0: m.bbox.x - margin, y0: top - margin, w: m.bbox.width + 2 * margin,
    h: m.bbox.y + m.bbox.height - top + 2 * margin, baseline: 0, dropX, dropBottom,
  };
  const relFont = path.relative(BRAND, FONT).split(path.sep).join('/');
  fs.writeFileSync(path.join(BRAND, 'wordmark.svg'), `<?xml version="1.0" encoding="UTF-8"?>\n${wordmarkSvg(relFont, geo)}\n`);
  outputs.push(path.join(BRAND, 'wordmark.svg'));
  const wpx = 1200;
  const hpx = Math.round((wpx * geo.h) / geo.w);
  outputs.push(await render(page, wordmarkSvg(fontDataUrl, geo, wpx), wpx, hpx, path.join(BRAND, 'wordmark.png')));

  await browser.close();
  for (const f of outputs) {
    console.log(`${String(fs.statSync(f).size).padStart(8)}  ${path.relative(REPO, f)}`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
