/*
 * « Jardin zen », version 2: a Japanese dry garden at dawn, drawn as a real 3D scene with
 * physically based materials and the HDR finish of post.js (the quality bar of the forest v2).
 *
 *   - Raked gravel with real relief: furrows with an analytic profile (normals and their own
 *     shadows under the low sun), straight lines running away from the viewer and rings around
 *     three groups of mossy stones set in islands of moss.
 *   - A clipped hedge and rounded azaleas (karikomi); behind them a bamboo grove (instanced culms
 *     and leaf cards, translucent against the light) that recedes into a golden haze.
 *   - A flowering cherry branch across the top of the view, its blossoms glowing against the sun.
 *   - A dark pond in the foreground (planar reflection in half float, ripples) behind kerb stones.
 *   - Light: a low warm sun (one directional light, static shadow map: long shadows), sky light,
 *     image-based light on the stones only; height fog with a forward-scattering lobe lit by the
 *     sun, and a band of ground mist integrated analytically in every shader, lit through the
 *     shadow map (the gaps of the hedge and the grove cut it into rays).
 * Everything that moves is a function of the scene time t (modulo 30 s): the period loops.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;
  var TAU = Math.PI * 2;

  // ------------------------------------------------------------------ layout
  var CAM = [0, 2.9, 8.0];
  var LOOK = [0.3, -1.3, -30];
  var SUN_AZ = 8.5, SUN_EL = 10.5;  // degrees: right of the view axis, above the horizon
  var POND_Y = -0.1;
  var POND_FAR = -3.3;             // far edge of the pond (kerb stones)
  var HEDGE_Z = -21.6;
  var BAMBOO_H = 12;
  // stone groups on islands of moss: centre x, z and the island's radii
  var GROUPS = [
    { x: -2.1, z: -8.3, rx: 1.55, rz: 1.15 },
    { x: 2.3, z: -12.4, rx: 2.1, rz: 1.45 },
    { x: -0.9, z: -17.2, rx: 1.4, rz: 1.0 },
  ];
  var RING = 1.9;                  // width of the raked rings around an island (m)

  function lin(hex) {
    return new THREE.Color(hex).convertSRGBToLinear();
  }

  // ------------------------------------------------------------------ procedural textures (JS)
  function dataTexture(data, w, h, opts) {
    var t = new THREE.DataTexture(data, w, h, THREE.RGBAFormat, THREE.UnsignedByteType);
    t.wrapS = t.wrapT = opts.repeat ? THREE.RepeatWrapping : THREE.ClampToEdgeWrapping;
    t.magFilter = THREE.LinearFilter;
    t.minFilter = opts.mipmaps || opts.mips ? THREE.LinearMipmapLinearFilter : THREE.LinearFilter;
    t.generateMipmaps = !!opts.mips;
    if (opts.mipmaps) t.mipmaps = opts.mipmaps;
    t.anisotropy = opts.anisotropy || 1;
    t.needsUpdate = true;
    return t;
  }

  // 128x128, tileable: R fbm (4..32 cells), G fbm (8..64), B fine fbm (16..64), A cells (Worley).
  function noiseTexture(rng) {
    var N = 128;
    var periods = [4, 8, 16, 32, 64];
    function lattice(P) {
      var a = new Float32Array(P * P);
      for (var i = 0; i < a.length; i++) a[i] = rng();
      return a;
    }
    var la = periods.map(lattice), lb = periods.map(lattice);
    function vnoise(lat, P, x, y) {
      var xi = Math.floor(x), yi = Math.floor(y), fx = x - xi, fy = y - yi;
      var ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
      var x0 = ((xi % P) + P) % P, x1 = (x0 + 1) % P, y0 = ((yi % P) + P) % P, y1 = (y0 + 1) % P;
      var a = lat[y0 * P + x0], b = lat[y0 * P + x1], c = lat[y1 * P + x0], d = lat[y1 * P + x1];
      return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
    }
    function fbm(lats, first, count, u, v) {
      var s = 0, amp = 0.5, n = 0;
      for (var o = first; o < first + count; o++) {
        var P = periods[o];
        s += amp * vnoise(lats[o], P, u * P, v * P);
        n += amp;
        amp *= 0.5;
      }
      return s / n;
    }
    var C = 8, pts = [];
    for (var k = 0; k < C * C; k++) pts.push(rng(), rng());
    function worley(u, v) {
      var x = u * C, y = v * C, xi = Math.floor(x), yi = Math.floor(y), best = 9;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          var cx = xi + dx, cy = yi + dy;
          var wx = ((cx % C) + C) % C, wy = ((cy % C) + C) % C;
          var px = cx + pts[(wy * C + wx) * 2], py = cy + pts[(wy * C + wx) * 2 + 1];
          var d = (px - x) * (px - x) + (py - y) * (py - y);
          if (d < best) best = d;
        }
      }
      return Math.sqrt(best);
    }
    var ch = [new Float32Array(N * N), new Float32Array(N * N), new Float32Array(N * N), new Float32Array(N * N)];
    for (var y = 0; y < N; y++) {
      for (var x = 0; x < N; x++) {
        var u = x / N, v = y / N, i = y * N + x;
        ch[0][i] = fbm(la, 0, 4, u, v);
        ch[1][i] = fbm(la, 1, 4, u, v);
        ch[2][i] = fbm(lb, 2, 3, u, v);
        ch[3][i] = worley(u, v);
      }
    }
    var data = new Uint8Array(N * N * 4);
    ch.forEach(function (c, j) {
      var lo = 1e9, hi = -1e9;
      for (var q = 0; q < c.length; q++) { lo = Math.min(lo, c[q]); hi = Math.max(hi, c[q]); }
      for (var p = 0; p < c.length; p++) data[p * 4 + j] = Math.round((c[p] - lo) / (hi - lo) * 255);
    });
    return dataTexture(data, N, N, { repeat: true, mips: true, anisotropy: 4 });
  }

  // A small raster of anti-aliased strokes: coverage (a), shade (s), tint (t).
  function raster(w, h) {
    return { w: w, h: h, a: new Float32Array(w * h), s: new Float32Array(w * h), t: new Float32Array(w * h) };
  }
  function stroke(c, x0, y0, x1, y1, r0, r1, shade, tint) {
    var rr = Math.max(r0, r1) + 1.5;
    var minx = Math.max(0, Math.floor(Math.min(x0, x1) - rr)), maxx = Math.min(c.w - 1, Math.ceil(Math.max(x0, x1) + rr));
    var miny = Math.max(0, Math.floor(Math.min(y0, y1) - rr)), maxy = Math.min(c.h - 1, Math.ceil(Math.max(y0, y1) + rr));
    var dx = x1 - x0, dy = y1 - y0, len2 = Math.max(1e-6, dx * dx + dy * dy);
    for (var y = miny; y <= maxy; y++) {
      for (var x = minx; x <= maxx; x++) {
        var px = x + 0.5, py = y + 0.5;
        var t = Math.max(0, Math.min(1, ((px - x0) * dx + (py - y0) * dy) / len2));
        var qx = x0 + dx * t - px, qy = y0 + dy * t - py;
        var cov = Math.max(0, Math.min(1, r0 + (r1 - r0) * t + 0.5 - Math.sqrt(qx * qx + qy * qy)));
        if (cov <= 0) continue;
        var i = y * c.w + x, a = c.a[i], na = a + cov * (1 - a);
        c.s[i] = (c.s[i] * a * (1 - cov) + shade * cov) / na;
        c.t[i] = (c.t[i] * a * (1 - cov) + tint * cov) / na;
        c.a[i] = na;
      }
    }
  }
  // RGBA bytes (R shade, G tint, A coverage) with mipmaps that keep the alpha-tested coverage.
  function coverageTexture(c) {
    var w = c.w, h = c.h, data = new Uint8Array(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      var a = c.a[i];
      data[i * 4] = Math.round((a > 0.02 ? c.s[i] : 0.55) * 255);
      data[i * 4 + 1] = Math.round((a > 0.02 ? c.t[i] : 0.5) * 255);
      data[i * 4 + 2] = 0;
      data[i * 4 + 3] = Math.round(a * 255);
    }
    function coverage(alpha, scale) {
      var n = 0;
      for (var q = 0; q < alpha.length; q++) if (alpha[q] * scale >= 0.5) n++;
      return n / alpha.length;
    }
    var a0 = new Float32Array(w * h);
    for (var p = 0; p < w * h; p++) a0[p] = data[p * 4 + 3] / 255;
    var target = coverage(a0, 1);
    var levels = [{ data: data, width: w, height: h }];
    var src = data, sw = w, sh = h;
    while (sw > 1 || sh > 1) {
      var nw = Math.max(1, sw >> 1), nh = Math.max(1, sh >> 1);
      var dst = new Uint8Array(nw * nh * 4), alpha = new Float32Array(nw * nh);
      for (var y = 0; y < nh; y++) {
        for (var x = 0; x < nw; x++) {
          var r = 0, g = 0, sa = 0;
          for (var oy = 0; oy < 2; oy++) {
            for (var ox = 0; ox < 2; ox++) {
              var sx = Math.min(sw - 1, x * 2 + ox), sy = Math.min(sh - 1, y * 2 + oy), k = (sy * sw + sx) * 4;
              var aa = src[k + 3] / 255 + 0.004;
              r += src[k] * aa; g += src[k + 1] * aa; sa += aa;
            }
          }
          var j = (y * nw + x) * 4;
          dst[j] = Math.round(r / sa); dst[j + 1] = Math.round(g / sa);
          alpha[y * nw + x] = (sa - 0.016) / 4;
        }
      }
      var lo = 0.5, hi = 6;
      for (var it = 0; it < 14; it++) {
        var mid = (lo + hi) / 2;
        if (coverage(alpha, mid) < target) lo = mid; else hi = mid;
      }
      for (var m = 0; m < nw * nh; m++) dst[m * 4 + 3] = Math.round(Math.min(1, alpha[m] * hi) * 255);
      levels.push({ data: dst, width: nw, height: nh });
      src = dst; sw = nw; sh = nh;
    }
    return dataTexture(data, w, h, { mipmaps: levels, anisotropy: 4 });
  }

  // Bamboo spray: a thin twig along the card carrying fans of long, narrow, pointed leaves.
  function bambooTexture(rng) {
    var W = 256, H = 128, c = raster(W, H);
    function leaf(x, y, ang, len, w, shade, tint) {
      var steps = 8, px = x, py = y, a = ang, curve = (rng() - 0.5) * 0.6;
      for (var s = 0; s < steps; s++) {
        var t0 = s / steps, t1 = (s + 1) / steps;
        var nx = px + Math.cos(a) * len / steps, ny = py + Math.sin(a) * len / steps;
        var w0 = w * Math.pow(Math.sin(Math.PI * Math.min(1, t0 * 1.15 + 0.05)), 0.6);
        var w1 = w * Math.pow(Math.sin(Math.PI * Math.min(1, t1 * 1.15 + 0.05)), 0.6);
        stroke(c, px, py, nx, ny, Math.max(0.3, w0 * 0.5), Math.max(0.25, w1 * 0.5),
          shade + 0.3 * t0, tint);
        px = nx; py = ny; a += curve / steps;
      }
      stroke(c, x, y, x + Math.cos(ang) * len * 0.8, y + Math.sin(ang) * len * 0.8, 0.35, 0.25, shade * 0.6, tint);
    }
    var y0 = H * 0.5;
    stroke(c, 2, y0, W - 16, y0 + 2, 1.1, 0.45, 0.28, 0.2);
    var nodes = 13;
    for (var i = 0; i < nodes; i++) {
      var x = 6 + (i + rng() * 0.6) * (W - 36) / nodes;
      var y = y0 + 2 * x / W;
      var n = 3 + Math.floor(rng() * 3);
      for (var k = 0; k < n; k++) {
        var side = k % 2 ? 1 : -1;
        var ang = side * (0.25 + rng() * 0.95);
        var len = (36 + rng() * 24) * (1 - 0.3 * i / nodes);
        leaf(x, y, ang, len, 9.5 + rng() * 3.5, 0.42 + rng() * 0.22, 0.2 + rng() * 0.65);
      }
    }
    for (var e = 0; e < 4; e++) leaf(W - 30, y0 + 2, (e - 1.5) * 0.3, 28 + rng() * 8, 9, 0.55, 0.4);
    return coverageTexture(c);
  }

  // Cherry blossom: five rounded petals with a notched tip, pink at the heart, stamens.
  function blossomTexture(rng) {
    var S = 64, c = raster(S, S);
    var seg = TAU / 5;
    for (var y = 0; y < S; y++) {
      for (var x = 0; x < S; x++) {
        var u = ((x + 0.5) / S - 0.5) * 2, v = ((y + 0.5) / S - 0.5) * 2;
        var r = Math.hypot(u, v), th = Math.atan2(v, u) + 0.3;
        var phi = (((th + seg * 0.5) % seg) + seg) % seg - seg * 0.5;
        var q = phi / (seg * 0.5);
        var rp = 0.95 * Math.sqrt(Math.max(0, 1 - q * q * 0.6)) - 0.14 * Math.exp(-q * q * 45);
        var cov = Math.max(0, Math.min(1, (rp - r) * S * 0.5 + 0.5));
        var i = y * S + x;
        var vein = 0.06 * Math.exp(-Math.pow(q * 6.0, 2)) * Math.min(1, r * 3);
        c.a[i] = cov;
        c.s[i] = 0.62 + 0.38 * Math.min(1, Math.max(0, (r - 0.1) / 0.7)) - vein;
        c.t[i] = Math.min(1, Math.max(0, (r - 0.12) / 0.6));
      }
    }
    // stamens: short filaments with darker anthers around the heart
    for (var k = 0; k < 16; k++) {
      var a = k / 16 * TAU + rng() * 0.2, l = 7 + rng() * 4;
      var x1 = S / 2 + Math.cos(a) * l, y1 = S / 2 + Math.sin(a) * l;
      stroke(c, S / 2, S / 2, x1, y1, 0.35, 0.3, 0.5, 0.0);
      stroke(c, x1, y1, x1, y1, 0.9, 0.9, 0.25, 0.0);
    }
    return coverageTexture(c);
  }

  // ------------------------------------------------------------------ geometry helpers
  function geometry(pos, nor, uv, idx, col) {
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(nor, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    if (col) g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
    g.setIndex(idx);
    return g;
  }

  // IcosahedronGeometry is not indexed: weld the vertices so that the normals are smooth.
  function mergeVertices(g) {
    var p = g.attributes.position, map = {}, pos = [], uv = [], idx = [];
    for (var i = 0; i < p.count; i++) {
      var key = Math.round(p.getX(i) * 1e4) + ',' + Math.round(p.getY(i) * 1e4) + ',' + Math.round(p.getZ(i) * 1e4);
      if (map[key] === undefined) {
        map[key] = pos.length / 3;
        pos.push(p.getX(i), p.getY(i), p.getZ(i));
        uv.push(p.getX(i), p.getZ(i));
      }
      idx.push(map[key]);
    }
    var out = new THREE.BufferGeometry();
    out.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    out.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    out.setIndex(idx);
    g.dispose();
    return out;
  }

  // Weathered stone: a displaced icosphere cut by a few planes (split faces, flat top), set in
  // the ground (flattened underneath). shape: [width, height, depth].
  function stoneGeometry(rng, detail, shape, cuts) {
    var g = new THREE.IcosahedronGeometry(1, detail);
    var p = g.attributes.position;
    var planes = [];
    for (var k = 0; k < cuts; k++) {
      var th = rng() * TAU, el = (rng() - 0.2) * 1.4;
      planes.push([Math.cos(th) * Math.cos(el), Math.sin(el), Math.sin(th) * Math.cos(el), 0.62 + rng() * 0.25]);
    }
    var s0 = rng() * 10, s1 = rng() * 10;
    var v = new THREE.Vector3();
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var n = 0.14 * Math.sin(v.x * 2.6 + s0) * Math.sin(v.y * 2.2 + 0.4) * Math.sin(v.z * 2.9 + s1)
        + 0.06 * Math.sin(v.x * 6.1 + v.z * 4.3 + s1) + 0.04 * Math.sin(v.y * 8.0 + v.x * 5.1)
        + 0.02 * Math.sin(v.x * 15.0 + v.y * 12.0) * Math.sin(v.z * 14.0 - v.y * 10.0);
      v.multiplyScalar(1 + n);
      planes.forEach(function (pl) {
        var d = v.x * pl[0] + v.y * pl[1] + v.z * pl[2];
        if (d > pl[3]) v.addScaledVector(new THREE.Vector3(pl[0], pl[1], pl[2]), (pl[3] - d) * 0.93);
      });
      if (v.y < -0.25) v.y = -0.25 + (v.y + 0.25) * 0.2;
      p.setXYZ(i, v.x * shape[0], (v.y + 0.25) * shape[1], v.z * shape[2]);
    }
    g = mergeVertices(g);
    g.computeVertexNormals();
    return g;
  }

  // A rounded mound (moss island, azalea): a dome with gentle lumps, its outline irregular.
  function moundGeometry(rng, lumps, flat) {
    var g = new THREE.SphereGeometry(1, 28, 12, 0, TAU, 0, Math.PI / 2);
    var p = g.attributes.position, v = new THREE.Vector3();
    var a = rng() * 10, b = rng() * 10;
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var th = Math.atan2(v.z, v.x);
      var outline = 1 + 0.1 * Math.sin(3 * th + a) + 0.06 * Math.sin(5 * th + b);
      var n = 1 + lumps * (Math.sin(v.x * 5.0 + a) * Math.sin(v.z * 4.0 + b) + 0.5 * Math.sin(v.x * 9.0 + v.z * 7.0));
      var y = flat ? Math.pow(Math.max(0, v.y), 0.7) : v.y;
      p.setXYZ(i, v.x * outline * n, y * n - 0.04, v.z * outline * n);
    }
    g.computeVertexNormals();
    return g;
  }

  // A tube along a polyline of [x, y, z, radius]; uv: around (m), along (m).
  function tubeGeometry(points, radial, rough) {
    var pos = [], nor = [], uv = [], idx = [];
    var along = 0;
    var up = new THREE.Vector3(0, 1, 0), t = new THREE.Vector3(), a = new THREE.Vector3(), b = new THREE.Vector3();
    for (var j = 0; j < points.length; j++) {
      var p = points[j], q = points[Math.min(points.length - 1, j + 1)], o = points[Math.max(0, j - 1)];
      t.set(q[0] - o[0], q[1] - o[1], q[2] - o[2]).normalize();
      a.crossVectors(t, up);
      if (a.lengthSq() < 1e-6) a.set(1, 0, 0);
      a.normalize();
      b.crossVectors(a, t).normalize();
      if (j > 0) along += Math.hypot(p[0] - o[0], p[1] - o[1], p[2] - o[2]);
      for (var i = 0; i <= radial; i++) {
        var th = i / radial * TAU;
        var r = p[3] * (1 + (rough || 0) * (Math.sin(th * 3 + j * 1.7) * 0.5 + Math.sin(th * 7 + j * 0.9) * 0.3));
        var nx = a.x * Math.cos(th) + b.x * Math.sin(th), ny = a.y * Math.cos(th) + b.y * Math.sin(th), nz = a.z * Math.cos(th) + b.z * Math.sin(th);
        pos.push(p[0] + nx * r, p[1] + ny * r, p[2] + nz * r);
        nor.push(nx, ny, nz);
        uv.push(i / radial * TAU * p[3], along);
      }
    }
    for (var k = 0; k < points.length - 1; k++) {
      for (var m = 0; m < radial; m++) {
        var s = k * (radial + 1) + m, e = s + radial + 1;
        idx.push(s, s + 1, e, s + 1, e + 1, e);
      }
    }
    return geometry(pos, nor, uv, idx);
  }

  function mergeAll(list) {
    var pos = [], nor = [], uv = [], idx = [], base = 0;
    list.forEach(function (g) {
      var p = g.attributes.position, n = g.attributes.normal, u = g.attributes.uv;
      for (var i = 0; i < p.count; i++) {
        pos.push(p.getX(i), p.getY(i), p.getZ(i));
        nor.push(n.getX(i), n.getY(i), n.getZ(i));
        uv.push(u.getX(i), u.getY(i));
      }
      var ix = g.index.array;
      for (var j = 0; j < ix.length; j++) idx.push(ix[j] + base);
      base += p.count;
      g.dispose();
    });
    return geometry(pos, nor, uv, idx);
  }

  // A folded card (leaf spray) from root along (dirx, dirz): `segs` rows, three vertices across
  // (the edges droop by `fold` of the width: a gable). Vertex colour: occlusion toward the root.
  function addCard(B, root, dirx, dirz, len, width, pitch, tipDrop, roll, ao, segs, fold) {
    var base = B.pos.length / 3;
    var sx = -dirz, sz = dirx;
    var cr = Math.cos(roll), sr = Math.sin(roll);
    var dnx = -sx * sr, dny = cr, dnz = -sz * sr;
    for (var s = 0; s <= segs; s++) {
      var u = s / segs;
      var hd = u * len * Math.cos(pitch), vd = u * len * Math.sin(pitch) - tipDrop * len * u * u;
      var px = root[0] + dirx * hd, py = root[1] + vd, pz = root[2] + dirz * hd;
      var ox = sx * cr * width * 0.5, oy = sr * width * 0.5, oz = sz * cr * width * 0.5;
      var fd = fold * width * Math.min(1, 0.4 + u);
      var nx = dirx * (0.3 + 0.6 * u), ny = 0.8, nz = dirz * (0.3 + 0.6 * u);
      var nl = Math.hypot(nx, ny, nz);
      nx /= nl; ny /= nl; nz /= nl;
      B.pos.push(px - ox - dnx * fd, py - oy - dny * fd, pz - oz - dnz * fd, px, py, pz, px + ox - dnx * fd, py + oy - dny * fd, pz + oz - dnz * fd);
      B.nor.push(nx - sx * 0.35, ny, nz - sz * 0.35, nx, ny, nz, nx + sx * 0.35, ny, nz + sz * 0.35);
      B.uv.push(u, 0, u, 0.5, u, 1);
      var a = (0.5 + 0.5 * Math.min(1, u / 0.7)) * ao;
      B.col.push(a * 0.9, a * 0.9, a * 0.9, a, a, a, a * 0.9, a * 0.9, a * 0.9);
    }
    for (var k = 0; k < segs; k++) {
      var p = base + k * 3;
      B.idx.push(p, p + 3, p + 1, p + 1, p + 3, p + 4, p + 1, p + 4, p + 2, p + 2, p + 4, p + 5);
    }
  }

  // Bamboo culm: thin, slowly tapering, its top arching over (local +x); uv: (around, height m).
  function bend(y) {
    var t = y / BAMBOO_H;
    return 1.0 * t * t * t;
  }
  function culmGeometry(radial, rings) {
    var pos = [], nor = [], uv = [], idx = [];
    for (var j = 0; j <= rings; j++) {
      var y = Math.pow(j / rings, 0.85) * BAMBOO_H;
      var r = 0.05 * (1 - 0.55 * y / BAMBOO_H) + 0.005;
      var bx = bend(y);
      for (var i = 0; i <= radial; i++) {
        var th = i / radial * TAU, cx = Math.cos(th), sz = Math.sin(th);
        pos.push(bx + cx * r, y, sz * r);
        nor.push(cx, 0, sz);
        uv.push(i / radial, y);
      }
    }
    for (var a = 0; a < rings; a++) {
      for (var b = 0; b < radial; b++) {
        var p = a * (radial + 1) + b, q = p + radial + 1;
        idx.push(p, q, p + 1, p + 1, q, q + 1);
      }
    }
    return geometry(pos, nor, uv, idx);
  }
  // Its foliage: drooping leaf sprays from the upper nodes, more and shorter toward the top.
  function bambooLeafGeometry(rng, lod) {
    var B = { pos: [], nor: [], uv: [], idx: [], col: [] };
    var n = lod === 0 ? 30 : 16;
    for (var k = 0; k < n; k++) {
      var f = k / (n - 1);
      var y = BAMBOO_H * (0.42 + 0.56 * Math.pow(f, 0.75));
      var th = k * 2.39996 + rng() * 0.7;
      var dirx = Math.cos(th) + 0.35, dirz = Math.sin(th);   // a little more toward the arching side
      var dl = Math.hypot(dirx, dirz); dirx /= dl; dirz /= dl;
      var len = (lod === 0 ? 2.0 : 2.5) * (1.25 - 0.55 * f) * (0.8 + rng() * 0.4);
      var pitch = 0.15 - rng() * 0.45;
      var roll = (k % 2 ? 1 : -1) * (0.25 + rng() * 0.3);
      addCard(B, [bend(y) + dirx * 0.03, y, dirz * 0.03], dirx, dirz, len, len * (lod === 0 ? 0.6 : 0.65), pitch, 0.55, roll,
        0.6 + 0.4 * f, lod === 0 ? 2 : 1, 0.2);
    }
    return geometry(B.pos, B.nor, B.uv, B.idx, B.col);
  }

  // A long clipped hedge along x: a rounded profile, gently undulating.
  function hedgeGeometry(x0, x1, height, depth) {
    var pos = [], nor = [], uv = [], idx = [];
    var NX = 140, NP = 18;
    var prof = [];
    for (var k = 0; k <= NP; k++) {
      var a = Math.PI * k / NP;   // from the front base, over the top, to the back base
      var cy = Math.sin(a), cz = -Math.cos(a);
      var sq = Math.pow(Math.abs(cy), 0.35), sz = Math.sign(cz) * Math.pow(Math.abs(cz), 0.45);
      prof.push([sz * depth * 0.5, sq * height, cz, cy]);
    }
    for (var i = 0; i <= NX; i++) {
      var x = x0 + (x1 - x0) * i / NX;
      var und = 1 + 0.06 * Math.sin(x * 0.9) + 0.04 * Math.sin(x * 2.3 + 1.0) + 0.02 * Math.sin(x * 5.1);
      for (var j = 0; j <= NP; j++) {
        var P = prof[j];
        pos.push(x, P[1] * und, P[0] * (0.95 + 0.05 * und));
        nor.push(0, P[3], P[2]);
        uv.push(x, j / NP * (height * 2 + depth));
      }
    }
    for (var a2 = 0; a2 < NX; a2++) {
      for (var b2 = 0; b2 < NP; b2++) {
        var p = a2 * (NP + 1) + b2, q = p + NP + 1;
        idx.push(p, p + 1, q, p + 1, q + 1, q);
      }
    }
    var g = geometry(pos, nor, uv, idx);
    g.computeVertexNormals();
    return g;
  }

  // ------------------------------------------------------------------ shared GLSL
  // Fog, ground mist and sun-shadow lookups, written for both the patched three.js materials and
  // the scene's ShaderMaterials (which already have uTime, EV_PERIOD, EV_TAU).
  var FO_GLSL = [
    'uniform vec3 uSunDir; uniform vec3 uSunFog; uniform vec3 uFogAmb;',
    'uniform vec4 uFog;',        // base density, ground density, height falloff, mist level
    'uniform vec4 uMist;',       // band height, band width, band density, noise scale
    'uniform sampler2D uNoiseTex;',
    'uniform sampler2DShadow uShadowMap; uniform mat4 uShadowMatrix; uniform float uShadowReady;',
    // (bases kept above 0: pow() of a negative number is NaN on mobile GPUs)
    'float fo_phase(float c) {',
    '  c = clamp(c, -1.0, 1.0);',
    '  float a = 0.3276 / pow(max(1.6724 - 1.64 * c, 0.03), 1.5);',
    '  float b = 0.8775 / pow(max(1.1225 - 0.7 * c, 0.4), 1.5);',
    '  return (0.72 * a + 0.28 * b) * 0.0796;',
    '}',
    'float fo_shadow(vec3 wp) {',
    '  vec4 sc = uShadowMatrix * vec4(wp, 1.0);',
    '  sc.xyz /= sc.w;',
    '  if (uShadowReady < 0.5 || sc.x < 0.0 || sc.x > 1.0 || sc.y < 0.0 || sc.y > 1.0 || sc.z > 1.0) return 1.0;',
    '  return texture(uShadowMap, vec3(sc.xy, sc.z - 0.002));',
    '}',
    'vec2 fo_weights(float t) { float s = sin(3.14159265 * t / EV_PERIOD); return vec2(s * s, 1.0 - s * s); }',
    'float fo_loopNoise(vec2 p, vec2 drift) {',
    '  float tau = uTime / EV_PERIOD;',
    '  vec2 w = fo_weights(uTime);',
    '  float a = texture2D(uNoiseTex, p + drift * EV_PERIOD * (fract(tau) - 0.5)).r;',
    '  float b = texture2D(uNoiseTex, p + drift * EV_PERIOD * (fract(tau + 0.5) - 0.5) + vec2(0.37, 0.71)).r;',
    '  float v = w.x * (a - 0.5) + w.y * (b - 0.5);',
    '  return clamp(0.5 + v / sqrt(w.x * w.x + w.y * w.y), 0.0, 1.0);',
    '}',
    'float fo_heightOD(float y0, float dy, float L) {',
    '  float k = uFog.z;',
    // (a ray far below the ground would overflow exp(): it is hidden anyway)
    '  float a = max(k * dy * L, -40.0);',
    '  return exp(-k * y0) * (abs(a) > 1e-3 ? (1.0 - exp(-a)) / (k * dy) : L);',
    '}',
    'float fo_bandOD(float y0, float dy, float L) {',
    '  float yc = uMist.x, w = uMist.y;',
    '  if (abs(dy) > 1e-3) return w * (atan((y0 + dy * L - yc) / w) - atan((y0 - yc) / w)) / dy;',
    '  float q = (y0 - yc) / w;',
    '  return L / (1.0 + q * q);',
    '}',
    'vec3 fo_fog(vec3 col, vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = max(length(d), 1e-3);',
    '  vec3 dir = d / L;',
    '  float ph = fo_phase(dot(dir, uSunDir));',
    '  float od = uFog.x * L + uFog.y * fo_heightOD(cameraPosition.y, dir.y, L);',
    '  float T = exp(-od);',
    '  vec3 haze = uFogAmb + uSunFog * ph * mix(0.3, 1.0, smoothstep(4.0, 50.0, L));',
    '  col = col * T + haze * (1.0 - T);',
    '  float odm = fo_bandOD(cameraPosition.y, dir.y, L) * uMist.z * uFog.w;',
    '  if (odm > 0.004) {',
    '    vec3 mist = uFogAmb * 1.25 + uSunFog * ph * 0.9;',
    '#ifdef FO_LOW',
    '    odm *= 0.6;',
    '#else',
    // drifting and lit by the sun through the hedge and the grove for the rays that look down
    '    float down = smoothstep(-0.01, -0.1, dir.y);',
    '    if (down > 0.0) {',
    '      vec3 pc = cameraPosition + dir * clamp((uMist.x - cameraPosition.y) / dir.y, 0.0, L);',
    '      float n = fo_loopNoise(pc.xz * uMist.w, vec2(0.006, 0.002));',
    '      odm *= mix(0.6, 0.15 + 2.2 * n * n, down);',
    '      mist = mix(mist, uFogAmb * 1.25 + uSunFog * ph * (0.15 + 1.1 * fo_shadow(pc + vec3(0.0, 0.25, 0.0))), down);',
    '    } else {',
    '      odm *= 0.6;',
    '    }',
    '#endif',
    '    float Tm = exp(-odm);',
    '    col = col * Tm + mist * (1.0 - Tm);',
    '  }',
    '  return col;',
    '}',
    'vec3 fo_skyFog(vec3 col, vec3 dir) {',
    '  float ph = fo_phase(dot(dir, uSunDir));',
    '  float od = uFog.x * 160.0 + uFog.y * fo_heightOD(cameraPosition.y, dir.y, 2000.0);',
    '  float T = exp(-od);',
    '  col = col * T + (uFogAmb + uSunFog * ph) * (1.0 - T);',
    '  float Tm = exp(-fo_bandOD(cameraPosition.y, dir.y, 2000.0) * uMist.z * uFog.w * 0.6);',
    '  return col * Tm + (uFogAmb * 1.25 + uSunFog * ph * 0.9) * (1.0 - Tm);',
    '}',
    'float fo_trans(vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = max(length(d), 1e-3);',
    '  vec3 dir = d / L;',
    '  float od = uFog.x * L + uFog.y * fo_heightOD(cameraPosition.y, dir.y, L) + fo_bandOD(cameraPosition.y, dir.y, L) * uMist.z * uFog.w;',
    '  return exp(-od);',
    '}',
  ].join('\n');

  var BUMP_GLSL = [
    'vec3 fo_bump(vec3 n, vec3 surf, float h, float scale) {',
    '  vec3 dpdx = dFdx(surf), dpdy = dFdy(surf);',
    '  float dhdx = dFdx(h), dhdy = dFdy(h);',
    '  vec3 r1 = cross(dpdy, n), r2 = cross(n, dpdx);',
    '  float det = dot(dpdx, r1);',
    '  vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2);',
    '  vec3 b = abs(det) * n - scale * grad;',
    '  return abs(det) > 1e-14 && dot(b, b) > 1e-28 ? normalize(b) : n;',
    '}',
  ].join('\n');

  var WORLD_VERTEX = [
    'vec4 foW = vec4(transformed, 1.0);',
    '#ifdef USE_INSTANCING',
    'foW = instanceMatrix * foW;',
    '#endif',
    'vFoWorld = (modelMatrix * foW).xyz;',
  ].join('\n');

  // Light through thin leaves and petals, seen against the sun (after the direct lights).
  function translucency(amount, tint) {
    return [
      '#if NUM_DIR_LIGHTS > 0',
      '{',
      '  float foBack = saturate(dot(-geometryViewDir, directLight.direction));',
      '  float foThin = pow(foBack, 3.0) * 0.85 + 0.15 * saturate(dot(-geometryNormal, directLight.direction));',
      '  reflectedLight.directDiffuse += directLight.color * material.diffuseColor * vec3(' + tint.map(function (x) { return x.toFixed(3); }).join(', ') + ') * (' + amount.toFixed(3) + ' * foThin);',
      '}',
      '#endif',
    ].join('\n');
  }

  // Wind on the bamboo, the cherry branch and its blossoms: a world offset (gusts loop over the
  // period), converted to the instance's local space so that every chunk sees the moved vertex.
  var SWAY_GLSL = [
    // a world vector in the space of an instance whose matrix is rotation x scale (columns
    // orthogonal): its inverse is S^-1 R^T, no inverse() in the shader
    'vec3 gz_toLocal(mat4 m, vec3 w) {',
    '  vec3 a = m[0].xyz, b = m[1].xyz, c = m[2].xyz;',
    '  return vec3(dot(a, w) / max(dot(a, a), 1e-8), dot(b, w) / max(dot(b, b), 1e-8), dot(c, w) / max(dot(c, c), 1e-8));',
    '}',
    'vec3 gz_wind(vec3 w, float weight) {',
    '  float T = EV_TAU * uTime / EV_PERIOD;',
    '  float ph = w.x * 0.11 + w.z * 0.07;',
    '  float gust = 0.55 + 0.45 * sin(T + ph * 0.5);',
    '  float s = sin(7.0 * T + ph * 3.0) * 0.6 + sin(11.0 * T + ph * 5.0 + 1.3) * 0.25 + sin(2.0 * T + ph) * 0.8;',
    '  return vec3(1.0, 0.0, 0.35) * s * gust * weight;',
    '}',
  ].join('\n');

  // ------------------------------------------------------------------ scene
  E.register({
    id: 'jardin-zen',
    decors: ['petales', 'rayons-soleil', 'brume', 'pluie'],
    defaults: { petales: 40, 'rayons-soleil': 30 },
    post: true,

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera, renderer = ctx.renderer;
      var quality = ctx.quality;
      var high = quality === 'high';
      var rng = ctx.rng('v2');
      camera.fov = 50;
      camera.near = 0.1;
      camera.far = 1500;

      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFShadowMap;
      // the sun and everything that casts a shadow stand still: the map is drawn once
      renderer.shadowMap.autoUpdate = false;

      var az = SUN_AZ * Math.PI / 180, el = SUN_EL * Math.PI / 180;
      var sunDir = new THREE.Vector3(Math.sin(az) * Math.cos(el), Math.sin(el), -Math.cos(az) * Math.cos(el)).normalize();
      var noiseTex = noiseTexture(ctx.rng('noise'));
      var bambooTex = bambooTexture(ctx.rng('bamboo-tex'));
      var blossomTex = blossomTexture(ctx.rng('blossom-tex'));
      var textures = [noiseTex, bambooTex, blossomTex];

      var shared = {
        uTime: ctx.uniforms.uTime,
        uSunDir: { value: sunDir },
        uSunFog: { value: lin('#ffd3a0').multiplyScalar(1.0) },
        uFogAmb: { value: lin('#aaa6aa').multiplyScalar(0.13) },
        uFog: { value: new THREE.Vector4(0.003, 0.015, 0.3, 0.0) },
        uMist: { value: new THREE.Vector4(0.3, 0.7, 0.12, 0.05) },
        uNoiseTex: { value: noiseTex },
        uShadowMap: { value: null },
        uShadowMatrix: { value: new THREE.Matrix4() },
        uShadowReady: { value: 0 },
        uWet: { value: 0 },
        uRain: { value: 0 },
      };
      var fogBase = { density: shared.uFog.value.x, ground: shared.uFog.value.y };
      var shadowPlaceholder = new THREE.DepthTexture(1, 1);
      shadowPlaceholder.compareFunction = THREE.LessEqualCompare;
      shadowPlaceholder.needsUpdate = true;
      shared.uShadowMap.value = shadowPlaceholder;
      textures.push(shadowPlaceholder);

      // patched three.js materials: shared fog / mist, world position, hooks
      var patched = [];
      var envTexture = null;
      function pbr(Kind, params, hooks) {
        var m = new Kind(params);
        hooks = hooks || {};
        if (hooks.env) {
          m.userData.env = true;
          m.envMap = envTexture;
          m.envMapIntensity = 0.5 * hooks.env;
        }
        m.onBeforeCompile = function (shader) {
          Object.keys(shared).forEach(function (k) { shader.uniforms[k] = shared[k]; });
          Object.assign(shader.uniforms, hooks.uniforms || {});
          var head = 'varying vec3 vFoWorld;\nvarying vec2 vFoUv;\nuniform float uTime;\nuniform float uWet;\nuniform float uRain;\n#define EV_PERIOD 30.0\n#define EV_TAU 6.28318530718\n';
          var vs = shader.vertexShader
            .replace('#include <common>', '#include <common>\n' + head + SWAY_GLSL + '\n' + (hooks.vertexPars || ''))
            .replace('#include <begin_vertex>', '#include <begin_vertex>\nvFoUv = uv;\n' + (hooks.vertex || ''))
            .replace('#include <project_vertex>', '#include <project_vertex>\n' + WORLD_VERTEX);
          var fs = shader.fragmentShader
            .replace('#include <common>', '#include <common>\n' + head + (quality === 'low' ? '#define FO_LOW 1\n' : '') +
              FO_GLSL + '\n' + BUMP_GLSL + '\n' + (hooks.fragmentPars || ''))
            .replace('#include <map_fragment>', hooks.map || '#include <map_fragment>')
            .replace('#include <color_fragment>', '#include <color_fragment>\n' + (hooks.color || ''))
            .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\n' + (hooks.roughness || ''))
            .replace('#include <normal_fragment_maps>', '#include <normal_fragment_maps>\n' + (hooks.normal || ''))
            .replace('#include <lights_fragment_begin>', '#include <lights_fragment_begin>\n' + (hooks.light || ''))
            .replace('#include <lights_fragment_end>', '#include <lights_fragment_end>\n' +
              'reflectedLight.directSpecular *= mix(' + (hooks.drySpecular !== undefined ? hooks.drySpecular : 0.3).toFixed(3) + ', 0.6, uWet);\n' +
              (hooks.lightEnd || ''))
            .replace('#include <fog_fragment>', 'gl_FragColor.rgb = fo_fog(gl_FragColor.rgb, vFoWorld);');
          shader.vertexShader = vs;
          shader.fragmentShader = fs;
        };
        m.customProgramCacheKey = function () { return 'gz-' + hooks.key + '-' + quality; };
        patched.push(m);
        return m;
      }
      function glf(x) { return Number(x).toFixed(3); }
      function cardMap(tintA, tintB, shadeLo, shadeHi) {
        return [
          'vec4 foTx = texture2D(map, vMapUv);',
          'diffuseColor.rgb *= mix(vec3(' + tintA.map(glf).join(', ') + '), vec3(' + tintB.map(glf).join(', ') + '), foTx.g) * mix(' + glf(shadeLo) + ', ' + glf(shadeHi) + ', foTx.r);',
          'diffuseColor.a *= foTx.a;',
        ].join('\n');
      }
      function cardMaterial(map, color, roughness, key, extra) {
        return pbr(THREE.MeshStandardMaterial, Object.assign({
          color: color, roughness: roughness, metalness: 0, map: map, alphaTest: 0.5,
          alphaToCoverage: high, side: THREE.DoubleSide, vertexColors: true,
        }, extra && extra.params), Object.assign({ key: key }, extra && extra.hooks));
      }

      // ---------------------------------------------------------------- sky + environment
      var SKY_FRAGMENT = [
        'uniform vec3 uZenith; uniform vec3 uHorizon; uniform vec3 uSunDisc; uniform vec3 uCloudLit; uniform float uEnv;',
        'varying vec3 vDir;',
        'void main() {',
        '  vec3 d = normalize(vDir);',
        '  float c = dot(d, uSunDir);',
        '  float y = max(d.y, 0.0);',
        '  vec3 col = mix(uHorizon, uZenith, pow(smoothstep(-0.02, 0.85, y), 0.55));',
        // a warm band low on the horizon toward the sun, cooler on the other side
        '  float az = 0.5 + 0.5 * dot(d.xz / max(length(d.xz), 1e-4), normalize(uSunDir.xz));',
        '  col *= mix(vec3(0.85, 0.9, 1.05), vec3(1.12, 1.0, 0.86), az * (1.0 - smoothstep(0.0, 0.5, y)));',
        '  col += uSunFog * fo_phase(c) * 0.35;',
        // high veils of cloud lit from below by the low sun
        '  vec2 p = d.xz / max(d.y + 0.18, 0.06) * 0.07;',
        '  float cl = fo_loopNoise(p + vec2(0.31, 0.12), vec2(0.0016, 0.0003));',
        '  float veil = smoothstep(0.5, 0.82, cl) * smoothstep(0.03, 0.2, d.y) * (1.0 - smoothstep(0.45, 0.8, d.y));',
        '  col = mix(col, uCloudLit * (0.35 + 2.4 * fo_phase(c)), veil * 0.55);',
        '  if (uEnv < 0.5) {',
        '    float r = acos(clamp(c, -1.0, 1.0));',
        '    col += uSunDisc * (1.0 - smoothstep(0.0085, 0.0098, r)) * (1.0 - 0.6 * uRain);',
        '  }',
        '  col *= 1.0 - 0.35 * uRain;',
        '  col = fo_skyFog(col, d);',
        '  gl_FragColor = vec4(col, 1.0);',
        '}',
      ].join('\n');
      function skyMaterial(env) {
        return ctx.material({
          uniforms: Object.assign({}, shared, {
            uZenith: { value: lin('#5d7aa6').multiplyScalar(0.9) },
            uHorizon: { value: lin('#f2d2ad').multiplyScalar(1.2) },
            uSunDisc: { value: lin('#ffe2b8').multiplyScalar(40) },
            uCloudLit: { value: lin('#ffd9b0').multiplyScalar(1.6) },
            uEnv: { value: env ? 1 : 0 },
          }),
          vertexShader: 'varying vec3 vDir;\nvoid main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
          fragmentShader: 'uniform float uRain;\n' + FO_GLSL + '\n' + SKY_FRAGMENT,
          side: THREE.BackSide,
          depthWrite: false,
        });
      }
      var sky = new THREE.Mesh(new THREE.SphereGeometry(1000, 48, 24), skyMaterial(false));
      sky.renderOrder = 10;   // after the opaque scene: only the gaps are shaded
      sky.frustumCulled = false;
      scene.add(sky);

      var pmrem = new THREE.PMREMGenerator(renderer);
      var envScene = new THREE.Scene();
      var envSky = new THREE.Mesh(new THREE.SphereGeometry(50, 32, 16), skyMaterial(true));
      envScene.add(envSky);
      var envRT = pmrem.fromScene(envScene, 0.03, 0.1, 100, { size: 64 });
      envTexture = envRT.texture;
      patched.forEach(function (m) { if (m.userData.env) { m.envMap = envTexture; m.needsUpdate = true; } });
      envSky.geometry.dispose();
      envSky.material.dispose();
      pmrem.dispose();

      // ---------------------------------------------------------------- lights
      var sunColor = lin('#ffcf9e');
      var SUN_I = 9.0;
      var sun = new THREE.DirectionalLight(sunColor, SUN_I);
      var target = new THREE.Vector3(0, 0, -18);
      sun.target.position.copy(target);
      sun.position.copy(target).addScaledVector(sunDir, 120);
      sun.castShadow = true;
      var shadowSize = high ? 1024 : 512;
      sun.shadow.mapSize.set(shadowSize, shadowSize);
      sun.shadow.bias = -0.0005;
      sun.shadow.normalBias = 0.03;
      sun.shadow.radius = 2.0;
      scene.add(sun);
      scene.add(sun.target);
      // fit the shadow box (light space) to the garden and the near grove
      (function fitShadow() {
        sun.updateMatrixWorld();
        sun.target.updateMatrixWorld();
        var sc = sun.shadow.camera;
        sc.position.copy(sun.position);
        sc.lookAt(target);
        sc.updateMatrixWorld();
        var inv = sc.matrixWorldInverse;
        var lo = new THREE.Vector3(1e9, 1e9, 1e9), hi = new THREE.Vector3(-1e9, -1e9, -1e9), v = new THREE.Vector3();
        [-13, 13].forEach(function (x) {
          [0, 13].forEach(function (y) {
            [-44, -2].forEach(function (z) {
              v.set(x, y, z).applyMatrix4(inv);
              lo.min(v); hi.max(v);
            });
          });
        });
        sc.left = lo.x; sc.right = hi.x; sc.bottom = lo.y; sc.top = hi.y;
        sc.near = Math.max(1, -hi.z - 10); sc.far = -lo.z + 10;
        sc.updateProjectionMatrix();
      })();
      var hemi = new THREE.HemisphereLight(lin('#9fb2d4'), lin('#a8916f'), 0.95);
      scene.add(hemi);

      // ---------------------------------------------------------------- ground: gravel, moss, soil
      var gp = [], gn = [], gu = [], gi = [];
      var NX = 90, NZ = 110;
      for (var gz = 0; gz <= NZ; gz++) {
        var sz = gz / NZ;
        var zz = POND_FAR + 0.15 - 170 * Math.pow(sz, 1.8);
        for (var gx = 0; gx <= NX; gx++) {
          var su = gx / NX * 2 - 1;
          var xx = 80 * Math.sign(su) * Math.pow(Math.abs(su), 1.7);
          var yy = Math.max(0, HEDGE_Z - 2 - zz) * 0.018 + Math.max(0, Math.abs(xx) - 20) * 0.02;
          gp.push(xx, yy, zz);
          gn.push(0, 1, 0);
          gu.push(xx, zz);
        }
      }
      for (var a2 = 0; a2 < NZ; a2++) {
        for (var b2 = 0; b2 < NX; b2++) {
          var p0 = a2 * (NX + 1) + b2, p1 = p0 + NX + 1;
          gi.push(p0, p0 + 1, p1, p0 + 1, p1 + 1, p1);
        }
      }
      var groundGeo = geometry(gp, gn, gu, gi);
      groundGeo.computeVertexNormals();
      var groupUniform = GROUPS.map(function (g) { return new THREE.Vector4(g.x, g.z, g.rx, g.rz); });
      var ground = new THREE.Mesh(groundGeo, pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 }, {
        key: 'ground',
        drySpecular: 0.45,
        uniforms: { uGroups: { value: groupUniform } },
        fragmentPars: [
          'uniform vec4 uGroups[3];',
          // the rake: across-furrow coordinate u (m), its gradient, the distance to the nearest island
          'float gz_rake(vec2 p, out vec2 grad, out float island) {',
          '  island = 1e3; vec2 g = vec2(0.0, 1.0);',
          '  for (int i = 0; i < 3; i++) {',
          '    vec2 q = (p - uGroups[i].xy) / uGroups[i].zw;',
          '    float L = max(length(q), 1e-4);',
          '    float R = 0.5 * (uGroups[i].z + uGroups[i].w);',
          '    float d = (L - 1.0) * R;',
          '    if (d < island) { island = d; g = q / L / uGroups[i].zw * R; }',
          '  }',
          '  if (island < ' + RING.toFixed(2) + ') { grad = g; return island; }',
          '  grad = vec2(1.0, 0.0);',
          '  return p.x;',
          '}',
          // furrow profile (height in [0, 1]): rounded ridges, narrower grooves
          'float gz_prof(float u) { return pow(max(0.5 + 0.5 * cos(u * EV_TAU / 0.085), 0.0), 0.65); }',
          'float gz_furrowShadow;',
          'vec3 gz_furrowNormal;',
          'float gz_ridge;',
          'float gz_fine;',
        ].join('\n'),
        color: [
          'vec2 gzP = vFoWorld.xz;',
          'vec2 gzGrad; float gzIsl;',
          'float gzU = gz_rake(gzP, gzGrad, gzIsl);',
          'float gzGarden = smoothstep(' + (HEDGE_Z - 0.2).toFixed(2) + ', ' + (HEDGE_Z + 0.6).toFixed(2) + ', gzP.y);',
          // furrows per pixel: fade the relief before it aliases
          'float gzW = fwidth(gzU) / 0.085;',
          'gz_fine = (1.0 - smoothstep(0.22, 0.6, gzW)) * gzGarden;',
          'float gzH = gz_prof(gzU);',
          'float gzE = 0.006;',
          'float gzSlope = (gz_prof(gzU + gzE) - gz_prof(gzU - gzE)) / (2.0 * gzE) * 0.022 * gz_fine;',
          'gz_furrowNormal = normalize(vec3(-gzSlope * gzGrad.x, 1.0, -gzSlope * gzGrad.y));',
          // furrows shadow themselves under the low sun (march a little toward it across them)
          'float gzSc = dot(uSunDir.xz, gzGrad);',
          'float gzTan = uSunDir.y / max(abs(gzSc), 1e-3);',
          'float gzSh = 1.0;',
          'for (int k = 1; k <= 3; k++) {',
          '  float dk = float(k) * 0.012;',
          '  float hk = gz_prof(gzU + sign(gzSc) * dk);',
          '  gzSh = min(gzSh, clamp(1.0 - ((hk - gzH) * 0.022 - dk * gzTan) * 160.0, 0.0, 1.0));',
          '}',
          'gz_furrowShadow = mix(0.82, gzSh, gz_fine);',
          'gz_ridge = mix(0.5, gzH, gz_fine);',
          // gravel: pale granite chips, darker grooves, a few dark specks
          'float gzC = texture2D(uNoiseTex, gzP * 7.0).a;',
          'float gzV = texture2D(uNoiseTex, gzP * 7.0 + 0.5).b;',
          'float gzN = texture2D(uNoiseTex, gzP * 0.13).r;',
          'vec3 gzGravel = mix(vec3(0.36, 0.34, 0.31), vec3(0.50, 0.48, 0.44), gzV);',
          'gzGravel *= mix(0.8, 1.0, smoothstep(0.05, 0.35, gzC));',
          'gzGravel *= 0.9 + 0.2 * gzN;',
          'gzGravel *= mix(0.78, 1.0, gz_ridge);',
          'gzGravel *= mix(1.0, 0.5, smoothstep(0.82, 0.95, texture2D(uNoiseTex, gzP * 3.1 + 0.2).b));',
          // contact shade at the foot of the islands and of the hedge
          'gzGravel *= mix(0.62, 1.0, smoothstep(-0.05, 0.6, gzIsl)) * mix(0.55, 1.0, smoothstep(' + (HEDGE_Z + 0.3).toFixed(2) + ', ' + (HEDGE_Z + 2.4).toFixed(2) + ', gzP.y));',
          // under the hedge and the grove: dark soil, moss, fallen bamboo leaves
          'float gzN2 = texture2D(uNoiseTex, gzP * 0.6).g;',
          'float gzLeaf = smoothstep(0.55, 0.75, texture2D(uNoiseTex, gzP * vec2(2.2, 0.9)).b);',
          'vec3 gzSoil = mix(vec3(0.045, 0.036, 0.026), vec3(0.16, 0.12, 0.07), gzLeaf * (0.5 + 0.5 * gzN2));',
          'gzSoil = mix(gzSoil, vec3(0.04, 0.07, 0.025), smoothstep(0.55, 0.7, gzN2) * 0.8);',
          'diffuseColor.rgb = mix(gzSoil, gzGravel, gzGarden);',
          'diffuseColor.rgb *= 1.0 - 0.38 * uWet;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.95, mix(0.8, 0.68, uWet), gzGarden);',
        normal: 'normal = normalize((viewMatrix * vec4(gz_furrowNormal, 0.0)).xyz);',
        lightEnd: [
          'reflectedLight.directDiffuse *= gz_furrowShadow;',
          // wet gravel: a soft sheen toward the sun, not a mirror
          'reflectedLight.directSpecular *= gz_furrowShadow * mix(1.0, 0.3, uWet);',
        ].join('\n'),
      }));
      ground.receiveShadow = true;
      scene.add(ground);

      // distant wooded hills in the haze, seen through the opening on the right
      (function hills() {
        var hp = [], hn = [], hu = [], hi = [];
        var HX = 160, HZ = 6;
        var hr = ctx.rng('hills');
        var ph = [hr() * 10, hr() * 10, hr() * 10];
        for (var j = 0; j <= HZ; j++) {
          for (var i = 0; i <= HX; i++) {
            var x = -700 + 1400 * i / HX;
            var f = j / HZ;
            var ridge = 38 + 26 * Math.sin(x * 0.006 + ph[0]) + 14 * Math.sin(x * 0.017 + ph[1]) + 6 * Math.sin(x * 0.045 + ph[2]);
            var z = -260 - 220 * f;
            var y = ridge * Math.pow(Math.sin(Math.PI * Math.min(1, 0.15 + f * 0.85)), 0.6) - 4;
            hp.push(x, y, z); hn.push(0, 1, 0); hu.push(x, z);
          }
        }
        for (var a = 0; a < HZ; a++) {
          for (var b = 0; b < HX; b++) {
            var q0 = a * (HX + 1) + b, q1 = q0 + HX + 1;
            hi.push(q0, q0 + 1, q1, q0 + 1, q1 + 1, q1);
          }
        }
        var hg = geometry(hp, hn, hu, hi);
        hg.computeVertexNormals();
        var hm = new THREE.Mesh(hg, pbr(THREE.MeshStandardMaterial, { color: lin('#2c3a25'), roughness: 1, metalness: 0 }, {
          key: 'hills',
          color: 'diffuseColor.rgb *= 0.7 + 0.6 * texture2D(uNoiseTex, vFoWorld.xz * 0.02).r;',
        }));
        hm.frustumCulled = false;
        scene.add(hm);
      })();

      // ---------------------------------------------------------------- moss islands and stones
      var mossMat = pbr(THREE.MeshPhysicalMaterial, {
        color: lin('#55702c'), roughness: 1.0, metalness: 0, sheen: 1.0, sheenColor: lin('#b5c97c'), sheenRoughness: 0.5,
      }, {
        key: 'moss',
        color: [
          'float gzM = texture2D(uNoiseTex, vFoWorld.xz * 1.1).b;',
          'float gzM2 = texture2D(uNoiseTex, vFoWorld.xz * 0.25).r;',
          'diffuseColor.rgb *= (0.5 + 0.6 * gzM) * mix(vec3(1.0), vec3(1.15, 1.05, 0.7), smoothstep(0.55, 0.75, gzM2));',
          'diffuseColor.rgb *= 1.0 - 0.3 * uWet;',
        ].join('\n'),
        normal: 'normal = fo_bump(normal, -vViewPosition, texture2D(uNoiseTex, vFoWorld.xz * 2.6).b, 0.01 * smoothstep(30.0, 6.0, length(vViewPosition)));',
        light: translucency(0.2, [0.9, 1.0, 0.5]),
      });
      var mr = ctx.rng('moss');
      GROUPS.forEach(function (g) {
        var island = new THREE.Mesh(moundGeometry(mr, 0.035, true), mossMat);
        island.position.set(g.x, 0, g.z);
        island.scale.set(g.rx * 1.02, 0.16, g.rz * 1.02);
        island.rotation.y = mr() * 0.4;
        island.receiveShadow = true;
        scene.add(island);
      });

      var stoneHooks = {
        key: 'stone',
        env: 1,
        drySpecular: 0.25,
        color: [
          'vec3 foWn = normalize(cross(dFdx(vFoWorld), dFdy(vFoWorld)));',
          'float foS1 = texture2D(uNoiseTex, vFoWorld.xz * 0.45 + vFoWorld.y * 0.25).g;',
          'float foS2 = texture2D(uNoiseTex, vFoWorld.xy * 0.9 + vFoWorld.z * 0.3).b;',
          'float foS3 = texture2D(uNoiseTex, vFoWorld.zy * 1.7 + vFoWorld.x * 0.2).a;',
          'vec3 foRock = mix(vec3(0.10, 0.095, 0.088), vec3(0.24, 0.22, 0.20), foS1 * 0.6 + foS2 * 0.4);',
          'foRock *= mix(0.75, 1.0, smoothstep(0.05, 0.3, foS3));',
          'float foLich = smoothstep(0.62, 0.8, foS2) * smoothstep(0.35, 0.6, foS1);',
          'foRock = mix(foRock, vec3(0.34, 0.34, 0.29), foLich * 0.7);',
          'float foMossTop = smoothstep(0.55, 0.85, foWn.y + (foS1 - 0.5) * 0.7) * uMossAmount;',
          'diffuseColor.rgb = mix(foRock, vec3(0.05, 0.085, 0.025), foMossTop);',
          'diffuseColor.rgb *= 1.0 - 0.4 * uWet;',
        ].join('\n'),
        fragmentPars: 'uniform float uMossAmount;',
        roughness: 'roughnessFactor = mix(mix(0.78, 1.0, foMossTop), 0.58, uWet * (1.0 - foMossTop));',
        lightEnd: 'reflectedLight.directSpecular *= mix(1.0, 0.45, uWet);',
        normal: 'normal = fo_bump(normal, -vViewPosition, foS2 * 0.5 + foS1 * 0.3 + foS3 * 0.2, 0.035 * smoothstep(30.0, 3.0, length(vViewPosition)));',
      };
      var stoneMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 },
        Object.assign({}, stoneHooks, { uniforms: { uMossAmount: { value: 1.0 } } }));
      var kerbMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 },
        Object.assign({}, stoneHooks, { key: 'kerb', uniforms: { uMossAmount: { value: 0.35 } } }));
      var sr = ctx.rng('stones');
      // [group, dx, dz, width, height, depth, yaw]
      var stoneSpots = [
        [0, 0.15, 0.0, 0.85, 1.25, 0.7, 0.3], [0, -0.75, 0.35, 0.45, 0.5, 0.42, 1.2],
        [1, -0.3, 0.05, 1.25, 0.95, 0.9, 2.1], [1, 0.85, -0.25, 0.6, 0.6, 0.55, 0.4], [1, 0.45, 0.75, 0.35, 0.3, 0.3, 1.0],
        [2, 0.1, 0.0, 0.55, 1.45, 0.5, 2.6], [2, -0.65, 0.2, 0.4, 0.42, 0.38, 0.1],
      ];
      stoneSpots.forEach(function (s) {
        var g = GROUPS[s[0]];
        var m = new THREE.Mesh(stoneGeometry(sr, 3, [s[3], s[4], s[5]], 7), stoneMat);
        m.position.set(g.x + s[1], 0.05, g.z + s[2]);
        m.rotation.set((sr() - 0.5) * 0.12, s[6], (sr() - 0.5) * 0.12);
        m.castShadow = true;
        m.receiveShadow = true;
        scene.add(m);
      });

      // kerb stones along the far edge of the pond
      var kerbGeo = stoneGeometry(ctx.rng('kerb'), 2, [1, 1, 1], 5);
      var kerbList = [];
      var kr = ctx.rng('kerb-place');
      for (var kx = -14; kx < 14;) {
        var ks = 0.26 + kr() * 0.16;
        kerbList.push([kx + ks, POND_FAR + (kr() - 0.5) * 0.14, ks, kr() * TAU]);
        kx += ks * 1.55 + kr() * 0.04;
      }
      var kerb = new THREE.InstancedMesh(kerbGeo, kerbMat, kerbList.length);
      var dummy = new THREE.Matrix4(), qq = new THREE.Quaternion(), e3 = new THREE.Vector3(), sv = new THREE.Vector3();
      var euler = new THREE.Euler();
      kerbList.forEach(function (k, i) {
        qq.setFromEuler(euler.set(0, k[3], 0));
        kerb.setMatrixAt(i, dummy.compose(e3.set(k[0], POND_Y - 0.08, k[1]), qq, sv.set(k[2] * 1.2, k[2] * 0.6, k[2] * 1.1)).clone());
      });
      kerb.castShadow = true;
      kerb.receiveShadow = true;
      kerb.frustumCulled = false;
      scene.add(kerb);

      // ---------------------------------------------------------------- hedge and azaleas
      var leafyHooks = {
        key: 'hedge',
        drySpecular: 0.25,
        color: [
          'float gzL1 = texture2D(uNoiseTex, vFoUv * vec2(1.6, 1.6)).a;',
          'float gzL2 = texture2D(uNoiseTex, vFoWorld.xz * 0.35 + vFoWorld.y * 0.3).g;',
          'float gzLeaves = smoothstep(0.05, 0.45, gzL1);',
          'diffuseColor.rgb *= mix(0.45, 1.05, gzLeaves) * (0.8 + 0.4 * gzL2);',
          'diffuseColor.rgb *= 1.0 - 0.25 * uWet;',
        ].join('\n'),
        normal: 'normal = fo_bump(normal, -vViewPosition, gzLeaves, 0.06 * smoothstep(45.0, 10.0, length(vViewPosition)));',
        light: translucency(0.35, [0.85, 1.0, 0.45]),
      };
      var hedgeMat = pbr(THREE.MeshPhysicalMaterial, {
        color: lin('#2f4a1c'), roughness: 0.85, metalness: 0, sheen: 0.6, sheenColor: lin('#93b45a'), sheenRoughness: 0.6,
      }, leafyHooks);
      var hedge = new THREE.Mesh(hedgeGeometry(-22, 22, 1.2, 1.5), hedgeMat);
      hedge.position.set(0, 0, HEDGE_Z);
      hedge.castShadow = true;
      hedge.receiveShadow = true;
      scene.add(hedge);
      var azaleaMat = pbr(THREE.MeshPhysicalMaterial, {
        color: lin('#334f1e'), roughness: 0.85, metalness: 0, sheen: 0.6, sheenColor: lin('#9cbc62'), sheenRoughness: 0.6,
      }, Object.assign({}, leafyHooks, {
        key: 'azalea',
        color: leafyHooks.color.replace('vFoUv * vec2(1.6, 1.6)', 'vFoWorld.xz * 1.4 + vFoWorld.y * 0.9'),
      }));
      var ar = ctx.rng('azalea');
      [[-5.6, -19.8, 1.15, 0.8], [-3.6, -20.4, 0.75, 0.55], [4.4, -19.6, 1.3, 0.9], [6.8, -20.3, 0.85, 0.65],
        [0.9, -20.6, 0.7, 0.5], [-8.6, -19.2, 1.05, 0.75], [9.6, -19.0, 1.2, 0.85]].forEach(function (a) {
        var m = new THREE.Mesh(moundGeometry(ar, 0.03, false), azaleaMat);
        m.position.set(a[0], 0, a[1]);
        m.scale.set(a[2], a[3], a[2] * 0.85);
        m.rotation.y = ar() * TAU;
        m.castShadow = true;
        m.receiveShadow = true;
        scene.add(m);
      });

      // ---------------------------------------------------------------- bamboo grove
      var culmHooks = {
        key: 'culm',
        drySpecular: 0.5,
        vertex: 'float gzT = max(position.y, 0.0) / ' + BAMBOO_H.toFixed(1) + ';\ntransformed += gz_toLocal(instanceMatrix, gz_wind((instanceMatrix * vec4(transformed, 1.0)).xyz, 0.05 * gzT * gzT));',
        color: [
          'float gzNodeL = 0.34;',
          'float gzY = vFoUv.y / gzNodeL;',
          'float gzNode = fract(gzY);',
          'float gzAA = fwidth(gzY);',
          'float gzRing = (1.0 - smoothstep(0.0, 0.05 + gzAA, gzNode)) * (1.0 - smoothstep(0.3, 0.8, gzAA));',
          'float gzBloom = smoothstep(0.75, 1.0, gzNode) * (1.0 - smoothstep(0.3, 0.8, gzAA));',
          'float gzAge = texture2D(uNoiseTex, vec2(vFoWorld.x * 0.37, vFoWorld.z * 0.41)).r;',
          'vec3 gzCulm = mix(vec3(0.17, 0.25, 0.06), vec3(0.32, 0.30, 0.12), smoothstep(0.45, 0.75, gzAge));',
          'gzCulm = mix(gzCulm, vec3(0.36, 0.38, 0.30), gzBloom * 0.35);',
          'gzCulm *= 1.0 - 0.35 * gzRing;',
          'gzCulm *= 0.85 + 0.25 * texture2D(uNoiseTex, vec2(vFoUv.x * 0.5, vFoUv.y * 0.05)).g;',
          'diffuseColor.rgb = gzCulm;',
        ].join('\n'),
        roughness: 'roughnessFactor = 0.42;',
      };
      var culmMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.5, metalness: 0 }, culmHooks);
      var leafMat = cardMaterial(bambooTex, lin('#5a7a2a'), 0.65, 'bamboo-leaves', {
        hooks: {
          map: cardMap([0.85, 1.0, 0.75], [1.15, 1.08, 0.62], 0.55, 1.2),
          vertex: 'float gzT = max(position.y, 0.0) / ' + BAMBOO_H.toFixed(1) + ';\ntransformed += gz_toLocal(instanceMatrix, gz_wind((instanceMatrix * vec4(transformed, 1.0)).xyz, 0.06 * gzT * gzT + 0.012));',
          light: translucency(1.1, [1.05, 1.0, 0.5]),
          drySpecular: 0.35,
        },
      });
      var culmGeos = [culmGeometry(7, 9), culmGeometry(5, 5)];
      var leafGeos = [bambooLeafGeometry(ctx.rng('leaves0'), 0), bambooLeafGeometry(ctx.rng('leaves1'), 1)];
      var bamboo = [[], []];
      var br = ctx.rng('bamboo');
      var placed = [];
      var nBamboo = high ? 400 : 260;
      for (var at = 0; at < 12000 && placed.length < nBamboo; at++) {
        var bz = HEDGE_Z - 1.8 - Math.pow(br(), 1.25) * 44;
        var bx = (br() * 2 - 1) * (13 + (HEDGE_Z - bz) * 0.4);
        // the grove stands on the left and at the back; the right side opens toward the sun
        var edge = -1.5 + 0.32 * (HEDGE_Z - 2 - bz);
        if (bx > edge + (br() - 0.5) * 3) continue;
        // clumps: denser in patches
        var dens = texDensity(bx, bz);
        if (br() > dens) continue;
        var ok = true;
        for (var pi = placed.length - 1; pi >= 0 && pi > placed.length - 400; pi--) {
          if (Math.abs(placed[pi][0] - bx) < 0.6 && Math.abs(placed[pi][1] - bz) < 0.6) { ok = false; break; }
        }
        if (!ok) continue;
        placed.push([bx, bz]);
        var d = Math.hypot(bx - CAM[0], bz - CAM[2]);
        bamboo[d < 44 ? 0 : 1].push([bx, bz, 0.85 + br() * 0.45, 0.65 + br() * 0.5, br() * TAU, (br() - 0.5) * 0.14, (br() - 0.5) * 0.14]);
      }
      function texDensity(x, z) {
        return 0.35 + 0.65 * Math.pow(0.5 + 0.5 * Math.sin(x * 0.31 + Math.sin(z * 0.17) * 2.0) * Math.cos(z * 0.23 + x * 0.05), 1.5);
      }
      var bambooCounts = [bamboo[0].length, bamboo[1].length];
      bamboo.forEach(function (list, l) {
        if (!list.length) return;
        var culms = new THREE.InstancedMesh(culmGeos[l], culmMat, list.length);
        var leaves = new THREE.InstancedMesh(leafGeos[l], leafMat, list.length);
        list.forEach(function (b, i) {
          qq.setFromEuler(euler.set(b[5], b[4], b[6]));
          var m = dummy.compose(e3.set(b[0], -0.1, b[1]), qq, sv.set(b[2], b[3], b[2])).clone();
          culms.setMatrixAt(i, m);
          leaves.setMatrixAt(i, m);
        });
        [culms, leaves].forEach(function (o) {
          o.castShadow = true;
          o.receiveShadow = true;
          o.frustumCulled = false;
          scene.add(o);
        });
      });

      // ---------------------------------------------------------------- cherry branch in blossom
      // laid out in the view (screen x, y in -1..1 of a 9:16 frame, distance in m) so that it
      // crosses the top of the picture whatever the coordinates
      var viewCam = new THREE.PerspectiveCamera(camera.fov, 9 / 16, 0.1, 100);
      viewCam.position.set(CAM[0], CAM[1], CAM[2]);
      viewCam.lookAt(LOOK[0], LOOK[1], LOOK[2]);
      viewCam.updateMatrixWorld();
      viewCam.updateProjectionMatrix();
      function viewPoint(sx, sy, dist) {
        var v = new THREE.Vector3(sx, sy, 0.5).unproject(viewCam).sub(viewCam.position).normalize();
        return viewCam.position.clone().addScaledVector(v, dist);
      }
      var cr = ctx.rng('cherry');
      // the limb: cherry wood grows in short straight runs with kinks; it enters at the top left
      var limbCtl = [[-1.45, 1.02, 5.2], [-1.05, 0.88, 5.0], [-0.74, 0.8, 5.05], [-0.4, 0.74, 5.2], [-0.1, 0.71, 5.45], [0.2, 0.66, 5.7], [0.44, 0.66, 5.95]]
        .map(function (c) { return viewPoint(c[0], c[1], c[2]); });
      var limbCurve = new THREE.CatmullRomCurve3(limbCtl, false, 'catmullrom', 0.2);
      var branchParts = [];
      var spurs = [];   // [point, outward direction, cluster size]: where the blossoms are
      var limbPts = [];
      for (var li = 0; li <= 36; li++) {
        var lf = li / 36, lp = limbCurve.getPoint(lf);
        limbPts.push([lp.x, lp.y, lp.z, 0.036 * (1 - 0.7 * lf) + 0.007]);
      }
      branchParts.push(tubeGeometry(limbPts, 9, 0.1));
      function outward(d) {
        var o = new THREE.Vector3(cr() - 0.5, cr() - 0.3, cr() - 0.2).normalize();
        return o.addScaledVector(d, -o.dot(d) * 0.7).normalize();
      }
      function addSpurs(a, b, d, count, size) {
        for (var j = 0; j < count; j++) {
          var t = (j + 0.2 + cr() * 0.6) / count;
          spurs.push([a.clone().lerp(b, t), outward(d), size * (0.75 + cr() * 0.5)]);
        }
      }
      function branchFrom(start, dir, len, radius, depth) {
        var pts = [], p = start.clone(), d = dir.clone().normalize();
        var segs = 4 + Math.floor(cr() * 2);
        for (var sg = 0; sg <= segs; sg++) {
          pts.push([p.x, p.y, p.z, radius * (1 - 0.65 * sg / segs) + 0.0025]);
          if (sg === segs) break;
          // a kink at each node, a slight droop under the weight of the flowers
          d.x += (cr() - 0.5) * 0.6; d.y += (cr() - 0.5) * 0.5 - 0.07; d.z += (cr() - 0.5) * 0.35;
          d.normalize();
          var q0 = p.clone();
          p.addScaledVector(d, len / segs);
          addSpurs(q0, p, d, 2 + Math.floor(cr() * 2.5), 0.7 + 0.6 * sg / segs);
        }
        branchParts.push(tubeGeometry(pts, depth > 0 ? 6 : 4, 0.04));
        spurs.push([p.clone(), d.clone(), 1.3]);
        if (depth > 0) {
          var n = 2 + Math.floor(cr() * 2);
          for (var k = 0; k < n; k++) {
            var i2 = 1 + Math.floor(cr() * (pts.length - 2));
            var o = new THREE.Vector3(pts[i2][0], pts[i2][1], pts[i2][2]);
            var nd = new THREE.Vector3(d.x + (cr() - 0.5) * 1.2, (cr() - 0.55) * 1.1, d.z + (cr() - 0.5) * 0.8);
            branchFrom(o, nd, len * (0.35 + cr() * 0.25), radius * 0.5, depth - 1);
          }
        }
      }
      for (var lk = 0; lk < limbPts.length - 3; lk += 3) {
        var la = new THREE.Vector3(limbPts[lk][0], limbPts[lk][1], limbPts[lk][2]);
        var lb = new THREE.Vector3(limbPts[lk + 3][0], limbPts[lk + 3][1], limbPts[lk + 3][2]);
        if (lk > 6) addSpurs(la, lb, lb.clone().sub(la).normalize(), 2, 0.9);
      }
      for (var sb = 0; sb < 6; sb++) {
        var f0 = 0.12 + sb * 0.15 + cr() * 0.06;
        var o0 = limbCurve.getPoint(f0);
        var tan = limbCurve.getTangent(f0);
        var up = sb % 2 === 0 ? 0.55 : -0.6;
        var dir0 = new THREE.Vector3(tan.x + (cr() - 0.2) * 0.6, up + (cr() - 0.5) * 0.4, tan.z + (cr() - 0.5) * 0.8);
        branchFrom(o0, dir0, 0.45 + cr() * 0.45, 0.016, 1);
      }
      // the limb ends in a fork of flowering twigs
      var tipP = limbCurve.getPoint(1), tipD = limbCurve.getTangent(1);
      for (var tf = 0; tf < 3; tf++) {
        branchFrom(tipP, new THREE.Vector3(tipD.x, tipD.y + (tf - 1) * 0.5, tipD.z + (cr() - 0.5) * 0.5), 0.3 + cr() * 0.2, 0.008, 0);
      }
      var branchFlex = { value: 0.012 };
      var barkMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.8, metalness: 0 }, {
        key: 'cherry-bark',
        drySpecular: 0.35,
        vertex: 'transformed += gz_wind(transformed, uBranchFlex * smoothstep(' + limbCtl[1].x.toFixed(2) + ', ' + limbCtl[limbCtl.length - 1].x.toFixed(2) + ', transformed.x) + uBranchFlex * 0.5 * smoothstep(0.0, 0.8, ' + limbCurve.getPoint(0.5).y.toFixed(2) + ' - transformed.y));',
        vertexPars: 'uniform float uBranchFlex;',
        uniforms: { uBranchFlex: branchFlex },
        color: [
          // cherry bark: dark, glossy, with horizontal lenticels
          'float gzLen = smoothstep(0.75, 0.9, texture2D(uNoiseTex, vec2(vFoUv.x * 0.4, vFoUv.y * 6.0)).g);',
          'float gzBk = texture2D(uNoiseTex, vFoUv * vec2(0.5, 1.5)).r;',
          'diffuseColor.rgb = mix(vec3(0.045, 0.026, 0.022), vec3(0.11, 0.07, 0.055), gzBk) * (1.0 - 0.4 * gzLen);',
          'diffuseColor.rgb *= 1.0 - 0.3 * uWet;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.6, 0.35, uWet);',
      });
      var branch = new THREE.Mesh(mergeAll(branchParts), barkMat);
      branch.frustumCulled = false;
      scene.add(branch);

      // blossoms: flower cards in clusters at the twigs, translucent against the low sun
      var flowers = [];
      spurs.forEach(function (sp) {
        var n = Math.max(1, Math.round((3 + cr() * 3) * sp[2]));
        for (var k = 0; k < n; k++) {
          var p = sp[0].clone().addScaledVector(sp[1], 0.02 + cr() * 0.035)
            .add(new THREE.Vector3((cr() - 0.5) * 0.06, (cr() - 0.5) * 0.05, (cr() - 0.5) * 0.06));
          flowers.push([p, cr(), cr(), 0.021 + cr() * 0.008, cr() < 0.15, sp[1]]);
        }
      });
      if (!high) flowers = flowers.filter(function (f, i) { return i % 3 !== 2; });
      var flowerGeo = new THREE.PlaneGeometry(2, 2, 1, 1);
      var flowerMat = cardMaterial(blossomTex, lin('#ffffff'), 0.6, 'blossom', {
        params: { vertexColors: false },
        hooks: {
          map: cardMap([0.95, 0.4, 0.52], [1.0, 0.68, 0.76], 0.55, 1.0),
          vertex: 'transformed += gz_toLocal(instanceMatrix, gz_wind((instanceMatrix * vec4(transformed, 1.0)).xyz, uBranchFlex * smoothstep(' + limbCtl[1].x.toFixed(2) + ', ' + limbCtl[limbCtl.length - 1].x.toFixed(2) + ', instanceMatrix[3].x) + uBranchFlex * 0.5 * smoothstep(0.0, 0.8, ' + limbCurve.getPoint(0.5).y.toFixed(2) + ' - instanceMatrix[3].y)));',
          vertexPars: 'uniform float uBranchFlex;',
          uniforms: { uBranchFlex: branchFlex },
          light: translucency(0.55, [1.0, 0.75, 0.8]),
          drySpecular: 0.2,
        },
      });
      var blossoms = new THREE.InstancedMesh(flowerGeo, flowerMat, flowers.length);
      flowers.forEach(function (f, i) {
        // facing out of the spur, a little toward the viewer
        var nrm = f[5].clone().multiplyScalar(0.8).add(new THREE.Vector3((f[1] - 0.5) * 0.8, (f[2] - 0.4) * 0.6, 0.5));
        nrm.normalize();
        qq.setFromUnitVectors(new THREE.Vector3(0, 0, 1), nrm);
        var spin = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), f[1] * TAU);
        qq.multiply(spin);
        var s = f[4] ? f[3] * 0.45 : f[3];
        blossoms.setMatrixAt(i, dummy.compose(f[0], qq, sv.set(s, s, s)).clone());
      });
      blossoms.frustumCulled = false;
      scene.add(blossoms);

      // ---------------------------------------------------------------- pond (HDR mirror)
      var post = ctx.post({
        exposure: 0.88,
        toneMapping: 'aces',
        bloom: { strength: 0.16, threshold: 1.2, knee: 0.7, radius: 1.0 },
        rays: { strength: 0.3, length: 0.32, decay: 0.92, radius: 0.3 },
        aberration: 0.004,
        vignette: 0.36,
        grain: ctx.record ? 0 : 0.02,
      });
      var pondUniforms = Object.assign({}, shared, {
        uDeep: { value: lin('#0a1512').multiplyScalar(0.12) },
        uSunCol: { value: sunColor.clone().multiplyScalar(SUN_I) },
      });
      var pond = ctx.mirror({
        y: POND_Y,
        size: [40, 15],
        center: [0, POND_FAR + 7.5],
        scale: high ? 0.4 : 0.3,
        uniforms: pondUniforms,
        fragmentShader: 'uniform float uRain;\n' + FO_GLSL + '\n' + [
          'uniform vec3 uDeep; uniform vec3 uSunCol;',
          'varying vec4 vMirror; varying vec3 vWorld;',
          // gentle ripples: a few long waves, whole cycles per period (the loop stays exact); slope
          'vec2 wa_slope(vec2 p) {',
          '  float T = EV_TAU * uTime / EV_PERIOD;',
          '  vec2 s = vec2(0.0);',
          '  vec3 W[5];',
          '  W[0] = vec3(0.83, 0.55, 2.1); W[1] = vec3(-0.6, 0.8, 3.3); W[2] = vec3(0.2, -0.98, 4.6); W[3] = vec3(-0.95, -0.3, 6.2); W[4] = vec3(0.5, 0.86, 8.9);',
          '  for (int i = 0; i < 5; i++) {',
          '    float k = W[i].z;',
          '    float ph = dot(W[i].xy, p) * k - float(i + 2) * T + float(i) * 1.7;',
          '    s += W[i].xy * k * cos(ph) / (k * k);',
          '  }',
          '  return s;',
          '}',
          'float wa_rings(vec2 p) {',
          '  vec2 cell = floor(p * 1.6); vec2 f = fract(p * 1.6) - 0.5;',
          '  float h = 0.0;',
          '  for (int k = 0; k < 2; k++) {',
          '    float s = fract(sin(dot(cell + float(k) * 17.0, vec2(12.9898, 78.233))) * 43758.5453);',
          '    vec2 o = vec2(fract(s * 13.7), fract(s * 71.3)) - 0.5;',
          '    float ph = fract(uTime / EV_PERIOD * 10.0 + s);',
          '    float r = length(f - o * 0.6);',
          '    float q = (r - ph * 0.42) * 12.0;',
          '    h += sin((r - ph * 0.42) * 70.0) * exp(-q * q) * (1.0 - ph);',
          '  }',
          '  return h;',
          '}',
          'void main() {',
          '  vec3 toCam = cameraPosition - vWorld;',
          '  float dist = length(toCam);',
          '  vec3 V = toCam / dist;',
          '  vec2 p = vWorld.xz;',
          '  vec2 fw = fwidth(p);',
          '  float amp = 0.12 * (1.0 + 1.2 * uRain) * (1.0 - smoothstep(0.08, 0.3, max(fw.x, fw.y)));',
          '  vec2 sl = wa_slope(p) * amp;',
          '  vec3 n = vec3(-sl.x, 1.0, -sl.y);',
          '  if (uRain > 0.01) {',
          '    float re = 0.01;',
          '    float r0 = wa_rings(p), rx = wa_rings(p + vec2(re, 0.0)), rz = wa_rings(p + vec2(0.0, re));',
          '    float ra = 0.004 * uRain * (1.0 - smoothstep(0.02, 0.06, max(fw.x, fw.y)));',
          '    n.xz -= vec2(rx - r0, rz - r0) / re * ra;',
          '  }',
          '  n = normalize(n);',
          '  vec2 uv = vMirror.xy / vMirror.w + n.xz * 0.06;',
          '  vec3 refl = ev_mirror(uv);',
          '  float cosT = max(dot(V, n), 0.0);',
          '  float F = 0.02 + 0.98 * pow(clamp(1.0 - cosT, 0.0, 1.0), 5.0);',
          // the water itself: dark, a hint of the sky scattered in it
          // looking down into it near the viewer, the dark water swallows more of the reflection
          '  vec3 c = uDeep * (1.0 - F) + refl * F * 0.4 * mix(0.55, 1.0, smoothstep(4.0, 11.0, dist));',
          '  c = fo_fog(c, vWorld);',
          '  gl_FragColor = vec4(c, 1.0);',
          '}',
        ].join('\n'),
      });
      var mirrorRT = pond.getRenderTarget();
      if (post.floatTargets) mirrorRT.texture.type = THREE.HalfFloatType;
      pond.layers.set(1);
      scene.add(pond);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function levelOnly(object, uniforms, extra) {
        var u = { value: 0 };
        uniforms.forEach(function (m) { m.uLevel = u; });
        object.visible = false;
        return { object: object, setLevel: function (v) { u.value = v; if (extra) extra(v); } };
      }
      var DECOR_GLSL = D.GLSL, DECOR_VERT = D.GLSL_VERTEX;
      function hex(c) { return '#' + c.getHexString(); }

      // petals: the shared tumbling flakes, given HDR light (the sun, translucent against it)
      var petals = D.petales(ctx, {
        count: high ? 170 : 110, box: { min: [-3.2, -0.2, -6], max: [3.4, 4.6, 6.8] }, size: [0.016, 0.024],
        colors: [hex(lin('#f7cdd8')), hex(lin('#f3b9c9')), hex(lin('#fde9ee'))], lightDir: [sunDir.x, sunDir.y, sunDir.z],
        light: '#ffffff', ambient: '#ffffff', fog: '#ffffff', fogDensity: 0.012,
      });
      var pu = petals.object.material.uniforms;
      pu.uLight.value.copy(sunColor).multiplyScalar(SUN_I / Math.PI * 1.1);
      pu.uAmbient.value.copy(lin('#a8bad8')).multiplyScalar(0.42);
      pu.uFog.value.copy(shared.uFogAmb.value).multiplyScalar(1.4);

      // sun rays: shafts in the haze and dust, plus the light rays of the finish
      var sunFar = sunDir.clone().multiplyScalar(160).add(new THREE.Vector3(0, 0, -20));
      var rays = D['rayons-soleil'](ctx, {
        origin: [sunFar.x, sunFar.y, sunFar.z], toward: [-2, 0, -6], spread: 0.16, count: 9, length: 175,
        width: [0.5, 4.0], color: hex(lin('#ffdcae')), intensity: 0.07, falloff: 0.6,
        motes: high ? 160 : 90, moteColor: '#ffffff', moteSize: 0.02, spreadAxis: [0, 1, 0],
        onLevel: function (v) { post.uniforms.uRays.value.x = 0.15 + 0.45 * v; },
      });
      rays.object.children[1].material.uniforms.uColor.value.copy(lin('#ffe6c4')).multiplyScalar(2.2);
      // the motes live near the viewer, in the light: move them from the far shafts
      (function () {
        var g = rays.object.children[1].geometry, p = g.attributes.position;
        var mrr = ctx.rng('motes');
        for (var i = 0; i < p.count; i++) p.setXYZ(i, (mrr() * 2 - 1) * 3.2, 0.2 + mrr() * 3.6, 6.2 - mrr() * 12);
        p.needsUpdate = true;
      })();

      // rain: streaks lit by the sun where it reaches them, wet surfaces, rings on the pond
      var rainCount = high ? 1200 : 750;
      var rainGeo = new THREE.InstancedBufferGeometry();
      rainGeo.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(18), 3));
      rainGeo.setAttribute('corner', new THREE.Float32BufferAttribute([-1, 0, 1, 0, 1, 1, -1, 0, 1, 1, -1, 1], 2));
      var ra = [], rb = [];
      var rq = ctx.rng('rain');
      for (var ri = 0; ri < rainCount; ri++) {
        ra.push(rq(), rq(), rq(), rq());
        rb.push(Math.max(1, Math.round((8 + rq() * 2.5) * 30 / 10)), 0.35 + rq() * 0.3, 0.5 + rq() * 0.5, 0);
      }
      rainGeo.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(ra), 4));
      rainGeo.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(rb), 4));
      rainGeo.instanceCount = rainCount;
      var rainMat = ctx.material({
        uniforms: Object.assign({}, shared, {
          uLevel: { value: 0 }, uSunCol: { value: sunColor.clone() },
          uBoxMin: { value: new THREE.Vector3(-5, -0.3, -16) }, uBoxMax: { value: new THREE.Vector3(5, 9.7, 7) },
        }),
        transparent: true,
        blending: THREE.AdditiveBlending,
        vertexShader: DECOR_GLSL + '\n' + DECOR_VERT + '\n' + FO_GLSL + '\n' + [
          'uniform vec3 uBoxMin; uniform vec3 uBoxMax; uniform vec3 uSunCol;',
          'attribute vec2 corner; attribute vec4 aA; attribute vec4 aB;',
          'varying float vAlong; varying float vAcross; varying vec3 vC;',
          'void main() {',
          '  vec3 size = uBoxMax - uBoxMin;',
          '  float ph = fract(aA.z + aB.x * uTime / EV_PERIOD);',
          '  vec3 dir = normalize(vec3(-0.06, -1.0, 0.03));',
          '  vec3 head = uBoxMin + vec3(aA.x * size.x, (1.0 - ph) * size.y, aA.y * size.z);',
          '  vec3 tail = head - dir * aB.y;',
          '  vec3 hv = (viewMatrix * vec4(head, 1.0)).xyz;',
          '  vec3 tv = (viewMatrix * vec4(tail, 1.0)).xyz;',
          '  float dist = -hv.z;',
          '  if (dist < 0.35 || -tv.z < 0.35) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vC = vec3(0.0); vAlong = 0.0; vAcross = 0.0; return; }',
          '  float w = max(1.1 * uPixelRatio, 0.0035 * uFocal / dist);',
          '  gl_Position = ev_streak(hv, tv, corner, w);',
          '  float env = smoothstep(0.0, 0.05, ph) * smoothstep(1.0, 0.95, ph);',
          '  float lit = fo_shadow(head);',
          '  float phs = fo_phase(dot(normalize(head - cameraPosition), uSunDir));',
          '  vec3 c = uFogAmb * 0.9 + uSunCol * (0.05 + phs * lit * 1.4);',
          '  vC = c * ev_present(aA.w) * env * aB.z * smoothstep(0.5, 2.0, dist) * (0.55 + 0.45 * uLevel) * fo_trans(head);',
          '  vC *= min(1.0, 1.6 / (0.6 + w)) * 0.35;',
          '  vAlong = corner.y; vAcross = corner.x;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying float vAlong; varying float vAcross; varying vec3 vC;',
          'void main() {',
          '  float across = 1.0 - vAcross * vAcross;',
          '  float along = smoothstep(0.0, 0.25, vAlong) * smoothstep(1.0, 0.4, vAlong);',
          '  gl_FragColor = vec4(vC * across * along, 1.0);',
          '}',
        ].join('\n'),
      });
      var rain = new THREE.Mesh(rainGeo, rainMat);
      rain.frustumCulled = false;
      rain.renderOrder = 23;
      rain.layers.set(1);

      var mistLevel = 0, rainLevel = 0;
      function applyAir() {
        var low = high ? 1 : 0.75;
        shared.uFog.value.x = fogBase.density * (1 + 0.6 * mistLevel + 0.5 * rainLevel) * low;
        shared.uFog.value.y = fogBase.ground * (1 + 1.2 * mistLevel + 0.4 * rainLevel) * low;
        shared.uFog.value.w = (0.2 + 0.8 * mistLevel) * low;
        sun.intensity = SUN_I * (1 - 0.5 * rainLevel);
        shared.uSunFog.value.copy(lin('#ffd3a0')).multiplyScalar(1.0 * (1 - 0.45 * rainLevel));
      }
      var decors = {
        petales: petals,
        'rayons-soleil': rays,
        brume: levelOnly(new THREE.Group(), [], function (v) { mistLevel = v; applyAir(); }),
        pluie: levelOnly(rain, [rainMat.uniforms], function (v) {
          rainLevel = v;
          shared.uWet.value = v;
          shared.uRain.value = v;
          applyAir();
        }),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });
      applyAir();

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = t / ctx.PERIOD * TAU;
        camera.position.set(CAM[0] + 0.3 * Math.sin(T), CAM[1] + 0.04 * Math.sin(2 * T + 0.4), CAM[2] + 0.35 * Math.cos(T) - 0.35);
        camera.lookAt(LOOK[0] + 0.45 * Math.sin(T + 0.6), LOOK[1] + 0.12 * Math.sin(T), LOOK[2]);
      }
      update(0);
      var sunScreen = new THREE.Vector3();

      // the mist and the rain sample the sun's shadow map: one tiny render makes it (and compiles
      // the programs) before the first frame
      function primeShadows() {
        renderer.shadowMap.needsUpdate = true;
        var rt = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType });
        renderer.setRenderTarget(rt);
        renderer.render(scene, camera);
        renderer.setRenderTarget(null);
        rt.dispose();
        var ready = !!(sun.shadow.map && sun.shadow.map.depthTexture);
        shared.uShadowMap.value = ready ? sun.shadow.map.depthTexture : shadowPlaceholder;
        shared.uShadowMatrix.value = sun.shadow.matrix;
        shared.uShadowReady.value = ready ? 1 : 0;
      }
      primeShadows();

      return {
        decors: decors,
        update: update,
        render: function () {
          camera.updateMatrixWorld();
          sunScreen.copy(sunDir).multiplyScalar(500).add(camera.position).project(camera);
          post.setLight(sunScreen.x * 0.5 + 0.5, sunScreen.y * 0.5 + 0.5);
          post.render(scene, camera);
        },
        setQuality: function (qq2) {
          quality = qq2;
          high = qq2 === 'high';
          post.setQuality(qq2);
          patched.forEach(function (m) {
            if (m.alphaTest > 0) m.alphaToCoverage = high;
            m.needsUpdate = true;
          });
          var size = high ? 1024 : 512;
          sun.shadow.mapSize.set(size, size);
          if (sun.shadow.map) {
            sun.shadow.map.dispose();
            sun.shadow.map = null;
          }
          shared.uShadowMap.value = shadowPlaceholder;
          primeShadows();
          applyAir();
        },
        describe: function () {
          var d = post.describe();
          d.shadowMap = sun.shadow.mapSize.x;
          d.mirror = { w: mirrorRT.width, h: mirrorRT.height, type: post.floatTargets ? 'half-float' : 'rgba8' };
          d.bamboo = bambooCounts;
          d.blossoms = flowers.length;
          return d;
        },
        dispose: function () {
          post.dispose();
          textures.forEach(function (t) { t.dispose(); });
          envRT.dispose();
          sun.dispose();
        },
      };
    },
  });
})();
