#!/usr/bin/env node
// Local static server for the Imaginaire scenes (offline, 127.0.0.1 only):
//   /imaginaire/...  -> app/assets/imaginaire/ (the runtime exactly as bundled in the app)
//   /preview/...     -> tools/imaginaire/preview/ (all scenes, decor sliders; run
//                       node tools/imaginaire/build-preview.js first)
//
// Usage: node tools/imaginaire/serve.js [port]   then open http://127.0.0.1:8765/preview/

'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const ROOTS = {
  '/imaginaire/': path.join(REPO, 'app', 'assets', 'imaginaire'),
  '/preview/': path.join(__dirname, 'preview'),
};
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.ttf': 'font/ttf',
};

function resolve(urlPath) {
  for (const prefix of Object.keys(ROOTS)) {
    if (urlPath.startsWith(prefix)) {
      const root = ROOTS[prefix];
      let file = path.normalize(path.join(root, decodeURIComponent(urlPath.slice(prefix.length))));
      if (file !== root && !file.startsWith(root + path.sep)) return null;
      if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
      return file;
    }
  }
  return null;
}

function start(port = 8765) {
  const server = http.createServer((req, res) => {
    const urlPath = new URL(req.url, 'http://127.0.0.1').pathname;
    if (urlPath === '/' || urlPath === '/preview') {
      res.writeHead(302, { Location: '/preview/' });
      res.end();
      return;
    }
    const file = resolve(urlPath);
    if (!file || !fs.existsSync(file)) {
      res.writeHead(404);
      res.end('not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(port, '127.0.0.1', () => ok(server)));
}

module.exports = { start };

if (require.main === module) {
  const port = Number(process.argv[2]) || 8765;
  start(port).then(() => console.log(`Imaginaire preview: http://127.0.0.1:${port}/preview/`));
}
