/*
 * « Mer de nuages », version 2: above a sea of clouds at dawn, drawn as a real 3D scene with the
 * HDR finish of post.js (the quality bar of the forest v2).
 *
 *   - The sea of clouds: a fan of vertices around the viewer lifted into billows by a looping
 *     height field (rounded cells at three scales) that drifts slowly toward the viewer; lit from
 *     behind by the rising sun: wrap lighting with the billows' own shadows toward the sun, sky
 *     light darker in the hollows, forward scattering through the thin edges and tops.
 *   - Peaks rising from the sea (a 3D relief with snow on the gentler upper slopes) whose long
 *     shadows lie on the clouds (one directional light, static shadow map).
 *   - The foreground: a summit of rock and alpine grass, boulders, a few spruces at its edge,
 *     kept dark (backlit) for the lower third.
 *   - Air: height fog with a forward-scattering lobe lit by the sun (gold toward it, violet
 *     elsewhere), a band of haze over the cloud tops integrated analytically, the curvature of the
 *     Earth hiding the far edge of the sea; sky with cirrus streaks catching the dawn.
 * Everything that moves is a function of the scene time t (modulo 30 s): the period loops.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;
  var TAU = Math.PI * 2;

  // ------------------------------------------------------------------ layout
  var CAM = [0, 62, 0];
  var LOOK = [-60, -26, -1000];
  var SUN_AZ = -10, SUN_EL = 3.2;   // degrees: left of the view axis, above the horizon
  var TREE_H = 14;

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

  // Spruce spray (one branch seen from above): a main shoot carrying alternate branchlets, which
  // carry short twigs; every shoot is a bottle-brush of short needles, so the spray reads as a
  // dense, ragged mass. u (x) runs from the trunk to the tip.
  function sprayTexture(rng) {
    var W = 256, H = 128, c = raster(W, H);
    function shoot(x, y, a, len, curve, needle, depth, shadeBase, tint) {
      var steps = Math.max(3, Math.round(len / 3));
      var pts = [[x, y, a]];
      for (var s = 1; s <= steps; s++) {
        a += curve / steps;
        x += Math.cos(a) * len / steps;
        y += Math.sin(a) * len / steps;
        pts.push([x, y, a]);
      }
      for (var k = 1; k < pts.length; k++) {
        var f0 = (k - 1) / steps;
        stroke(c, pts[k - 1][0], pts[k - 1][1], pts[k][0], pts[k][1], needle * 0.16 * (1 - 0.6 * f0) + 0.3, needle * 0.16 * (1 - 0.6 * f0) + 0.25, shadeBase * 0.6, tint);
      }
      // needles all around the shoot, leaning forward, shorter toward the tip
      var along = 0;
      for (var q = 1; q < pts.length; q++) {
        var ax = pts[q - 1][0], ay = pts[q - 1][1], ang = pts[q - 1][2];
        var sl = Math.hypot(pts[q][0] - ax, pts[q][1] - ay);
        for (var d = 0; d < sl; d += 0.75) {
          var f = (along + d) / len;
          var px = ax + Math.cos(ang) * d, py = ay + Math.sin(ang) * d;
          for (var n = 0; n < 2; n++) {
            var side = (n === 0 ? -1 : 1) * (0.45 + rng() * 0.9);
            var na = ang + side;
            var nl = needle * (0.65 + rng() * 0.45) * (1 - 0.4 * f);
            stroke(c, px, py, px + Math.cos(na) * nl, py + Math.sin(na) * nl, 0.62, 0.36,
              shadeBase + (1 - shadeBase) * 0.55 * f + (rng() - 0.5) * 0.14, tint + (rng() - 0.5) * 0.1);
          }
        }
        along += sl;
      }
      if (depth <= 0) return;
      // alternate children
      var count = depth === 2 ? 22 : 3 + Math.floor(rng() * 2);
      for (var i = 0; i < count; i++) {
        var f2 = depth === 2 ? 0.05 + (i + rng() * 0.4) / count * 0.9 : 0.2 + (i + rng() * 0.5) / count * 0.65;
        var idx = Math.min(pts.length - 1, Math.round(f2 * steps));
        var p = pts[idx], sideSign = i % 2 ? 1 : -1;
        var ca = p[2] + sideSign * ((depth === 2 ? 44 : 50) + rng() * 14) * Math.PI / 180;
        var env = depth === 2
          ? Math.pow(Math.sin(Math.PI * Math.min(1, f2 * 1.05 + 0.05)), 0.8) * (1 - 0.35 * f2) * H * 0.47
          : len * (0.42 * (1 - f2) + 0.08);
        shoot(p[0], p[1], ca, env * (0.85 + rng() * 0.25), -sideSign * 0.25, needle * 0.82, depth - 1,
          Math.min(0.9, shadeBase + 0.08), tint + (rng() - 0.5) * 0.25);
      }
    }
    shoot(2, H * 0.5 + 2, -0.02, W - 8, 0.04, 5.2, 2, 0.42, 0.5);
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

  // Spruce: a tapered trunk; uv: around (m), height (m).
  function trunkGeometry(radial, rings) {
    var pos = [], nor = [], uv = [], idx = [];
    for (var j = 0; j < rings.length; j++) {
      var y = rings[j];
      var r = 0.24 * Math.pow(Math.max(0, 1 - y / TREE_H), 0.85) + 0.015;
      for (var i = 0; i <= radial; i++) {
        var th = i / radial * TAU, cx = Math.cos(th), sz = Math.sin(th);
        pos.push(cx * r, y, sz * r); nor.push(cx, 0.08, sz); uv.push(i / radial * TAU * 0.3, y);
      }
    }
    for (var a = 0; a < rings.length - 1; a++) {
      for (var b = 0; b < radial; b++) {
        var p = a * (radial + 1) + b, q = p + radial + 1;
        idx.push(p, q, p + 1, p + 1, q, q + 1);
      }
    }
    var g = geometry(pos, nor, uv, idx);
    g.computeVertexNormals();
    return g;
  }
  // Its crown: tiers of drooping branch cards carrying the spray texture (as the forest's).
  function crownGeometry(rng) {
    var B = { pos: [], nor: [], uv: [], idx: [], col: [] };
    var yb = TREE_H * 0.18, top = TREE_H;
    for (var y = yb; y < top - 0.4; y += 0.34 + rng() * 0.12) {
      var c = (y - yb) / (top - yb);
      var len = 0.23 * TREE_H * Math.pow(1 - c, 0.85) + 0.3;
      var rot = y * 2.39996 + rng();
      for (var k = 0; k < 8; k++) {
        var th = rot + k / 8 * TAU + (rng() - 0.5) * 0.5;
        var l = len * (0.8 + rng() * 0.35);
        var trunkR = 0.24 * Math.pow(1 - y / TREE_H, 0.85) * 0.6;
        addCard(B, [Math.cos(th) * trunkR, y, Math.sin(th) * trunkR], Math.cos(th), Math.sin(th), l, l * 0.72 + 0.15,
          (-0.6 + 0.6 * c) + (rng() - 0.5) * 0.25, 0.4 * (1 - c) + 0.08, (k % 2 ? 1 : -1) * 0.45 + (rng() - 0.5) * 0.5, 0.7 + 0.3 * c, 2, 0.25);
      }
    }
    for (var q = 0; q < 2; q++) {
      var a = q * Math.PI / 2, b0 = B.pos.length / 3, ca = Math.cos(a) * 0.3, sa = Math.sin(a) * 0.3;
      B.pos.push(-ca, top - 1.2, -sa, ca, top - 1.2, sa, -ca * 0.3, top + 0.3, -sa * 0.3, ca * 0.3, top + 0.3, sa * 0.3);
      for (var e = 0; e < 4; e++) { B.nor.push(0, 1, 0); B.col.push(0.9, 0.9, 0.9); }
      B.uv.push(0.15, 0, 0.15, 1, 0.95, 0, 0.95, 1);
      B.idx.push(b0, b0 + 2, b0 + 1, b0 + 1, b0 + 2, b0 + 3);
    }
    return geometry(B.pos, B.nor, B.uv, B.idx, B.col);
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

  // ------------------------------------------------------------------ foreground: the summit
  // The viewer stands on a summit: a slope of rock and alpine grass falls toward an irregular
  // edge (~35 m ahead), then a cliff drops into the sea of clouds (its deck lies 62 m below).
  function edgeZ(x) {
    return -29 + 4 * Math.sin(x * 0.08 + 0.5) + 2.5 * Math.sin(x * 0.21 + 1.3) + 1.0 * Math.sin(x * 0.53);
  }
  function ridgeY(x, z) {
    var y = 60.2 - 0.3 * Math.max(0, -z) + 0.05 * Math.max(0, z);
    y += 5.0 * Math.exp(-Math.pow((x + 17) / 7, 2) - Math.pow((z + 24) / 10, 2));   // a knoll on the left
    y += 2.0 * Math.exp(-Math.pow((x - 13) / 6, 2) - Math.pow((z + 26) / 8, 2));    // a smaller one on the right
    y += 0.5 * Math.sin(0.35 * x + 0.2 * z) + 0.3 * Math.sin(0.9 * x - 0.5 * z + 2.0) + 0.15 * Math.sin(2.1 * x + 1.7 * z);
    y += 0.0025 * x * x;
    var over = edgeZ(x) - z;
    if (over > 0) y -= 2.2 * over + 0.09 * over * over;
    return y;
  }

  // ------------------------------------------------------------------ scene
  E.register({
    id: 'mer-nuages',
    decors: ['oiseaux-vol', 'etoiles', 'etoiles-filantes', 'brume', 'rayons-soleil'],
    defaults: { 'oiseaux-vol': 30, 'rayons-soleil': 40 },
    post: true,

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera, renderer = ctx.renderer;
      var quality = ctx.quality;
      var high = quality === 'high';
      camera.fov = 50;
      camera.near = 0.5;
      camera.far = 30000;

      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFShadowMap;
      // the sun and the peaks stand still: their shadows on the clouds are drawn once
      renderer.shadowMap.autoUpdate = false;

      var az = SUN_AZ * Math.PI / 180, el = SUN_EL * Math.PI / 180;
      var sunDir = new THREE.Vector3(Math.sin(az) * Math.cos(el), Math.sin(el), -Math.cos(az) * Math.cos(el)).normalize();
      var noiseTex = noiseTexture(ctx.rng('noise'));
      var sprayTex = sprayTexture(ctx.rng('spray'));
      var textures = [noiseTex, sprayTex];

      var shared = {
        uTime: ctx.uniforms.uTime,
        uSunDir: { value: sunDir },
        uSunFog: { value: lin('#ffb47c').multiplyScalar(0.6) },
        uFogAmb: { value: lin('#8c84b0').multiplyScalar(0.12) },
        uFog: { value: new THREE.Vector4(0.00004, 0.00026, 0.011, 0.25) },
        uMist: { value: new THREE.Vector4(8, 14, 0.07, 0.0035) },
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

      var patched = [];
      function pbr(Kind, params, hooks) {
        var m = new Kind(params);
        hooks = hooks || {};
        m.onBeforeCompile = function (shader) {
          Object.keys(shared).forEach(function (k) { shader.uniforms[k] = shared[k]; });
          Object.assign(shader.uniforms, hooks.uniforms || {});
          var head = 'varying vec3 vFoWorld;\nvarying vec2 vFoUv;\nuniform float uTime;\nuniform float uWet;\nuniform float uRain;\n#define EV_PERIOD 30.0\n#define EV_TAU 6.28318530718\n';
          var vs = shader.vertexShader
            .replace('#include <common>', '#include <common>\n' + head + (hooks.vertexPars || ''))
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
              'reflectedLight.directSpecular *= ' + (hooks.drySpecular !== undefined ? hooks.drySpecular : 0.3).toFixed(3) + ';\n' +
              (hooks.lightEnd || ''))
            .replace('#include <fog_fragment>', 'gl_FragColor.rgb = fo_fog(gl_FragColor.rgb, vFoWorld);');
          shader.vertexShader = vs;
          shader.fragmentShader = fs;
        };
        m.customProgramCacheKey = function () { return 'mn-' + hooks.key + '-' + quality; };
        patched.push(m);
        return m;
      }
      function glf(x) { return Number(x).toFixed(3); }

      // ---------------------------------------------------------------- sky
      var SKY_FRAGMENT = [
        'uniform vec3 uZenith; uniform vec3 uMid; uniform vec3 uHorizon; uniform vec3 uGold; uniform vec3 uSunDisc; uniform vec3 uCloudLit;',
        'varying vec3 vDir;',
        'void main() {',
        '  vec3 d = normalize(vDir);',
        '  float c = dot(d, uSunDir);',
        '  float y = max(d.y, 0.0);',
        // dawn: gold and rose low on the horizon (gold toward the sun), violet, then deep blue
        '  float az = 0.5 + 0.5 * dot(d.xz / max(length(d.xz), 1e-4), normalize(uSunDir.xz));',
        '  vec3 low = mix(uHorizon, uGold, smoothstep(0.35, 1.0, az));',
        '  vec3 col = mix(low, uMid, smoothstep(0.0, 0.22, y));',
        '  col = mix(col, uZenith, smoothstep(0.15, 0.85, y));',
        '  col += uSunFog * fo_phase(c) * 0.3;',
        // high streaks of cirrus catching the dawn, lit from below
        '  vec2 p = d.xz / max(d.y + 0.1, 0.03) * 0.045;',
        '  float ci = fo_loopNoise(p * vec2(0.6, 2.2) + vec2(0.17, 0.4), vec2(0.0012, 0.0));',
        '  float streak = smoothstep(0.55, 0.85, ci) * smoothstep(0.04, 0.2, d.y) * (1.0 - smoothstep(0.45, 0.8, d.y));',
        '  col = mix(col, uCloudLit * (0.4 + 3.0 * fo_phase(c)) * mix(vec3(1.0, 0.72, 0.8), vec3(1.0), az), streak * 0.6);',
        '  float r = acos(clamp(c, -1.0, 1.0));',
        '  col += uSunDisc * (1.0 - smoothstep(0.0085, 0.0096, r));',
        '  col = fo_skyFog(col, d);',
        '  gl_FragColor = vec4(col, 1.0);',
        '}',
      ].join('\n');
      var sky = new THREE.Mesh(new THREE.SphereGeometry(20000, 48, 24), ctx.material({
        uniforms: Object.assign({}, shared, {
          uZenith: { value: lin('#22356e').multiplyScalar(0.6) },
          uMid: { value: lin('#8086c8').multiplyScalar(0.85) },
          uHorizon: { value: lin('#eaa49a').multiplyScalar(1.5) },
          uGold: { value: lin('#ffc286').multiplyScalar(2.6) },
          uSunDisc: { value: lin('#ffe6c2').multiplyScalar(80) },
          uCloudLit: { value: lin('#ffd2b0').multiplyScalar(0.9) },
        }),
        vertexShader: 'varying vec3 vDir;\nvoid main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        fragmentShader: FO_GLSL + '\n' + SKY_FRAGMENT,
        side: THREE.BackSide,
        depthWrite: false,
      }));
      sky.renderOrder = 10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- lights
      var sunColor = lin('#ffc490');
      var SUN_I = 10;
      var sun = new THREE.DirectionalLight(sunColor, SUN_I);
      var target = new THREE.Vector3(1500, 0, -4500);
      sun.target.position.copy(target);
      sun.position.copy(target).addScaledVector(sunDir, 8000);
      sun.castShadow = true;
      var shadowSize = high ? 1024 : 512;
      sun.shadow.mapSize.set(shadowSize, shadowSize);
      sun.shadow.bias = -0.0004;
      sun.shadow.normalBias = 0;
      sun.shadow.radius = 2.0;
      scene.add(sun);
      scene.add(sun.target);
      (function fitShadow() {
        sun.updateMatrixWorld();
        var sc = sun.shadow.camera;
        sc.position.copy(sun.position);
        sc.lookAt(target);
        sc.updateMatrixWorld();
        var inv = sc.matrixWorldInverse;
        var lo = new THREE.Vector3(1e9, 1e9, 1e9), hi = new THREE.Vector3(-1e9, -1e9, -1e9), v = new THREE.Vector3();
        [-2500, 6500].forEach(function (x) {
          [-60, 1250].forEach(function (y) {
            [-10500, 200].forEach(function (z) {
              v.set(x, y, z).applyMatrix4(inv);
              lo.min(v); hi.max(v);
            });
          });
        });
        sc.left = lo.x; sc.right = hi.x; sc.bottom = lo.y; sc.top = hi.y;
        sc.near = Math.max(1, -hi.z - 50); sc.far = -lo.z + 50;
        sc.updateProjectionMatrix();
      })();
      var hemi = new THREE.HemisphereLight(lin('#8f8cc4'), lin('#6a5a72'), 0.8);
      scene.add(hemi);

      // ---------------------------------------------------------------- peaks rising from the sea
      var PEAKS = [
        [1350, -3600, 520, 1000], [2500, -4900, 760, 1400], [3150, -4500, 600, 900], [800, -6600, 1050, 1800],
        [4300, -3900, 430, 950], [3300, -8000, 900, 1800], [-3700, -7200, 700, 1500], [-1500, -9400, 560, 1500],
        [5800, -6300, 640, 1300], [-200, -5200, 380, 900],
      ];
      function peakY(x, z) {
        var h = -90;
        for (var i = 0; i < PEAKS.length; i++) {
          var P = PEAKS[i];
          var dx = x - P[0], dz = z - P[1];
          var d = Math.sqrt(dx * dx + dz * dz) / P[3];
          if (d >= 1) continue;
          var a = Math.atan2(dz, dx);
          // ridges radiate from the summit: the cone is carved between them
          var ridges = 0.72 + 0.22 * Math.pow(Math.abs(Math.sin(a * 2.5 + i * 1.7)), 0.6) + 0.1 * Math.sin(a * 7 + i * 2.3)
            + 0.14 * Math.sin(a + i * 0.9) + 0.06 * Math.sin(a * 13 + i);
          var cone = Math.pow(1 - Math.min(1, d / ridges), 1.45);
          h = Math.max(h, -90 + (P[2] + 90) * cone);
        }
        // ridged detail (gullies and arêtes), stronger on the high slopes
        var up = Math.max(0, Math.min(1, (h + 60) / 300));
        var r = 0, amp = 1, fx = x * 0.0021, fz = z * 0.0021;
        for (var o = 0; o < 4; o++) {
          r += amp * (1 - Math.abs(vnoise2(fx, fz) * 2 - 1));
          fx = fx * 2.03 + 3.1; fz = fz * 2.03 - 1.7; amp *= 0.5;
        }
        h += (r - 0.9) * 190 * up + 14 * Math.sin(x * 0.011 + z * 0.007);
        return h;
      }
      var nr = ctx.rng('peak-noise'), NL = 64, nlat = new Float32Array(NL * NL);
      for (var nq = 0; nq < nlat.length; nq++) nlat[nq] = nr();
      function vnoise2(x, y) {
        var xi = Math.floor(x), yi = Math.floor(y), fx = x - xi, fy = y - yi;
        var ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
        var x0 = ((xi % NL) + NL) % NL, x1 = (x0 + 1) % NL, y0 = ((yi % NL) + NL) % NL, y1 = (y0 + 1) % NL;
        var a = nlat[y0 * NL + x0], b = nlat[y0 * NL + x1], c = nlat[y1 * NL + x0], d = nlat[y1 * NL + x1];
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
      }
      var pkp = [], pkn = [], pku = [], pki = [];
      var PX = high ? 220 : 150, PZ = high ? 90 : 60;
      for (var pj = 0; pj <= PZ; pj++) {
        var pz = -2600 - 8200 * pj / PZ;
        for (var pi = 0; pi <= PX; pi++) {
          var px = -6500 + 13500 * pi / PX;
          pkp.push(px, peakY(px, pz), pz);
          pkn.push(0, 1, 0);
          pku.push(px, pz);
        }
      }
      for (var pa = 0; pa < PZ; pa++) {
        for (var pb = 0; pb < PX; pb++) {
          var q0 = pa * (PX + 1) + pb, q1 = q0 + PX + 1;
          pki.push(q0, q0 + 1, q1, q0 + 1, q1 + 1, q1);
        }
      }
      var peakGeo = geometry(pkp, pkn, pku, pki);
      peakGeo.computeVertexNormals();
      var peakMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.9, metalness: 0 }, {
        key: 'peaks',
        drySpecular: 0.3,
        color: [
          'vec3 mnN = normalize(cross(dFdx(vFoWorld), dFdy(vFoWorld)));',
          'float mnR = texture2D(uNoiseTex, vFoWorld.xz * 0.0011).r;',
          'float mnG = texture2D(uNoiseTex, vFoWorld.xz * 0.004 + vFoWorld.y * 0.002).g;',
          'vec3 mnRock = mix(vec3(0.05, 0.045, 0.05), vec3(0.13, 0.11, 0.11), mnR * 0.6 + mnG * 0.4);',
          // snow on the gentler upper slopes, broken by rock ribs
          'float mnSnow = smoothstep(0.55, 0.78, mnN.y + (mnG - 0.5) * 0.5) * smoothstep(120.0, 380.0, vFoWorld.y + mnR * 150.0);',
          'diffuseColor.rgb = mix(mnRock, vec3(0.78, 0.8, 0.86), mnSnow);',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.9, 0.6, mnSnow);',
        normal: 'normal = fo_bump(normal, -vViewPosition, mnG, 0.6);',
      });
      var peaks = new THREE.Mesh(peakGeo, peakMat);
      peaks.castShadow = true;
      peaks.receiveShadow = true;
      peaks.frustumCulled = false;
      scene.add(peaks);

      // ---------------------------------------------------------------- the sea of clouds
      // A fan of vertices around the viewer (rows ever wider with distance), lifted into billows by
      // a looping height field: rounded cells (Worley domes) at three scales, drifting toward the
      // viewer. Shading: wrap lighting with the billows' own shadows toward the sun (marched in the
      // vertex shader), the peaks' shadows (shadow map), sky light darker in the hollows, and
      // forward scattering through the thin edges, strongest toward the sun: lit from behind.
      var FAN_R = high ? 150 : 100, FAN_A = high ? 120 : 84;
      var cp = [], ci = [];
      var A0 = -0.5, A1 = 0.38;   // angles (radians) left and right of the view axis
      for (var ri = 0; ri <= FAN_R; ri++) {
        var dist = 70 * Math.pow(16000 / 70, ri / FAN_R);
        for (var ai = 0; ai <= FAN_A; ai++) {
          var ang = A0 + (A1 - A0) * ai / FAN_A - 0.06;
          cp.push(Math.sin(ang) * dist, 0, -Math.cos(ang) * dist);
        }
      }
      for (var r2 = 0; r2 < FAN_R; r2++) {
        for (var a2 = 0; a2 < FAN_A; a2++) {
          var c0 = r2 * (FAN_A + 1) + a2, c1 = c0 + FAN_A + 1;
          ci.push(c0, c0 + 1, c1, c0 + 1, c1 + 1, c1);
        }
      }
      var cloudGeo = new THREE.BufferGeometry();
      cloudGeo.setAttribute('position', new THREE.Float32BufferAttribute(cp, 3));
      cloudGeo.setIndex(ci);
      var CLOUD_GLSL = [
        'uniform vec2 uDrift;',
        'float cl_dome(vec2 p) { float w = texture2D(uNoiseTex, p).a; return 1.0 - w * w; }',
        'float cl_field(vec2 p, float detail) {',
        '  float h = 20.0 * cl_dome(p / 2400.0 + vec2(0.11, 0.37));',
        '  h += 24.0 * cl_dome(p / 720.0 + vec2(0.53, 0.21));',
        '  h += 11.0 * detail * cl_dome(p / 230.0 + vec2(0.29, 0.77));',
        '  h += 24.0 * (texture2D(uNoiseTex, p / 12000.0).r - 0.5);',
        '  return h - 32.0;',
        '}',
        // the field drifts toward the viewer and loops: two copies half a period apart, crossfaded
        'float cl_height(vec2 p, float detail) {',
        '  float tau = uTime / EV_PERIOD;',
        '  vec2 w = fo_weights(uTime);',
        '  float a = cl_field(p - uDrift * EV_PERIOD * (fract(tau) - 0.5), detail);',
        '  float b = cl_field(p - uDrift * EV_PERIOD * (fract(tau + 0.5) - 0.5) + vec2(731.0, 377.0), detail);',
        '  float m = -2.0;',
        '  return m + (w.x * (a - m) + w.y * (b - m)) / sqrt(w.x * w.x + w.y * w.y);',
        '}',
      ].join('\n');
      var cloudMat = ctx.material({
        uniforms: Object.assign({}, shared, {
          uDrift: { value: new THREE.Vector2(0.4, 2.6) },
          uSunCol: { value: sunColor.clone().multiplyScalar(SUN_I) },
          uAmbHi: { value: lin('#a09ee0').multiplyScalar(0.55) },
          uAmbLo: { value: lin('#4c4690').multiplyScalar(0.24) },
          uAlbedo: { value: new THREE.Vector3(0.92, 0.9, 0.92) },
        }),
        vertexShader: FO_GLSL + '\n' + CLOUD_GLSL + '\n' + [
          'varying vec3 vWorld; varying vec3 vN; varying float vVis; varying float vTop;',
          'void main() {',
          '  vec3 p = position;',
          '  float dist = length(p.xz - cameraPosition.xz);',
          // the finest cells fade out where a vertex row is wider than they are
          '  float detail = 1.0 - smoothstep(1200.0, 3200.0, dist);',
          '  float e = clamp(dist * 0.012, 2.0, 40.0);',
          '  float h = cl_height(p.xz, detail);',
          '  float hx = cl_height(p.xz + vec2(e, 0.0), detail);',
          '  float hz = cl_height(p.xz + vec2(0.0, e), detail);',
          // the sea sinks with the curvature of the Earth (and hides its far edge in the haze)
          // (right under the cliff the sea lies a little lower: no billow rises in front of the viewer)
          '  p.y = h - dist * dist / 12.7e6 - 22.0 * (1.0 - smoothstep(120.0, 700.0, dist));',
          '  vN = normalize(vec3(-(hx - h) / e, 1.0, -(hz - h) / e));',
          '  vTop = clamp((h + 25.0) / 55.0, 0.0, 1.0);',
          // the billows' own shadows: does the field rise above the ray toward the sun?
          '  vec2 sd = normalize(uSunDir.xz);',
          '  float tanEl = uSunDir.y / length(uSunDir.xz);',
          '  float vis = 1.0;',
          '  for (int k = 1; k <= 3; k++) {',
          '    float dk = 30.0 * float(k * k);',
          '    float hk = cl_height(p.xz + sd * dk, 0.0);',
          '    vis = min(vis, clamp(1.0 - (hk - h - dk * tanEl) / 8.0, 0.0, 1.0));',
          '  }',
          '  vVis = vis;',
          '  vec4 w = modelMatrix * vec4(p, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: FO_GLSL + '\n' + BUMP_GLSL + '\n' + [
          'uniform vec3 uSunCol; uniform vec3 uAmbHi; uniform vec3 uAmbLo; uniform vec3 uAlbedo; uniform vec2 uDrift;',
          'varying vec3 vWorld; varying vec3 vN; varying float vVis; varying float vTop;',
          'float cl_phase(float c, float g) { return (1.0 - g * g) / pow(max(1.0 + g * g - 2.0 * g * clamp(c, -1.0, 1.0), 1e-3), 1.5) * 0.0796; }',
          'void main() {',
          '  vec3 V = cameraPosition - vWorld;',
          '  float dist = length(V);',
          '  V /= dist;',
          '  vec3 N = normalize(vN);',
          // cauliflower detail near the viewer (drifting with the field, fading with distance)
          '  vec2 dp = vWorld.xz - uDrift * (uTime - 15.0);',
          '  float fine = smoothstep(1400.0, 200.0, dist);',
          '#ifndef FO_LOW',
          '  float det = texture2D(uNoiseTex, dp / 55.0).a * 0.6 + texture2D(uNoiseTex, dp / 21.0 + 0.3).a * 0.4;',
          '  N = fo_bump(N, vWorld, 1.0 - det, 2.2 * fine);',
          '#endif',
          // light diffuses inside a cloud: soften the normal, wrap the sun far around
          '  vec3 Ns = normalize(mix(N, vec3(0.0, 1.0, 0.0), 0.35));',
          '  float ndl = dot(Ns, uSunDir);',
          '  float shade = vVis * fo_shadow(vWorld + vec3(0.0, 2.0, 0.0));',
          '  float wrap = pow(clamp((ndl + 0.55) / 1.55, 0.0, 1.0), 2.0);',
          '  vec3 direct = uSunCol * wrap * shade;',
          // forward scattering toward the sun: the tops and the crests seen against it glow
          '  float c = dot(-V, uSunDir);',
          '  float ph = 0.7 * cl_phase(c, 0.75) + 0.3 * cl_phase(c, 0.3);',
          '  float back = smoothstep(0.0, 0.6, -dot(N.xz, V.xz / max(length(V.xz), 1e-4)));',
          '  vec3 fwd = uSunCol * ph * (0.02 + 0.35 * back + 0.3 * vTop) * mix(0.25, 1.0, shade);',
          '  float sky = clamp(Ns.y * 0.8 + 0.2, 0.0, 1.0);',
          '  vec3 amb = mix(uAmbLo, uAmbHi, sky) * mix(0.45, 1.1, vTop);',
          '  vec3 col = uAlbedo * (direct * 0.4 + amb) + fwd * 0.6;',
          '  col = fo_fog(col, vWorld);',
          '  gl_FragColor = vec4(col, 1.0);',
          '}',
        ].join('\n'),
      });
      if (!high) cloudMat.defines.FO_LOW = 1;
      var clouds = new THREE.Mesh(cloudGeo, cloudMat);
      clouds.frustumCulled = false;
      clouds.renderOrder = 1;
      scene.add(clouds);

      // ---------------------------------------------------------------- the summit, rocks, spruces
      var gp = [], gn = [], gu = [], gi = [];
      var GX = high ? 110 : 80, GZ = high ? 90 : 64;
      for (var gz = 0; gz <= GZ; gz++) {
        var zz = 14 - 90 * Math.pow(gz / GZ, 1.15);
        for (var gx = 0; gx <= GX; gx++) {
          var xx = -80 + 160 * gx / GX;
          gp.push(xx, ridgeY(xx, zz), zz);
          gn.push(0, 1, 0);
          gu.push(xx, zz);
        }
      }
      for (var ga = 0; ga < GZ; ga++) {
        for (var gb = 0; gb < GX; gb++) {
          var g0 = ga * (GX + 1) + gb, g1 = g0 + GX + 1;
          gi.push(g0, g0 + 1, g1, g0 + 1, g1 + 1, g1);
        }
      }
      var ridgeGeo = geometry(gp, gn, gu, gi);
      ridgeGeo.computeVertexNormals();
      // the low sun skims the summit: march its relief toward the sun once (the sun stands still)
      var sunVis = new Float32Array(gp.length / 3);
      var sdx = sunDir.x / Math.hypot(sunDir.x, sunDir.z), sdz = sunDir.z / Math.hypot(sunDir.x, sunDir.z);
      var rise = sunDir.y / Math.hypot(sunDir.x, sunDir.z);
      for (var vi = 0; vi < sunVis.length; vi++) {
        var vx = gp[vi * 3], vy = gp[vi * 3 + 1] + 0.05, vz = gp[vi * 3 + 2], vis = 1;
        for (var st = 1; st <= 24; st++) {
          var dd = 0.35 * st * st;
          var over = ridgeY(vx + sdx * dd, vz + sdz * dd) - (vy + dd * rise);
          vis = Math.min(vis, Math.max(0, Math.min(1, 1 - over / (0.15 + dd * 0.02))));
          if (vis <= 0) break;
        }
        sunVis[vi] = vis;
      }
      ridgeGeo.setAttribute('aSun', new THREE.Float32BufferAttribute(sunVis, 1));
      var ridgeMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.95, metalness: 0 }, {
        key: 'ridge',
        drySpecular: 0.25,
        vertexPars: 'attribute float aSun; varying float vSun;',
        vertex: 'vSun = aSun;',
        fragmentPars: 'varying float vSun;',
        // (the summit stays a dark foreground: only its crests catch a little of the sun)
        lightEnd: 'reflectedLight.directDiffuse *= vSun * 0.5; reflectedLight.directSpecular *= vSun * 0.5;',
        color: [
          'vec3 mnN = normalize(cross(dFdx(vFoWorld), dFdy(vFoWorld)));',
          'float mnA = texture2D(uNoiseTex, vFoWorld.xz * 0.05).r;',
          'float mnB = texture2D(uNoiseTex, vFoWorld.xz * 0.31).b;',
          'float mnC = texture2D(uNoiseTex, vFoWorld.xz * 0.11 + vFoWorld.y * 0.05).a;',
          'vec3 mnRock = mix(vec3(0.018, 0.017, 0.02), vec3(0.05, 0.045, 0.046), mnB * 0.6 + mnA * 0.4) * mix(0.65, 1.0, smoothstep(0.05, 0.3, mnC));',
          'vec3 mnGrass = mix(vec3(0.016, 0.018, 0.009), vec3(0.045, 0.04, 0.02), mnB) * (0.75 + 0.5 * texture2D(uNoiseTex, vFoWorld.xz * 1.7).g);',
          'float mnG = smoothstep(0.55, 0.85, mnN.y + (mnA - 0.5) * 0.6);',
          'diffuseColor.rgb = mix(mnRock, mnGrass, mnG);',
        ].join('\n'),
        normal: 'normal = fo_bump(normal, -vViewPosition, mnB * 0.6 + mnC * 0.4, 0.05 * smoothstep(60.0, 5.0, length(vViewPosition)));',
      });
      var ridge = new THREE.Mesh(ridgeGeo, ridgeMat);
      ridge.receiveShadow = false;
      scene.add(ridge);

      var stoneMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 }, {
        key: 'stone',
        drySpecular: 0.25,
        color: [
          'float mnS1 = texture2D(uNoiseTex, vFoWorld.xz * 0.4 + vFoWorld.y * 0.2).g;',
          'float mnS2 = texture2D(uNoiseTex, vFoWorld.xy * 0.8 + vFoWorld.z * 0.3).b;',
          'diffuseColor.rgb = mix(vec3(0.05, 0.047, 0.05), vec3(0.14, 0.13, 0.12), mnS1 * 0.6 + mnS2 * 0.4);',
          'diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.2, 0.2, 0.17), smoothstep(0.66, 0.8, mnS2) * 0.6);',
        ].join('\n'),
        normal: 'normal = fo_bump(normal, -vViewPosition, mnS2 * 0.6 + mnS1 * 0.4, 0.04 * smoothstep(40.0, 3.0, length(vViewPosition)));',
      });
      var sr = ctx.rng('rocks');
      [[-3.5, -17, 1.5, 0.9], [3.2, -22, 1.2, 0.8], [7.0, -13, 0.9, 0.6], [-7.0, -11, 0.8, 0.5], [1.0, -9, 0.5, 0.35],
        [-1.2, -26, 1.8, 1.2], [5.6, -27, 1.4, 1.0], [-11.5, -27, 2.2, 1.4]].forEach(function (s) {
        var m = new THREE.Mesh(stoneGeometry(sr, 2, [s[2], s[3], s[2] * 0.85], 6), stoneMat);
        m.position.set(s[0], ridgeY(s[0], s[1]) - 0.15 * s[3], s[1]);
        m.rotation.set((sr() - 0.5) * 0.2, sr() * TAU, (sr() - 0.5) * 0.2);
        scene.add(m);
      });

      // a few spruces at the edge, dark against the clouds, their needles lit at the rims
      var barkMat = pbr(THREE.MeshStandardMaterial, { color: lin('#140f0c'), roughness: 0.9, metalness: 0 }, { key: 'bark' });
      var needleMat = pbr(THREE.MeshStandardMaterial, {
        color: lin('#121c14'), roughness: 0.85, metalness: 0, map: sprayTex, alphaTest: 0.5,
        alphaToCoverage: high, side: THREE.DoubleSide, vertexColors: true,
      }, {
        key: 'needles',
        map: [
          'vec4 foTx = texture2D(map, vMapUv);',
          'diffuseColor.rgb *= mix(vec3(0.78, 0.92, 0.88), vec3(1.05, 1.08, 0.86), foTx.g) * mix(0.55, 1.2, foTx.r);',
          'diffuseColor.a *= foTx.a;',
        ].join('\n'),
        light: translucency(0.35, [0.95, 1.0, 0.7]),
        drySpecular: 0.15,
      });
      var trunkGeo = trunkGeometry(6, [-1, 0, 1.2, 3.2, 7, 12, TREE_H]);
      var crownGeo = crownGeometry(ctx.rng('crown'));
      var TREES = [[-7.4, -27.5, 1.05, 0.2], [-5.0, -30.0, 0.78, 1.6], [-9.6, -24.5, 1.2, 2.7], [3.6, -29.0, 0.7, 4.1], [-3.2, -31.5, 0.5, 0.9]];
      var trunks = new THREE.InstancedMesh(trunkGeo, barkMat, TREES.length);
      var crowns = new THREE.InstancedMesh(crownGeo, needleMat, TREES.length);
      var dummy = new THREE.Matrix4(), qq = new THREE.Quaternion(), e3 = new THREE.Vector3(), sv = new THREE.Vector3();
      TREES.forEach(function (t, i) {
        qq.setFromAxisAngle(new THREE.Vector3(0, 1, 0), t[3]);
        var m = dummy.compose(e3.set(t[0], ridgeY(t[0], t[1]) - 0.3, t[1]), qq, sv.set(t[2], t[2], t[2])).clone();
        trunks.setMatrixAt(i, m);
        crowns.setMatrixAt(i, m);
      });
      [trunks, crowns].forEach(function (o) { o.frustumCulled = false; scene.add(o); });

      // ---------------------------------------------------------------- finish
      var post = ctx.post({
        exposure: 0.72,
        toneMapping: 'aces',
        bloom: { strength: 0.22, threshold: 1.2, knee: 0.8, radius: 1.0 },
        rays: { strength: 0.3, length: 0.4, decay: 0.93, radius: 0.35 },
        aberration: 0.004,
        vignette: 0.36,
        grain: ctx.record ? 0 : 0.02,
      });

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function levelOnly(object, extra) {
        object.visible = false;
        return { object: object, setLevel: function (v) { if (extra) extra(v); } };
      }
      function hex(c) { return '#' + c.getHexString(); }
      var birds = D['oiseaux-vol'](ctx, {
        size: 1.7, color: '#000000', fog: '#000000', fogDensity: 0.004,
        flocks: [
          { count: 7, x0: -90, x1: 90, y: 70, z: -95, spacing: 1.7, phase: 0.1, size: 1.1, dir: 1 },
          { count: 5, x0: -120, x1: 120, y: 79, z: -150, spacing: 2.1, phase: 0.62, size: 1.3, dir: -1 },
        ],
        soaring: [
          { count: 3, x: -22, y: 68, z: -70, dx: 8, dy: 3, dz: 8, radius: [5, 8], size: 1.0, turns: 1 },
        ],
      });
      birds.object.material.uniforms.uColor.value.copy(lin('#1a1520')).multiplyScalar(0.25);
      birds.object.material.uniforms.uFog.value.copy(lin('#c9a0a0')).multiplyScalar(0.9);
      var sunFar = sunDir.clone().multiplyScalar(9000);
      var rays = D['rayons-soleil'](ctx, {
        origin: [sunFar.x, sunFar.y, sunFar.z], toward: [sunFar.x + 2000, sunFar.y + 6000, sunFar.z + 3300],
        spread: 0.95, count: 11, length: 9500, width: [60, 900], color: hex(lin('#ffcf9e')), intensity: 0.1, falloff: 0.9,
        motes: 0, spreadAxis: [0, 0, 1],
        onLevel: function (v) { post.uniforms.uRays.value.x = 0.18 + 0.55 * v; },
      });
      var stars = D.etoiles(ctx, {
        count: high ? 700 : 450, radius: 19000, azimuth: [0, 40], elevation: [26, 85], size: 0.9, brightness: 2.2,
        tint: ['#cfe0ff', '#f6efe0'],
      });
      var meteors = D['etoiles-filantes'](ctx, { radius: 18000, azimuth: [12, 26], elevation: [38, 70] });
      meteors.object.material.uniforms.uColor.value.multiplyScalar(2.5);
      var mistLevel = 0;
      function applyMist(v) {
        mistLevel = v;
        var low = high ? 1 : 0.8;
        shared.uFog.value.x = fogBase.density * (1 + 0.4 * v) * low;
        shared.uFog.value.y = fogBase.ground * (1 + 0.6 * v) * low;
        shared.uFog.value.w = (0.25 + 0.9 * v) * low;
      }
      var decors = {
        'oiseaux-vol': birds,
        etoiles: stars,
        'etoiles-filantes': meteors,
        brume: levelOnly(new THREE.Group(), applyMist),
        'rayons-soleil': rays,
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });
      applyMist(0);

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = t / ctx.PERIOD * TAU;
        camera.position.set(CAM[0] + 0.6 * Math.sin(T), CAM[1] + 0.08 * Math.sin(2 * T + 0.4), CAM[2] + 0.5 * Math.cos(T) - 0.5);
        camera.lookAt(LOOK[0] + 14 * Math.sin(T + 0.6), LOOK[1] + 3 * Math.sin(T), LOOK[2]);
      }
      update(0);
      var sunScreen = new THREE.Vector3();

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
          sunScreen.copy(sunDir).multiplyScalar(5000).add(camera.position).project(camera);
          post.setLight(sunScreen.x * 0.5 + 0.5, sunScreen.y * 0.5 + 0.5);
          post.render(scene, camera);
        },
        setQuality: function (q) {
          quality = q;
          high = q === 'high';
          post.setQuality(q);
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
          if (high) delete cloudMat.defines.FO_LOW; else cloudMat.defines.FO_LOW = 1;
          cloudMat.needsUpdate = true;
          shared.uShadowMap.value = shadowPlaceholder;
          primeShadows();
          applyMist(mistLevel);
        },
        describe: function () {
          var d = post.describe();
          d.shadowMap = sun.shadow.mapSize.x;
          d.cloudVertices = (FAN_R + 1) * (FAN_A + 1);
          return d;
        },
        dispose: function () {
          post.dispose();
          textures.forEach(function (t) { t.dispose(); });
          sun.dispose();
        },
      };
    },
  });
})();
