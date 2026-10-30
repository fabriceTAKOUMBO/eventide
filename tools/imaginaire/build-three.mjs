#!/usr/bin/env node
// Builds app/assets/imaginaire/vendor/three.min.js from the pinned npm package `three`
// (package.json: exact version), tree-shaken to the names of three-entry.mjs, as ONE classic
// script defining the global `THREE`.
//
// Why a classic script and not the ES module files: the Android WebView loads the scenes from
// file:///android_asset/, where module scripts are refused (opaque origin, CORS) unless
// "file access from file URLs" is enabled, which webview_flutter does not expose. A classic
// script loads everywhere: WebView, desktop browser, Playwright.
//
// Usage (from tools/imaginaire/):  npm ci && node build-three.mjs
// The output is deterministic for the same versions of three and esbuild.

import { build } from 'esbuild';
import { copyFileSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const vendor = join(repo, 'app', 'assets', 'imaginaire', 'vendor');
const threePkg = JSON.parse(readFileSync(join(here, 'node_modules', 'three', 'package.json'), 'utf8'));
const esbuildPkg = JSON.parse(readFileSync(join(here, 'node_modules', 'esbuild', 'package.json'), 'utf8'));
const pinned = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8')).devDependencies;

if (threePkg.version !== pinned.three || esbuildPkg.version !== pinned.esbuild) {
  console.error(`installed three ${threePkg.version} / esbuild ${esbuildPkg.version} differ from the pins ` +
    `(${pinned.three} / ${pinned.esbuild}): run npm ci first`);
  process.exit(1);
}

const banner = [
  '/*!',
  ` * three.js ${threePkg.version} (npm package "three"), MIT License,`,
  ' * Copyright © 2010-2026 three.js authors. Full text: LICENSE-three.txt (next to this file).',
  ` * Tree-shaken classic build made by tools/imaginaire/build-three.mjs with esbuild ${esbuildPkg.version}.`,
  ' */',
].join('\n');

const out = join(vendor, 'three.min.js');
await build({
  entryPoints: [join(here, 'three-entry.mjs')],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'THREE',
  target: ['chrome90'],
  legalComments: 'none',
  banner: { js: banner },
  outfile: out,
  logLevel: 'warning',
});
copyFileSync(join(here, 'node_modules', 'three', 'LICENSE'), join(vendor, 'LICENSE-three.txt'));
writeFileSync(join(vendor, 'VERSION'), `three ${threePkg.version}\nesbuild ${esbuildPkg.version}\n`);
console.log(`${out}: ${(statSync(out).size / 1024).toFixed(0)} KiB (three ${threePkg.version})`);
