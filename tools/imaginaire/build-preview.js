#!/usr/bin/env node
// Makes tools/imaginaire/preview/ self-contained: copies next to preview/index.html the runtime,
// the shared decor and scenery code, the six scenes and the vendored three.js exactly as the app
// bundles them (app/assets/imaginaire/), plus the UI font (Manrope, OFL). The folder can then be
// opened locally (node tools/imaginaire/serve.js) or published as a multi-file page: it loads only
// relative files, no network.
//
// Usage (from the repository root): node tools/imaginaire/build-preview.js
// Run it after any change in app/assets/imaginaire/ (`render.js all` runs it; the other commands of
// render.js warn when the copies differ from the app's files).

'use strict';

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const SRC = path.join(REPO, 'app', 'assets', 'imaginaire');
const OUT = path.join(__dirname, 'preview');

function files() {
  const list = [
    ['runtime.js', path.join(SRC, 'runtime.js')],
    ['decors.js', path.join(SRC, 'decors.js')],
    ['scenery.js', path.join(SRC, 'scenery.js')],
    ['vendor/three.min.js', path.join(SRC, 'vendor', 'three.min.js')],
    ['vendor/LICENSE-three.txt', path.join(SRC, 'vendor', 'LICENSE-three.txt')],
    ['fonts/Manrope-Variable.ttf', path.join(REPO, 'app', 'assets', 'fonts', 'Manrope-Variable.ttf')],
    ['fonts/OFL-Manrope.txt', path.join(REPO, 'app', 'assets', 'fonts', 'OFL-Manrope.txt')],
  ];
  fs.readdirSync(path.join(SRC, 'scenes')).filter((f) => f.endsWith('.js')).sort().forEach((f) => {
    list.push([`scenes/${f}`, path.join(SRC, 'scenes', f)]);
  });
  return list;
}

// true when every copy equals its source
function upToDate() {
  return files().every(([rel, src]) => {
    const dst = path.join(OUT, rel);
    return fs.existsSync(dst) && fs.readFileSync(dst).equals(fs.readFileSync(src));
  });
}

function build() {
  const list = files();
  const keep = new Set(list.map(([rel]) => rel));
  for (const dir of ['scenes', 'vendor', 'fonts']) {
    const d = path.join(OUT, dir);
    if (!fs.existsSync(d)) continue;
    for (const f of fs.readdirSync(d)) {
      if (!keep.has(`${dir}/${f}`)) fs.unlinkSync(path.join(d, f));
    }
  }
  for (const [rel, src] of list) {
    const dst = path.join(OUT, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
  }
  return ['index.html', ...list.map(([rel]) => rel)];
}

module.exports = { build, upToDate };

if (require.main === module) {
  const published = build();
  console.log(`tools/imaginaire/preview/ (${published.length} files):`);
  published.forEach((f) => console.log(`  ${f}`));
}
