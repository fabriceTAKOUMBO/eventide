/*
 * « Forêt aux lucioles » (free), version 2: a path through a spruce forest on a misty night, the
 * moon low behind the trees. A real 3D forest lit by physically based materials and drawn with
 * the HDR finish of post.js (bloom, tone mapping, grain).
 *
 *   - Spruces: three shapes, each at three levels of detail (instanced): a tapered trunk with
 *     root flare and procedural bark, and crowns of drooping branch cards (needle sprays drawn
 *     once in JS into a texture whose mipmaps keep their coverage), lit with translucency.
 *   - Forest floor: needle litter, moss, a trodden path (puddles under rain), ferns, mossy rocks
 *     and mounds, a fallen trunk, twigs; occlusion under the trees from a small baked map.
 *   - Moonlight: one directional light with a shadow map, also sampled by the mist and the light
 *     rain, so that the lit patches of mist and of rain follow the real gaps of the canopy; rays of
 *     light from the moon through the trees in the finish (post.js).
 *   - Air: exponential height fog with a moon-lit forward-scattering lobe, plus a band of ground
 *     mist integrated analytically in every shader (no slices, so no lines where it meets a
 *     trunk); drifting motes near the camera.
 *   - The camera drifts on a closed path (one turn per 30 s): real parallax between the layers.
 * Everything that moves is a function of the scene time t (modulo 30 s): the period loops.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;
  var TAU = Math.PI * 2;

  // ------------------------------------------------------------------ layout
  var TREE_H = 22;           // reference height of the tree geometries (instances scale it)

  function pathX(z) {
    var s = 8 - z;
    return 0.8 * Math.sin(s * 0.05) + 0.35 * (Math.sin(s * 0.11 + 0.3) - Math.sin(0.3));
  }
  function pathHalf(z) {
    return 1.05 + Math.max(0, 8 - z) * 0.012;
  }
  // half-width of the corridor kept free of trunks along the path
  function clearHalf(z) {
    return Math.min(6, 2.2 + Math.max(0, 8 - z) * 0.06);
  }
  function groundY(x, z) {
    var h = 0.22 * Math.sin(0.19 * x + 0.11 * z + 0.7) + 0.16 * Math.sin(-0.13 * x + 0.23 * z + 1.9)
      + 0.06 * Math.sin(0.5 * x - 0.37 * z);
    var dp = (x - pathX(z)) / pathHalf(z);
    h -= 0.07 * Math.exp(-dp * dp * 1.5);
    h += Math.max(0, Math.abs(x) - 14) * 0.03;
    // the forest floor rises far away: the trees on it close the view (no flat horizon line)
    h += Math.max(0, -60 - z) * 0.035;
    return h;
  }

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
  // RGBA bytes (R shade, G tint, A coverage) with mipmaps that keep the alpha-tested coverage
  // (each level's alpha is scaled so that as many texels pass 0.5 as in level 0).
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

  // Fern frond: rachis along x, narrow pinnae on both sides leaning toward the tip, each cut
  // into small rounded lobes (pinnules), with gaps between them.
  function frondTexture(rng) {
    var W = 256, H = 64, c = raster(W, H);
    var N = 21;
    for (var i = 0; i < N; i++) {
      var u = 0.05 + (i + 0.5) / N * 0.9;
      var env = Math.pow(Math.sin(Math.PI * Math.min(1, u * 0.97 + 0.03)), 0.65) * Math.min(1, 0.4 + u * 2.4);
      for (var side = -1; side <= 1; side += 2) {
        var x0 = (u + (side > 0 ? 0.012 : 0)) * W, y0 = H * 0.5;
        var ang = (64 + rng() * 8) * Math.PI / 180;
        var len = env * H * 0.48;
        var dx = Math.cos(ang), dy = side * Math.sin(ang);
        // pinna midrib
        stroke(c, x0, y0, x0 + dx * len, y0 + dy * len, 0.7, 0.35, 0.4, 0.5);
        // lobes alternating along the pinna
        var lobes = Math.max(3, Math.round(len / 2.6));
        for (var k = 0; k < lobes; k++) {
          var t = (k + 0.5) / lobes;
          var lw = Math.max(0.55, len * 0.06 * Math.pow(Math.sin(Math.PI * Math.min(1, t * 0.85 + 0.15)), 0.7));
          var px = x0 + dx * len * t, py = y0 + dy * len * t;
          for (var sd = -1; sd <= 1; sd += 2) {
            var la = Math.atan2(dy, dx) + sd * 1.0;
            var ll = lw * 2.1;
            stroke(c, px, py, px + Math.cos(la) * ll, py + Math.sin(la) * ll, lw, lw * 0.75,
              0.55 + 0.4 * t + (rng() - 0.5) * 0.1, 0.4 + rng() * 0.2);
          }
        }
      }
    }
    stroke(c, 1, H * 0.5, W - 2, H * 0.5, 1.3, 0.5, 0.3, 0.5);
    return coverageTexture(c);
  }

  // Fallen leaf (beech-like): pointed oval with a serrated edge, midrib and veins.
  function leafTexture() {
    var S = 64, c = raster(S, S);
    for (var y = 0; y < S; y++) {
      for (var x = 0; x < S; x++) {
        var u = (y + 0.5) / S, v = ((x + 0.5) / S - 0.5) * 2;
        var hw = 0.82 * Math.pow(Math.sin(Math.PI * Math.min(1, u * 1.08)), 0.75) * (1 - 0.2 * u) + 0.03 * Math.sin(u * Math.PI * 16);
        if (u < 0.1) hw = Math.max(hw, 0.06);
        var cov = Math.max(0, Math.min(1, (hw - Math.abs(v)) * S * 0.5 + 0.5));
        var i = y * S + x;
        var vein = Math.exp(-Math.pow(v * 9, 2)) * 0.25 + Math.exp(-Math.pow(((u - Math.abs(v) * 0.55) * 9) % 1 - 0.5, 2) * 60) * 0.1;
        c.a[i] = cov;
        c.s[i] = Math.max(0, 0.85 - vein + 0.1 * u);
        c.t[i] = 0.5;
      }
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

  // Tapered trunk with root flare and buttresses, slightly bent; uv: around (m), height (m).
  function trunkGeometry(radial, rings, withRoots) {
    var pos = [], nor = [], uv = [], idx = [];
    var R0 = 0.27;
    for (var j = 0; j < rings.length; j++) {
      var y = rings[j];
      var r = R0 * Math.pow(Math.max(0, 1 - y / TREE_H), 0.85) + 0.015;
      if (withRoots) r *= 1 + 0.55 * Math.exp(-Math.max(0, y) * 2.4);
      var bend = 0.12 * Math.sin(y * 0.21 + 0.5) * (y / TREE_H);
      for (var i = 0; i <= radial; i++) {
        var th = i / radial * TAU;
        var rr = r * (withRoots ? 1 + 0.16 * Math.exp(-Math.max(0, y) * 3.2) * Math.sin(5 * th + 0.7) : 1);
        var cx = Math.cos(th), sz = Math.sin(th);
        pos.push(bend + cx * rr, y, sz * rr);
        nor.push(cx, 0.08, sz);
        uv.push(i / radial * TAU * R0 * 1.4, y);
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

  // Crown of drooping branch cards (needle sprays). lod 0: a long branch is a row of sprays; 1: one
  // folded card a branch; 2: fewer, larger cards. Vertex colour: occlusion toward the trunk.
  var VARIANTS = [
    { base: 0.22, radius: 0.19, droop: 1.0, n: 6 },
    { base: 0.36, radius: 0.16, droop: 1.3, n: 5 },
    { base: 0.1, radius: 0.215, droop: 0.8, n: 6 },
  ];
  // tilt: the roll of the cards, so that they are not seen edge-on from below; fold: the droop of
  // their edges; sub: near trees build a long branch from sprays of this length (m)
  var LODS = [
    { spacing: 0.56, segs: 2, wide: 1.0, long: 1.0, n: 1.0, tilt: 0.25, fold: 0.22, sub: 1.35 },
    { spacing: 0.9, segs: 2, wide: 0.9, long: 1.06, n: 0.85, tilt: 0.45, fold: 0.25, sub: 0 },
    { spacing: 1.15, segs: 1, wide: 1.1, long: 1.1, n: 0.85, tilt: 0.6, fold: 0.2, sub: 0 },
  ];
  function crownGeometry(variant, lod, rng) {
    var V = VARIANTS[variant], L = LODS[lod];
    var pos = [], nor = [], uv = [], idx = [], col = [];
    var yb = TREE_H * V.base, top = TREE_H;
    var tiers = Math.floor((top - 0.4 - yb) / L.spacing);
    var n = Math.max(3, Math.round(V.n * L.n));
    // a branch card: `segs` rows along the branch, three vertices across (the edges droop by
    // `fold` of the width: a gable, not a flat plane)
    function card(root, dirx, dirz, len, width, pitch, tipDrop, roll, c, segs, fold) {
      var base = pos.length / 3;
      var sx = -dirz, sz = dirx;
      var cr = Math.cos(roll), sr = Math.sin(roll);
      // "down" of the card plane (perpendicular to the branch and to the across vector)
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
        pos.push(px - ox - dnx * fd, py - oy - dny * fd, pz - oz - dnz * fd, px, py, pz, px + ox - dnx * fd, py + oy - dny * fd, pz + oz - dnz * fd);
        nor.push(nx - sx * 0.35, ny, nz - sz * 0.35, nx, ny, nz, nx + sx * 0.35, ny, nz + sz * 0.35);
        uv.push(u, 0, u, 0.5, u, 1);
        var ao = (0.42 + 0.58 * Math.min(1, u / 0.8)) * (0.7 + 0.3 * c);
        col.push(ao * 0.9, ao * 0.9, ao * 0.9, ao, ao, ao, ao * 0.9, ao * 0.9, ao * 0.9);
      }
      for (var k = 0; k < segs; k++) {
        var p = base + k * 3;
        idx.push(p, p + 3, p + 1, p + 1, p + 3, p + 4, p + 1, p + 4, p + 2, p + 2, p + 4, p + 5);
      }
    }
    for (var t = 0; t < tiers; t++) {
      var y = yb + (t + rng() * 0.6) * L.spacing;
      var c = (y - yb) / (top - yb);
      var len = (V.radius * TREE_H * Math.pow(1 - c, 0.85) + 0.2) * L.long;
      var rot = t * 2.39996 + rng() * 0.5;
      for (var j = 0; j < n; j++) {
        var th = rot + j / n * TAU + (rng() - 0.5) * 0.5;
        var dirx = Math.cos(th), dirz = Math.sin(th);
        var l = len * (0.82 + rng() * 0.32);
        var pitch = (-0.5 + 0.72 * c) * V.droop + (rng() - 0.5) * 0.2;
        var drop = 0.22 * V.droop * (1 - c) + 0.05;
        var trunkR = 0.27 * Math.pow(1 - y / TREE_H, 0.85) * 0.6;
        var roll = (j % 2 ? 1 : -1) * L.tilt + (rng() - 0.5) * 0.4;
        var root = [dirx * trunkR, y, dirz * trunkR];
        if (!L.sub || l < L.sub * 1.3) {
          card(root, dirx, dirz, l, l * 0.55 * L.wide + 0.12, pitch, drop, roll, c, L.segs, L.fold);
          continue;
        }
        // a long branch: sprays of about L.sub metres along it, alternating left and right of
        // the branch line, the last one at the tip
        var nSub = Math.ceil(l / L.sub);
        for (var k = 0; k < nSub; k++) {
          var f0 = k / nSub;
          var hd = f0 * l * Math.cos(pitch), vd = f0 * l * Math.sin(pitch) - drop * l * f0 * f0;
          var yaw = k === nSub - 1 ? 0 : (k % 2 ? 1 : -1) * (0.35 + rng() * 0.25);
          var cy = Math.cos(yaw), sy = Math.sin(yaw);
          var ddx = dirx * cy - dirz * sy, ddz = dirx * sy + dirz * cy;
          var ls = Math.min(l * (1 - f0) + 0.15, L.sub * (1.05 + rng() * 0.3));
          var lp = pitch - 2 * drop * f0 * 0.6;
          card([root[0] + dirx * hd, root[1] + vd, root[2] + dirz * hd], ddx, ddz, ls, ls * 0.62 * L.wide + 0.1, lp,
            drop * 0.5, roll + (rng() - 0.5) * 0.6, c, L.segs, L.fold);
        }
      }
    }
    // leader: two crossed vertical cards at the top
    for (var q = 0; q < 2; q++) {
      var a = q * Math.PI / 2;
      var b0 = pos.length / 3, ca = Math.cos(a) * 0.32, sa = Math.sin(a) * 0.32;
      pos.push(-ca, top - 1.3, -sa, ca, top - 1.3, sa, -ca * 0.3, top + 0.3, -sa * 0.3, ca * 0.3, top + 0.3, sa * 0.3);
      for (var e = 0; e < 4; e++) nor.push(0, 1, 0);
      uv.push(0.15, 0, 0.15, 1, 0.95, 0, 0.95, 1);
      col.push(0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9);
      idx.push(b0, b0 + 2, b0 + 1, b0 + 1, b0 + 2, b0 + 3);
    }
    return geometry(pos, nor, uv, idx, col);
  }

  // One fern: a rosette of arching fronds (uv.x along the frond).
  function fernGeometry(rng, fronds) {
    var pos = [], nor = [], uv = [], idx = [], col = [];
    var segs = 7;
    for (var f = 0; f < fronds; f++) {
      var th = f / fronds * TAU + (rng() - 0.5) * 0.6;
      var dx = Math.cos(th), dz = Math.sin(th), sx = -dz, sz = dx;
      var len = 0.55 + rng() * 0.45, width = len * 0.42;
      var p0 = 1.05 + rng() * 0.25;
      var base = pos.length / 3, px = dx * 0.04, py = 0, pz = dz * 0.04;
      for (var s = 0; s <= segs; s++) {
        var u = s / segs;
        if (s > 0) {
          var pitch = p0 - (p0 + 0.65) * Math.pow(u, 1.25);
          px += dx * Math.cos(pitch) * len / segs;
          pz += dz * Math.cos(pitch) * len / segs;
          py += Math.sin(pitch) * len / segs;
        }
        var roll = 0.25 * u * (f % 2 ? 1 : -1);
        var w = width * 0.5 * (s === 0 ? 0.3 : 1);
        var ox = sx * Math.cos(roll) * w, oy = Math.sin(roll) * w, oz = sz * Math.cos(roll) * w;
        pos.push(px - ox, py - oy, pz - oz, px + ox, py + oy, pz + oz);
        var nx = dx * 0.35, ny = 0.9, nz = dz * 0.35, nl = Math.hypot(nx, ny, nz);
        nor.push(nx / nl, ny / nl, nz / nl, nx / nl, ny / nl, nz / nl);
        uv.push(u, 0, u, 1);
        var ao = 0.45 + 0.55 * u;
        col.push(ao, ao, ao, ao, ao, ao);
      }
      for (var k = 0; k < segs; k++) {
        var p = base + k * 2;
        idx.push(p, p + 2, p + 1, p + 1, p + 2, p + 3);
      }
    }
    return geometry(pos, nor, uv, idx, col);
  }

  // Boulder: a displaced icosphere with a few planar cuts, flat underneath.
  function rockGeometry(rng) {
    var g = new THREE.IcosahedronGeometry(1, 3);
    var p = g.attributes.position;
    var planes = [];
    for (var k = 0; k < 8; k++) {
      var th = rng() * TAU, el = (rng() - 0.25) * 1.3;
      planes.push([Math.cos(th) * Math.cos(el), Math.sin(el), Math.sin(th) * Math.cos(el), 0.66 + rng() * 0.22]);
    }
    var v = new THREE.Vector3();
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var n = 0.16 * Math.sin(v.x * 3.1 + 1.3) * Math.sin(v.y * 2.7 + 0.4) * Math.sin(v.z * 3.3 + 2.1)
        + 0.07 * Math.sin(v.x * 7.1 + v.z * 5.3) + 0.05 * Math.sin(v.y * 9.0 + v.x * 6.1)
        + 0.025 * Math.sin(v.x * 17.0 + v.y * 13.0) * Math.sin(v.z * 15.0 - v.y * 11.0);
      v.multiplyScalar(1 + n);
      planes.forEach(function (pl) {
        var d = v.x * pl[0] + v.y * pl[1] + v.z * pl[2];
        if (d > pl[3]) v.addScaledVector(new THREE.Vector3(pl[0], pl[1], pl[2]), pl[3] - d);
      });
      if (v.y < -0.3) v.y = -0.3 + (v.y + 0.3) * 0.2;
      p.setXYZ(i, v.x * 1.25, v.y * 0.72, v.z);
    }
    g = mergeVertices(g);
    g.computeVertexNormals();
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

  // Moss mound: a low lumpy dome.
  function moundGeometry() {
    var g = new THREE.SphereGeometry(1, 14, 7, 0, TAU, 0, Math.PI / 2);
    var p = g.attributes.position, v = new THREE.Vector3();
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var n = 1 + 0.12 * Math.sin(v.x * 6.0 + 1.0) * Math.sin(v.z * 5.0) + 0.08 * Math.sin(v.x * 11.0 + v.z * 9.0);
      p.setXYZ(i, v.x * n, v.y * n - 0.05, v.z * n);
    }
    g.computeVertexNormals();
    return g;
  }

  // A tube along a polyline of [x, y, z, radius] (log, twigs); uv: around (m), along (m).
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
        uv.push(i / radial * TAU * p[3] * 1.4, along);
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

  // ------------------------------------------------------------------ shared GLSL
  // Fog, ground mist, moon shadow lookups. Written for both the patched three.js materials and
  // the scene's ShaderMaterials (which already have uTime, EV_PERIOD, EV_TAU).
  var FO_GLSL = [
    'uniform vec3 uMoonDir; uniform vec3 uMoonFog; uniform vec3 uFogAmb;',
    'uniform vec4 uFog;',        // base density, ground density, height falloff, mist level
    'uniform vec4 uMist;',       // band height, band width, band density, noise scale
    'uniform sampler2D uNoiseTex;',
    'uniform sampler2DShadow uShadowMap; uniform mat4 uShadowMatrix; uniform float uShadowReady;',
    'float fo_phase(float c) {',
    '  float a = 0.3276 / pow(1.6724 - 1.64 * c, 1.5);',
    '  float b = 0.8775 / pow(1.1225 - 0.7 * c, 1.5);',
    '  return (0.78 * a + 0.22 * b) * 0.0796;',
    '}',
    'float fo_shadow(vec3 wp) {',
    '  vec4 sc = uShadowMatrix * vec4(wp, 1.0);',
    '  sc.xyz /= sc.w;',
    '  if (uShadowReady < 0.5 || sc.x < 0.0 || sc.x > 1.0 || sc.y < 0.0 || sc.y > 1.0 || sc.z > 1.0) return 1.0;',
    '  return texture(uShadowMap, vec3(sc.xy, sc.z - 0.002));',
    '}',
    'vec2 fo_weights(float t) { float s = sin(3.14159265 * t / EV_PERIOD); return vec2(s * s, 1.0 - s * s); }',
    // noise drifting over the period and looping (two copies half a period apart, sin^2 weights)
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
    '  float a = k * dy * L;',
    '  return exp(-k * y0) * (abs(a) > 1e-3 ? (1.0 - exp(-a)) / (k * dy) : L);',
    '}',
    // optical depth of the ground-mist band (Lorentzian profile) along the segment
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
    '  float ph = fo_phase(dot(dir, uMoonDir));',
    '  float od = uFog.x * L + uFog.y * fo_heightOD(cameraPosition.y, dir.y, L);',
    '  float T = exp(-od);',
    '  vec3 haze = uFogAmb + uMoonFog * ph * mix(0.25, 1.0, smoothstep(3.0, 45.0, L));',
    '  col = col * T + haze * (1.0 - T);',
    '  float odm = fo_bandOD(cameraPosition.y, dir.y, L) * uMist.z * uFog.w;',
    '  if (odm > 0.004) {',
    // plain mist (its mean) for 'low' and for the rays that look up (they only cross the band
    // next to the camera); drifting and lit by the moon through the canopy for those looking down
    // (shadowed near the camera, lit far away: at the horizon it meets the sky's mist exactly)
    '    vec3 mist = uFogAmb * 1.3 + uMoonFog * ph * mix(0.35, 1.22, smoothstep(12.0, 90.0, L));',
    '#ifdef FO_LOW',
    '    odm *= 0.5;',
    '#else',
    '    float down = smoothstep(-0.01, -0.12, dir.y);',   // a soft hand-over near the horizon
    '    if (down > 0.0) {',
    '      vec3 pc = cameraPosition + dir * clamp((uMist.x - cameraPosition.y) / dir.y, 0.0, L);',
    '      float n = fo_loopNoise(pc.xz * uMist.w, vec2(0.0045, 0.0018));',
    '      odm *= mix(0.5, 0.08 + 2.6 * n * n * n, down);',
    '      mist = mix(mist, uFogAmb * 1.3 + uMoonFog * ph * (0.12 + 1.1 * fo_shadow(pc + vec3(0.0, 0.3, 0.0))), down);',
    '    } else {',
    '      odm *= 0.5;',
    '    }',
    '#endif',
    '    float Tm = exp(-odm);',
    '    col = col * Tm + mist * (1.0 - Tm);',
    '  }',
    '  return col;',
    '}',
    // the same air for the sky (a ray to infinity): the height fog and the mist band to the top of
    // their layers, the uniform haze over a bounded distance, the mist lit (no canopy far away)
    'vec3 fo_skyFog(vec3 col, vec3 dir) {',
    '  float ph = fo_phase(dot(dir, uMoonDir));',
    '  float od = uFog.x * 220.0 + uFog.y * fo_heightOD(cameraPosition.y, dir.y, 2000.0);',
    '  float T = exp(-od);',
    '  col = col * T + (uFogAmb + uMoonFog * ph) * (1.0 - T);',
    '  float Tm = exp(-fo_bandOD(cameraPosition.y, dir.y, 2000.0) * uMist.z * uFog.w * 0.5);',
    '  return col * Tm + (uFogAmb * 1.3 + uMoonFog * ph * 1.22) * (1.0 - Tm);',
    '}',
    // transmittance only (emissive points)
    'float fo_trans(vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = max(length(d), 1e-3);',
    '  vec3 dir = d / L;',
    '  float od = uFog.x * L + uFog.y * fo_heightOD(cameraPosition.y, dir.y, L) + fo_bandOD(cameraPosition.y, dir.y, L) * uMist.z * uFog.w;',
    '  return exp(-od);',
    '}',
  ].join('\n');

  // Bump from a procedural height h (Mikkelsen's surface gradient), view space.
  var BUMP_GLSL = [
    'vec3 fo_bump(vec3 n, vec3 surf, float h, float scale) {',
    '  vec3 dpdx = dFdx(surf), dpdy = dFdy(surf);',
    '  float dhdx = dFdx(h), dhdy = dFdy(h);',
    '  vec3 r1 = cross(dpdy, n), r2 = cross(n, dpdx);',
    '  float det = dot(dpdx, r1);',
    '  vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2);',
    // (a sliver of a pixel, e.g. a twig seen edge-on, has no usable derivatives: keep n)
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

  // Light through thin leaves and needles, seen against the moon (after the direct lights).
  function translucency(amount, tint) {
    return [
      '#if NUM_DIR_LIGHTS > 0',
      '{',
      '  float foBack = saturate(dot(-geometryViewDir, directLight.direction));',
      '  float foThin = pow(foBack, 4.0) * 0.85 + 0.15 * saturate(dot(-geometryNormal, directLight.direction));',
      '  reflectedLight.directDiffuse += directLight.color * material.diffuseColor * vec3(' + tint.join(', ') + ') * (' + amount + ' * foThin);',
      '}',
      '#endif',
    ].join('\n');
  }

  // ------------------------------------------------------------------ scene
  E.register({
    id: 'foret-lucioles',
    decors: ['lucioles', 'brume', 'pluie', 'etoiles'],
    defaults: { lucioles: 60, brume: 30 },
    post: true,

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera, renderer = ctx.renderer;
      var quality = ctx.quality;
      var rng = ctx.rng('v2');
      camera.fov = 52;
      camera.near = 0.1;
      camera.far = 1200;
      var camY = groundY(0, 7.5) + 1.45;

      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFShadowMap;

      var moonDir = new THREE.Vector3(0.05, 0.285, -0.957).normalize();
      var noiseTex = noiseTexture(ctx.rng('noise'));
      var sprayTex = sprayTexture(ctx.rng('spray'));
      var frondTex = frondTexture(ctx.rng('frond'));
      var leafTex = leafTexture();
      var textures = [noiseTex, sprayTex, frondTex, leafTex];

      var shared = {
        uTime: ctx.uniforms.uTime,
        uMoonDir: { value: moonDir },
        uMoonFog: { value: new THREE.Vector3(0.125, 0.165, 0.245) },
        uFogAmb: { value: new THREE.Vector3(0.009, 0.019, 0.042) },
        uFog: { value: new THREE.Vector4(0.006, 0.03, 0.45, 0.3) },
        uMist: { value: new THREE.Vector4(0.6, 1.1, 0.13, 0.045) },
        uNoiseTex: { value: noiseTex },
        uShadowMap: { value: null },   // a placeholder depth texture until the real map exists
        uShadowMatrix: { value: new THREE.Matrix4() },
        uShadowReady: { value: 0 },
        uWet: { value: 0 },            // follows the rain level
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
          m.envMapIntensity = 0.35 * hooks.env;
        }
        m.onBeforeCompile = function (shader) {
          Object.keys(shared).forEach(function (k) { shader.uniforms[k] = shared[k]; });
          Object.assign(shader.uniforms, hooks.uniforms || {});
          var head = 'varying vec3 vFoWorld;\nvarying vec2 vFoUv;\nuniform float uTime;\nuniform float uWet;\n#define EV_PERIOD 30.0\n#define EV_TAU 6.28318530718\n';
          var vs = shader.vertexShader
            .replace('#include <common>', '#include <common>\n' + head + (hooks.vertexPars || ''))
            .replace('#include <beginnormal_vertex>', '#include <beginnormal_vertex>\n' + (hooks.normalVertex || ''))
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
              // dry organic surfaces (litter, bark, needles, stone) do not shine at grazing angles
              // the way the GGX lobe alone would: damp the direct specular unless wet
              'reflectedLight.directSpecular *= mix(' + (hooks.drySpecular !== undefined ? hooks.drySpecular : 0.2).toFixed(3) + ', 0.45, uWet);\n' +
              (hooks.lightEnd || ''))
            .replace('#include <fog_fragment>', 'gl_FragColor.rgb = fo_fog(gl_FragColor.rgb, vFoWorld);');
          shader.vertexShader = vs;
          shader.fragmentShader = fs;
        };
        m.customProgramCacheKey = function () { return 'fo-' + hooks.key + '-' + quality; };
        patched.push(m);
        return m;
      }
      // texture with R = shade, G = tint, A = coverage (the sprays, fronds and leaves)
      function cardMap(tintA, tintB, shadeLo, shadeHi) {
        return [
          'vec4 foTx = texture2D(map, vMapUv);',
          'diffuseColor.rgb *= mix(vec3(' + tintA.join(', ') + '), vec3(' + tintB.join(', ') + '), foTx.g) * mix(' + shadeLo + ', ' + shadeHi + ', foTx.r);',
          'diffuseColor.a *= foTx.a;',
        ].join('\n');
      }
      function cardMaterial(map, color, roughness, key, extra) {
        return pbr(THREE.MeshStandardMaterial, Object.assign({
          color: color, roughness: roughness, metalness: 0, map: map, alphaTest: 0.5,
          alphaToCoverage: quality === 'high', side: THREE.DoubleSide, vertexColors: true,
        }, extra && extra.params), Object.assign({ key: key }, extra && extra.hooks));
      }

      // ---------------------------------------------------------------- sky + environment
      var SKY_FRAGMENT = [
        'uniform vec3 uZenith; uniform vec3 uHorizon; uniform vec3 uMoonDisc; uniform float uEnv;',
        'varying vec3 vDir;',
        'void main() {',
        '  vec3 d = normalize(vDir);',
        '  float c = dot(d, uMoonDir);',
        '  vec3 col = mix(uHorizon, uZenith, smoothstep(-0.02, 0.55, d.y));',
        // high veils of cloud, silver near the moon
        '  vec2 p = d.xz / max(d.y + 0.25, 0.06) * 0.09;',
        '  float cl = fo_loopNoise(p + vec2(0.3, 0.1), vec2(0.0012, 0.0004));',
        '  float veil = smoothstep(0.42, 0.85, cl) * smoothstep(0.02, 0.25, d.y);',
        '  col += uMoonFog * veil * (0.05 + 1.3 * fo_phase(c));',
        '  col += uMoonFog * fo_phase(c) * 0.45;',
        '  if (uEnv < 0.5) {',
        '    float r = acos(clamp(c, -1.0, 1.0));',
        '    float disc = 1.0 - smoothstep(0.0118, 0.0128, r);',
        '    if (disc > 0.0) {',
        '      vec3 up = normalize(cross(cross(uMoonDir, vec3(0.0, 1.0, 0.0)), uMoonDir));',
        '      vec3 side = normalize(cross(uMoonDir, up));',
        '      vec2 q = vec2(dot(d, side), dot(d, up)) / 0.0125;',
        '      float maria = texture2D(uNoiseTex, q * 0.22 + 0.4).r;',
        '      float limb = sqrt(max(0.0, 1.0 - dot(q, q)));',
        '      vec3 moon = uMoonDisc * (0.55 + 0.45 * limb) * (1.0 - 0.32 * smoothstep(0.45, 0.75, maria));',
        '      col = mix(col, moon * (1.0 - veil * 0.5), disc);',
        '    }',
        '  }',
        '  col = fo_skyFog(col, d);',
        '  gl_FragColor = vec4(col, 1.0);',
        '}',
      ].join('\n');
      function skyMaterial(env) {
        return ctx.material({
          uniforms: Object.assign({}, shared, {
            uZenith: { value: lin('#03070f') },
            uHorizon: { value: lin('#14233a').multiplyScalar(0.6) },
            uMoonDisc: { value: lin('#f2f0e6').multiplyScalar(26) },
            uEnv: { value: env ? 1 : 0 },
          }),
          vertexShader: 'varying vec3 vDir;\nvoid main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
          fragmentShader: FO_GLSL + '\n' + SKY_FRAGMENT,
          side: THREE.BackSide,
          depthWrite: false,
        });
      }
      var sky = new THREE.Mesh(new THREE.SphereGeometry(900, 48, 24), skyMaterial(false));
      sky.renderOrder = 10;   // after the opaque scene: only the gaps are shaded
      sky.frustumCulled = false;
      scene.add(sky);

      var pmrem = new THREE.PMREMGenerator(renderer);
      var envScene = new THREE.Scene();
      var envSky = new THREE.Mesh(new THREE.SphereGeometry(50, 32, 16), skyMaterial(true));
      envScene.add(envSky);
      var envRT = pmrem.fromScene(envScene, 0.02, 0.1, 100, { size: 64 });
      // image-based light only where it shows (wet ground, stone, the log, moss, leaves): the
      // needles, ferns and trunks, which cover most of the screen, skip its cost
      envTexture = envRT.texture;
      patched.forEach(function (m) { if (m.userData.env) { m.envMap = envTexture; m.needsUpdate = true; } });
      envSky.geometry.dispose();
      envSky.material.dispose();
      pmrem.dispose();

      // ---------------------------------------------------------------- lights
      var moon = new THREE.DirectionalLight(lin('#c2cde0'), 6.0);
      var target = new THREE.Vector3(0, 0, -24);
      moon.target.position.copy(target);
      moon.position.copy(target).addScaledVector(moonDir, 160);
      moon.castShadow = true;
      var shadowSize = quality === 'high' ? 1024 : 512;
      moon.shadow.mapSize.set(shadowSize, shadowSize);
      var sc = moon.shadow.camera;
      sc.left = -26; sc.right = 26; sc.top = 30; sc.bottom = -16; sc.near = 40; sc.far = 320;
      moon.shadow.bias = -0.0006;
      moon.shadow.normalBias = 0.04;
      moon.shadow.radius = 2.5;
      scene.add(moon);
      scene.add(moon.target);
      var hemi = new THREE.HemisphereLight(lin('#33507a'), lin('#141812'), 0.5);
      scene.add(hemi);

      // ---------------------------------------------------------------- trees
      var trees = [];
      var grid = {};
      function cellKey(x, z) { return Math.floor(x / 6) + ':' + Math.floor(z / 6); }
      function minDist(z) { return 2.5 * (1 + Math.max(0, 8 - z) / 55); }
      function free(x, z, d) {
        var cx = Math.floor(x / 6), cz = Math.floor(z / 6);
        for (var a = -2; a <= 2; a++) {
          for (var b = -2; b <= 2; b++) {
            var list = grid[(cx + a) + ':' + (cz + b)];
            if (!list) continue;
            for (var i = 0; i < list.length; i++) {
              if (Math.hypot(list[i].x - x, list[i].z - z) < d) return false;
            }
          }
        }
        return true;
      }
      function addTree(x, z, s, variant) {
        var t = { x: x, z: z, y: groundY(x, z) - 0.12, s: s, variant: variant, rot: rng() * TAU, lean: (rng() - 0.5) * 0.04 };
        // crowns next to the corridor are narrower (the open side of the path stays open)
        var reach = VARIANTS[variant].radius * TREE_H * s;
        // (near the camera only: farther on, crowns overhang the path and cut the moonlight into
        // stripes across it)
        t.cs = Math.max(0.45, Math.min(1, (Math.abs(x - pathX(z)) - 0.35 * clearHalf(z)) / reach));
        t.cs += (1 - t.cs) * Math.max(0, Math.min(1, (-14 - z) / 12));
        t.d = Math.hypot(x, z - 7.5);
        t.lod = t.d < 24 ? 0 : t.d < 70 ? 1 : 2;
        trees.push(t);
        var k = cellKey(x, z);
        (grid[k] = grid[k] || []).push(t);
      }
      [[-1, 0.8, 1.25, 0], [1, -3.5, 1.1, 2], [-1, -10, 1.15, 0], [1, -16, 1.05, 1], [-1, -23, 1.0, 2]]
        .forEach(function (h) { addTree(pathX(h[1]) + h[0] * (clearHalf(h[1]) + 0.4), h[1], h[2], h[3]); });
      for (var attempt = 0; attempt < 14000; attempt++) {
        var z = 12 - rng() * 222;
        var W = Math.min(70, 7 + 0.42 * (8 - z));
        var x = (rng() * 2 - 1) * W;
        if (Math.abs(x - pathX(z)) < clearHalf(z)) continue;
        if (Math.hypot(x, z - 7.5) < 2.2) continue;
        if (!free(x, z, minDist(z))) continue;
        addTree(x, z, 0.78 + rng() * 0.5, Math.floor(rng() * 3));
      }
      trees.sort(function (a, b) { return a.d - b.d; });

      // bark: vertical plates (cells) split by fissures, lichen, moss at the foot; uv = (around, up) m
      var barkHooks = {
        key: 'bark',
        color: [
          'vec2 foB = vFoUv;',
          'float foPl = texture2D(uNoiseTex, foB * vec2(0.55, 0.11)).a;',
          'float foFis = smoothstep(0.08, 0.32, foPl);',
          'float foN = texture2D(uNoiseTex, foB * vec2(0.9, 0.35)).g;',
          'vec3 foBark = mix(vec3(0.030, 0.026, 0.023), vec3(0.085, 0.074, 0.064), foFis * (0.55 + 0.6 * foN));',
          'float foLichen = smoothstep(0.62, 0.8, texture2D(uNoiseTex, foB * vec2(0.4, 0.3) + 0.3).b);',
          'foBark = mix(foBark, vec3(0.10, 0.11, 0.095), foLichen * 0.55);',
          'float foMoss = smoothstep(0.9, -0.2, vFoUv.y) * smoothstep(0.35, 0.65, foN);',
          'diffuseColor.rgb = mix(foBark, vec3(0.022, 0.042, 0.014), foMoss);',
          'diffuseColor.rgb *= 1.0 - 0.35 * uWet;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.94, 0.7, uWet) - 0.1 * foFis;',
        normal: 'normal = fo_bump(normal, -vViewPosition, foFis * 0.6 + foN * 0.4, 0.018 * smoothstep(40.0, 8.0, length(vViewPosition)));',
      };
      var barkMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.92, metalness: 0 }, barkHooks);
      var needleTint = [[0.78, 0.92, 0.88], [1.05, 1.08, 0.86]];
      var needleMat = cardMaterial(sprayTex, lin('#1f2f22'), 0.9, 'needles', {
        hooks: {
          map: cardMap(needleTint[0], needleTint[1], 0.55, 1.2),
          light: translucency(0.55, [0.85, 1.0, 0.75]),
          lightEnd: 'reflectedLight.directSpecular *= mix(0.22, 0.12, uWet); reflectedLight.indirectSpecular *= mix(0.4, 0.5, uWet);',
          roughness: 'roughnessFactor = mix(roughnessFactor, 0.62, uWet);',
        },
      });

      var trunkGeos = [
        trunkGeometry(10, [-0.4, 0, 0.12, 0.35, 0.7, 1.2, 2.0, 3.2, 4.8, 7, 10, 13.5, 17, 20, 22], true),
        trunkGeometry(6, [-0.4, 0, 0.35, 1.2, 3.2, 7, 12, 17, 22], true),
        trunkGeometry(5, [-0.4, 0, 2.5, 8, 15, 22], false),
      ];
      var crownGeos = [[], [], []];
      for (var v = 0; v < 3; v++) {
        for (var l = 0; l < 3; l++) crownGeos[l].push(crownGeometry(v, l, ctx.rng('crown' + v + l)));
      }
      var dummy = new THREE.Matrix4(), q = new THREE.Quaternion(), e3 = new THREE.Vector3(), sv = new THREE.Vector3();
      var euler = new THREE.Euler();
      function treeMatrix(t, crown) {
        euler.set(t.lean, t.rot, t.lean * 0.7);
        q.setFromEuler(euler);
        var k = crown ? t.cs : 1;
        return dummy.compose(e3.set(t.x, t.y, t.z), q, sv.set(t.s * k, t.s * (0.95 + 0.1 * ((t.rot * 7) % 1)), t.s * k)).clone();
      }
      var counts = { trees: trees.length, lod: [0, 0, 0] };
      var lodLists = [0, 1, 2].map(function (l) { return trees.filter(function (t) { return t.lod === l; }); });
      lodLists.forEach(function (list, l) {
        counts.lod[l] = list.length;
        if (!list.length) return;
        var trunk = new THREE.InstancedMesh(trunkGeos[l], barkMat, list.length);
        list.forEach(function (t, i) { trunk.setMatrixAt(i, treeMatrix(t)); });
        trunk.castShadow = l < 2;
        trunk.receiveShadow = true;
        trunk.frustumCulled = false;
        scene.add(trunk);
        for (var vv = 0; vv < 3; vv++) {
          var sub = list.filter(function (t) { return t.variant === vv; });
          if (!sub.length) continue;
          var crown = new THREE.InstancedMesh(crownGeos[l][vv], needleMat, sub.length);
          sub.forEach(function (t, i) { crown.setMatrixAt(i, treeMatrix(t, true)); });
          crown.castShadow = l < 2;
          crown.receiveShadow = true;
          crown.frustumCulled = false;
          scene.add(crown);
        }
      });

      // ---------------------------------------------------------------- ground (+ baked map)
      // canopy map over the near forest: R occlusion at the foot of trunks, G canopy cover,
      // B path, A puddle (low spots of the path)
      var CM = { x0: -45, z0: -150, w: 90, d: 164, n: 256 };
      var cmData = new Uint8Array(CM.n * CM.n * 4);
      var occ = new Float32Array(CM.n * CM.n), cov = new Float32Array(CM.n * CM.n);
      var cellW = CM.w / CM.n, cellD = CM.d / CM.n;
      trees.forEach(function (t) {
        var rT = 0.5 * t.s + 0.6, rC = VARIANTS[t.variant].radius * TREE_H * t.s * 0.75;
        var R = Math.max(rT * 2, rC * 1.6);
        var i0 = Math.max(0, Math.floor((t.x - R - CM.x0) / cellW)), i1 = Math.min(CM.n - 1, Math.ceil((t.x + R - CM.x0) / cellW));
        var j0 = Math.max(0, Math.floor((t.z - R - CM.z0) / cellD)), j1 = Math.min(CM.n - 1, Math.ceil((t.z + R - CM.z0) / cellD));
        for (var j = j0; j <= j1; j++) {
          for (var i = i0; i <= i1; i++) {
            var x = CM.x0 + (i + 0.5) * cellW, z = CM.z0 + (j + 0.5) * cellD;
            var d = Math.hypot(x - t.x, z - t.z);
            occ[j * CM.n + i] += Math.exp(-Math.pow(d / rT, 2));
            cov[j * CM.n + i] += 0.55 * Math.exp(-Math.pow(d / rC, 2));
          }
        }
      });
      for (var j = 0; j < CM.n; j++) {
        for (var i = 0; i < CM.n; i++) {
          var x = CM.x0 + (i + 0.5) * cellW, z = CM.z0 + (j + 0.5) * cellD, k = j * CM.n + i;
          var dp = (x - pathX(z)) / pathHalf(z);
          var path = Math.exp(-Math.pow(dp, 4) * 1.2);
          var low = path * (0.5 + 0.5 * Math.sin(z * 0.9 + Math.sin(z * 0.37) * 2.0)) * (0.6 + 0.4 * Math.sin(x * 2.1 + z * 0.5));
          cmData[k * 4] = Math.round(Math.min(1, occ[k]) * 255);
          cmData[k * 4 + 1] = Math.round(Math.min(1, cov[k]) * 255);
          cmData[k * 4 + 2] = Math.round(path * 255);
          cmData[k * 4 + 3] = Math.round(Math.max(0, Math.min(1, low)) * 255);
        }
      }
      var canopyTex = dataTexture(cmData, CM.n, CM.n, {});
      textures.push(canopyTex);

      var gp = [], gn = [], gu = [], gi = [];
      var NX = 96, NZ = 130;
      for (var gz = 0; gz <= NZ; gz++) {
        var sz = gz / NZ;
        var zz = 14 - 234 * Math.pow(sz, 1.7);
        for (var gx = 0; gx <= NX; gx++) {
          var su = gx / NX * 2 - 1;
          var xx = 75 * Math.sign(su) * Math.pow(Math.abs(su), 1.6);
          gp.push(xx, groundY(xx, zz), zz);
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
      var ground = new THREE.Mesh(groundGeo, pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.95, metalness: 0 }, {
        key: 'ground',
        env: 1,
        uniforms: {
          uCanopy: { value: canopyTex },
          uCanopyBox: { value: new THREE.Vector4(CM.x0, CM.z0, CM.w, CM.d) },
        },
        fragmentPars: [
          'uniform sampler2D uCanopy; uniform vec4 uCanopyBox;',
          // rain rings in the puddles: drops at fixed times on a grid, each ring grows and fades
          'float fo_ripples(vec2 p) {',
          '  vec2 cell = floor(p * 2.2); vec2 f = fract(p * 2.2) - 0.5;',
          '  float h = 0.0;',
          '  for (int k = 0; k < 2; k++) {',
          '    float s = fract(sin(dot(cell + float(k) * 17.0, vec2(12.9898, 78.233))) * 43758.5453);',
          '    vec2 o = vec2(fract(s * 13.7), fract(s * 71.3)) - 0.5;',
          '    float ph = fract(uTime / EV_PERIOD * 12.0 + s);',
          '    float r = length(f - o * 0.6);',
          '    h += sin((r - ph * 0.45) * 60.0) * exp(-pow((r - ph * 0.45) * 14.0, 2.0)) * (1.0 - ph);',
          '  }',
          '  return h;',
          '}',
        ].join('\n'),
        color: [
          'vec2 foC = (vFoWorld.xz - uCanopyBox.xy) / uCanopyBox.zw;',
          'vec4 foCm = texture2D(uCanopy, foC);',
          'float foN1 = texture2D(uNoiseTex, vFoWorld.xz * 0.045).r;',
          'float foN2 = texture2D(uNoiseTex, vFoWorld.xz * 0.21).g;',
          'float foN3 = texture2D(uNoiseTex, vFoWorld.xz * 0.9).b;',
          // litter: clumps of needles (cells), fine grain, a few pale dead leaves and twigs
          'float foCell = texture2D(uNoiseTex, vFoWorld.xz * 0.55 + foN2 * 0.2).a;',
          'float foG1 = texture2D(uNoiseTex, vFoWorld.xz * 3.1).b;',
          'float foG2 = texture2D(uNoiseTex, vFoWorld.xz * 7.7 + 0.31).g;',
          'float foClump = smoothstep(0.62, 0.12, foCell);',
          'vec3 foLitter = mix(vec3(0.011, 0.009, 0.007), vec3(0.072, 0.050, 0.033), foClump * (0.35 + 0.65 * foG1));',
          'foLitter = mix(foLitter, vec3(0.10, 0.078, 0.055), smoothstep(0.74, 0.9, foG2) * smoothstep(0.3, 0.7, foN3));',
          'foLitter *= 0.8 + 0.4 * foN2;',
          'vec3 foMossC = mix(vec3(0.010, 0.022, 0.007), vec3(0.034, 0.058, 0.018), foG1);',
          'float foMossM = smoothstep(0.5, 0.72, foN1 + (1.0 - foCm.g) * 0.2 - foCm.b * 0.45 + foN2 * 0.15);',
          'vec3 foSoil = mix(vec3(0.030, 0.023, 0.017), vec3(0.070, 0.054, 0.040), foG1 * 0.5 + foN3 * 0.5);',
          'foSoil = mix(foSoil, foLitter, smoothstep(0.55, 0.85, foN3 + (1.0 - foCm.b) * 0.4) * 0.8);',
          'diffuseColor.rgb = mix(foLitter, foMossC, foMossM);',
          'diffuseColor.rgb = mix(diffuseColor.rgb, foSoil, foCm.b * smoothstep(0.2, 0.55, foN1 * 0.4 + foN2 * 0.4 + foCm.b * 0.35));',
          'diffuseColor.rgb *= 1.0 - 0.55 * foCm.r;',
          'float foPuddle = smoothstep(0.62, 0.7, foCm.a + (foN1 - 0.5) * 0.35 + (foN3 - 0.5) * 0.3 + (foG1 - 0.5) * 0.1) * uWet;',
          'diffuseColor.rgb *= mix(1.0, 0.6, uWet) * (1.0 - 0.55 * foPuddle);',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(mix(1.0, 0.7, uWet), 0.12, foPuddle);',
        normal: [
          'float foFade = smoothstep(30.0, 4.0, length(vViewPosition));',
          'float foH = foClump * 0.5 + foG1 * 0.35 + foG2 * 0.15;',
          'normal = fo_bump(normal, -vViewPosition, foH, 0.005 * foFade * (1.0 - foPuddle));',
          'if (foPuddle > 0.01) normal = fo_bump(normal, -vViewPosition, fo_ripples(vFoWorld.xz) * foPuddle, 0.004 * foFade);',
        ].join('\n'),
        lightEnd: [
          // wet litter: a soft sheen; the puddles: a mirror of the glow
          'float foDryS = mix(0.04, 0.15, 1.0 - foCm.g);',
          'reflectedLight.indirectSpecular *= mix(mix(foDryS, 0.2, uWet), 0.3, foPuddle) * (1.0 - 0.5 * foCm.r);',
          'reflectedLight.directSpecular *= mix(mix(0.03, 0.06, uWet), 0.07, foPuddle * foPuddle);',
        ].join('\n'),
      }));
      ground.receiveShadow = true;
      scene.add(ground);

      // ---------------------------------------------------------------- ferns, rocks, moss, log
      var fernFrond = cardMaterial(frondTex, lin('#2a3f26'), 0.7, 'fern', {
        hooks: {
          map: cardMap([0.8, 0.95, 0.75], [1.1, 1.05, 0.7], 0.5, 1.2),
          light: translucency(0.6, [0.9, 1.0, 0.6]),
          lightEnd: 'reflectedLight.directSpecular *= mix(0.3, 1.0, uWet);',
          roughness: 'roughnessFactor = mix(roughnessFactor, 0.55, uWet);',
          vertex: [
            'float foU = uv.x * uv.x;',
            'vec3 foIp = vec3(instanceMatrix[3][0], 0.0, instanceMatrix[3][2]);',
            'float foPh = fract(sin(dot(foIp.xz, vec2(12.9898, 78.233))) * 43758.5453);',
            'transformed.x += foU * 0.04 * sin(EV_TAU * (2.0 * uTime / EV_PERIOD + foPh));',
            'transformed.z += foU * 0.03 * sin(EV_TAU * (3.0 * uTime / EV_PERIOD + foPh * 1.7));',
            'transformed.y += foU * 0.02 * sin(EV_TAU * (uTime / EV_PERIOD + foPh * 2.3));',
          ].join('\n'),
        },
      });
      var fernGeo = fernGeometry(ctx.rng('fern'), 8);
      var fernList = [];
      var fr = ctx.rng('fern-place');
      for (var fa = 0; fa < 2400 && fernList.length < (quality === 'high' ? 170 : 110); fa++) {
        var fz = 6.5 - Math.pow(fr(), 1.25) * 40;
        var side = fr() < 0.5 ? -1 : 1;
        var fx = pathX(fz) + side * (pathHalf(fz) + 0.15 + Math.pow(fr(), 1.6) * (2.0 + (8 - fz) * 0.2));
        if (Math.hypot(fx, fz - 7.5) < 1.2) continue;
        var tooClose = false;
        for (var fi = 0; fi < fernList.length; fi++) {
          if (Math.hypot(fernList[fi][0] - fx, fernList[fi][1] - fz) < 0.55) { tooClose = true; break; }
        }
        if (tooClose) continue;
        fernList.push([fx, fz, 0.7 + fr() * 0.6, fr() * TAU]);
      }
      var ferns = new THREE.InstancedMesh(fernGeo, fernFrond, fernList.length);
      fernList.forEach(function (f, i) {
        q.setFromEuler(euler.set(0, f[3], 0));
        ferns.setMatrixAt(i, dummy.compose(e3.set(f[0], groundY(f[0], f[1]) - 0.03, f[1]), q, sv.set(f[2], f[2] * 0.9, f[2])).clone());
      });
      ferns.receiveShadow = true;
      ferns.frustumCulled = false;
      scene.add(ferns);

      var stoneHooks = {
        key: 'stone',
        env: 1,
        color: [
          'vec3 foWn = normalize(cross(dFdx(vFoWorld), dFdy(vFoWorld)));',
          'float foS1 = texture2D(uNoiseTex, vFoWorld.xz * 0.35 + vFoWorld.y * 0.2).g;',
          'float foS2 = texture2D(uNoiseTex, vFoWorld.xy * 0.7 + vFoWorld.z * 0.3).b;',
          'vec3 foRock = mix(vec3(0.050, 0.052, 0.055), vec3(0.11, 0.11, 0.105), foS1 * 0.6 + foS2 * 0.4);',
          'float foLich = smoothstep(0.6, 0.78, foS2) * smoothstep(0.3, 0.6, foS1);',
          'foRock = mix(foRock, vec3(0.20, 0.21, 0.17), foLich * 0.8);',
          'float foMossTop = smoothstep(0.35, 0.75, foWn.y + (foS1 - 0.5) * 0.6);',
          'diffuseColor.rgb = mix(foRock, vec3(0.020, 0.040, 0.012), foMossTop);',
          'diffuseColor.rgb *= 1.0 - 0.35 * uWet;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(mix(0.82, 1.0, foMossTop), 0.55, uWet * (1.0 - foMossTop));',
        normal: 'normal = fo_bump(normal, -vViewPosition, foS2 * 0.6 + foS1 * 0.4, 0.03 * smoothstep(25.0, 3.0, length(vViewPosition)));',
      };
      var rockMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 }, stoneHooks);
      var rockGeo = rockGeometry(ctx.rng('rock'));
      var rockSpots = [[1.25, 1.6, 0.42], [-1.55, -3.6, 0.75], [1.9, -8.2, 0.5], [-2.0, -11.5, 1.05], [2.4, -21, 0.9],
        [-2.7, -26, 1.3], [0.9, 4.2, 0.22], [-1.0, 0.4, 0.3], [3.4, -31, 1.1]];
      var rocks = new THREE.InstancedMesh(rockGeo, rockMat, rockSpots.length);
      var rr = ctx.rng('rock-place');
      rockSpots.forEach(function (s, i) {
        q.setFromEuler(euler.set((rr() - 0.5) * 0.3, rr() * TAU, (rr() - 0.5) * 0.3));
        rocks.setMatrixAt(i, dummy.compose(e3.set(s[0], groundY(s[0], s[1]) + s[2] * 0.12, s[1]), q, sv.set(s[2], s[2], s[2])).clone());
      });
      rocks.castShadow = true;
      rocks.receiveShadow = true;
      rocks.frustumCulled = false;
      scene.add(rocks);

      var mossMat = pbr(THREE.MeshPhysicalMaterial, {
        color: lin('#3c5a22'), roughness: 1.0, metalness: 0, sheen: 1.0, sheenColor: lin('#7d9a56'), sheenRoughness: 0.55,
      }, {
        key: 'moss',
        env: 1,
        color: 'float foM = texture2D(uNoiseTex, vFoWorld.xz * 1.3).b; diffuseColor.rgb *= 0.55 + 0.6 * foM;',
        normal: 'normal = fo_bump(normal, -vViewPosition, texture2D(uNoiseTex, vFoWorld.xz * 2.4).b, 0.012);',
      });
      var mounds = [];
      var mr = ctx.rng('moss');
      trees.filter(function (t) { return t.lod === 0; }).forEach(function (t) {
        var n = 1 + Math.floor(mr() * 3);
        for (var m = 0; m < n; m++) {
          var a = mr() * TAU, d = 0.45 * t.s + mr() * 0.7;
          mounds.push([t.x + Math.cos(a) * d, t.z + Math.sin(a) * d, 0.25 + mr() * 0.4, mr() * TAU]);
        }
      });
      rockSpots.forEach(function (s) { mounds.push([s[0] + s[2] * 0.9, s[1] + s[2] * 0.3, s[2] * 0.6, mr() * TAU]); });
      var moundMesh = new THREE.InstancedMesh(moundGeometry(), mossMat, mounds.length);
      mounds.forEach(function (m, i) {
        q.setFromEuler(euler.set(0, m[3], 0));
        moundMesh.setMatrixAt(i, dummy.compose(e3.set(m[0], groundY(m[0], m[1]), m[1]), q, sv.set(m[2], m[2] * 0.35, m[2] * 0.8)).clone());
      });
      moundMesh.receiveShadow = true;
      moundMesh.frustumCulled = false;
      scene.add(moundMesh);

      // a fallen trunk along the left edge of the path, with broken branch stubs
      var logPts = [];
      var A = [-3.4, 3.6], B = [-0.9, -4.2];
      for (var lp = 0; lp <= 26; lp++) {
        var f = lp / 26;
        var lx = A[0] + (B[0] - A[0]) * f, lz = A[1] + (B[1] - A[1]) * f;
        var lr = 0.3 - 0.07 * f + (lp === 0 || lp === 26 ? -0.03 : 0);
        logPts.push([lx, Math.max(groundY(lx, lz) + lr * 0.75, 0.0) + 0.02 * Math.sin(f * 9.0), lz, lr]);
      }
      var parts = [tubeGeometry(logPts, 16, 0.07)];
      var lr2 = ctx.rng('log');
      for (var st = 0; st < 5; st++) {
        var ff = 0.15 + st * 0.17 + lr2() * 0.05, base = logPts[Math.round(ff * 26)];
        var ang = lr2() * TAU, el = 0.2 + lr2() * 0.7, len = 0.25 + lr2() * 0.4;
        var dx = Math.cos(ang) * Math.cos(el), dy = Math.sin(el), dz = Math.sin(ang) * Math.cos(el);
        parts.push(tubeGeometry([[base[0], base[1], base[2], 0.045], [base[0] + dx * len, base[1] + dy * len, base[2] + dz * len, 0.02]], 5, 0));
      }
      var logMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.9, metalness: 0 },
        Object.assign({}, barkHooks, {
          key: 'log',
          env: 1,
          color: barkHooks.color + '\nfloat foTop = smoothstep(0.25, 0.85, normalize(cross(dFdx(vFoWorld), dFdy(vFoWorld))).y + (foN - 0.5) * 0.7);\n' +
            'diffuseColor.rgb = mix(diffuseColor.rgb * vec3(1.15, 1.1, 1.05), vec3(0.022, 0.044, 0.013), foTop * 0.85);',
        }));
      var log = new THREE.Mesh(mergeAll(parts), logMat);
      log.castShadow = true;
      log.receiveShadow = true;
      scene.add(log);

      // twigs on the forest floor
      var twigParts = [];
      var tr = ctx.rng('twigs');
      for (var tw = 0; tw < 90; tw++) {
        var tz = 7 - Math.pow(tr(), 1.2) * 24, tx = pathX(tz) + (tr() * 2 - 1) * (pathHalf(tz) + 2.5);
        var ta = tr() * TAU, tl = 0.25 + tr() * 0.8, tyy = groundY(tx, tz) + 0.012;
        var mx = tx + Math.cos(ta) * tl * 0.5, mz = tz + Math.sin(ta) * tl * 0.5;
        twigParts.push(tubeGeometry([[tx, tyy, tz, 0.012 + tr() * 0.012], [mx, groundY(mx, mz) + 0.02, mz, 0.01],
          [tx + Math.cos(ta + 0.2) * tl, groundY(tx + Math.cos(ta + 0.2) * tl, tz + Math.sin(ta + 0.2) * tl) + 0.01, tz + Math.sin(ta + 0.2) * tl, 0.006]], 4, 0));
      }
      // twigs and cones: the bark shader, darker (small, half buried in the litter)
      var debrisMat = pbr(THREE.MeshStandardMaterial, { color: 0x6a6a6a, roughness: 0.95, metalness: 0 },
        Object.assign({}, barkHooks, { key: 'debris', color: barkHooks.color + '\ndiffuseColor.rgb *= 0.28;' }));
      var twigs = new THREE.Mesh(mergeAll(twigParts), debrisMat);
      twigs.receiveShadow = true;
      scene.add(twigs);

      // spruce cones on the floor
      var coneGeo = mergeVertices(new THREE.IcosahedronGeometry(1, 1));
      coneGeo.computeVertexNormals();
      var coneList = [];
      var cr2 = ctx.rng('cones');
      for (var cn = 0; cn < 110; cn++) {
        var cz = 7 - Math.pow(cr2(), 1.2) * 20, cx = pathX(cz) + (cr2() * 2 - 1) * (pathHalf(cz) + 2.2);
        coneList.push([cx, cz, cr2() * TAU, 0.8 + cr2() * 0.5]);
      }
      var cones = new THREE.InstancedMesh(coneGeo, debrisMat, coneList.length);
      coneList.forEach(function (c, i) {
        q.setFromEuler(euler.set(0, c[2], (cr2() - 0.5) * 0.4));
        cones.setMatrixAt(i, dummy.compose(e3.set(c[0], groundY(c[0], c[1]) + 0.02, c[1]), q, sv.set(0.055 * c[3], 0.022 * c[3], 0.022 * c[3])).clone());
      });
      cones.receiveShadow = true;
      cones.frustumCulled = false;
      scene.add(cones);

      // ---------------------------------------------------------------- motes near the camera
      var moteCount = 28;
      var mp = [], ma = [];
      var mo = ctx.rng('motes');
      for (var mi = 0; mi < moteCount; mi++) {
        mp.push((mo() * 2 - 1) * 2.4, 0.3 + mo() * 3.2, 6.2 - mo() * 9);
        ma.push(mo(), mo(), mo(), 0.5 + mo());
      }
      var moteGeo = new THREE.BufferGeometry();
      moteGeo.setAttribute('position', new THREE.Float32BufferAttribute(mp, 3));
      moteGeo.setAttribute('aM', new THREE.Float32BufferAttribute(ma, 4));
      var moteMat = ctx.material({
        uniforms: Object.assign({}, shared, { uMoonCol: { value: lin('#b4c8e6') } }),
        transparent: true,
        blending: THREE.AdditiveBlending,
        vertexShader: FO_GLSL + '\n' + [
          'attribute vec4 aM; uniform vec3 uMoonCol;',
          'varying vec3 vC; varying float vSoft;',
          'void main() {',
          '  float T = EV_TAU * uTime / EV_PERIOD;',
          '  vec3 p = position + vec3(0.35 * sin(T + aM.x * EV_TAU), 0.25 * sin(2.0 * T + aM.y * EV_TAU) + 0.1 * sin(T + aM.z * 6.0), 0.3 * cos(T + aM.z * EV_TAU));',
          '  vec4 mv = viewMatrix * vec4(p, 1.0);',
          '  gl_Position = projectionMatrix * mv;',
          '  float dist = -mv.z;',
          '  float lit = fo_shadow(p);',
          '  float ph = fo_phase(dot(normalize(p - cameraPosition), uMoonDir));',
          '  float px = 0.012 * aM.w * uFocal / max(dist, 0.2);',
          '  float blur = clamp(3.0 / max(dist, 0.3), 1.0, 8.0);',
          '  gl_PointSize = clamp(px * blur * 2.0 + 2.0, 1.0, 48.0 * uPixelRatio);',
          '  vSoft = blur;',
          '  vC = uMoonCol * (0.004 + 1.2 * ph * lit) * 0.22 / (blur * blur) * smoothstep(0.6, 1.4, dist);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vC; varying float vSoft;',
          'void main() {',
          '  float r = length(gl_PointCoord - 0.5) * 2.0;',
          '  float disc = 1.0 - smoothstep(0.55, 1.0, r);',
          '  gl_FragColor = vec4(vC * disc, 1.0);',
          '}',
        ].join('\n'),
      });
      var motes = new THREE.Points(moteGeo, moteMat);
      motes.frustumCulled = false;
      motes.renderOrder = 21;
      scene.add(motes);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function levelOnly(object, uniforms, extra) {
        var u = { value: 0 };
        uniforms.forEach(function (m) { m.uLevel = u; });
        object.visible = false;
        return { object: object, setLevel: function (v) { u.value = v; if (extra) extra(v); } };
      }
      var DECOR_GLSL = D.GLSL, DECOR_VERT = D.GLSL_VERTEX;

      // fireflies: emissive points (HDR, the bloom makes their halo), wandering, blinking
      var ffCount = quality === 'high' ? 220 : 140;
      var ffp = [], ffa = [], ffb = [];
      var fq = ctx.rng('fireflies');
      for (var fi2 = 0; fi2 < ffCount; fi2++) {
        var z3 = 6.5 - Math.pow(fq(), 0.9) * 30;
        var x3 = pathX(z3) + (fq() * 2 - 1) * (pathHalf(z3) + 2.5 + (8 - z3) * 0.12);
        ffp.push(x3, groundY(x3, z3) + 0.2 + Math.pow(fq(), 1.7) * 2.4, z3);
        ffa.push(fq(), fq(), fq(), fq());                                  // rank, phases
        ffb.push(4 + Math.floor(fq() * 5), fq(), fq(), fq());             // flashes per period, phase, size, warmth
      }
      var ffGeo = new THREE.BufferGeometry();
      ffGeo.setAttribute('position', new THREE.Float32BufferAttribute(ffp, 3));
      ffGeo.setAttribute('aA', new THREE.Float32BufferAttribute(ffa, 4));
      ffGeo.setAttribute('aB', new THREE.Float32BufferAttribute(ffb, 4));
      var ffMat = ctx.material({
        uniforms: Object.assign({}, shared, { uLevel: { value: 0 }, uColA: { value: lin('#d6f06a') }, uColB: { value: lin('#ffd27a') } }),
        transparent: true,
        blending: THREE.AdditiveBlending,
        vertexShader: DECOR_GLSL + '\n' + FO_GLSL + '\n' + [
          'attribute vec4 aA; attribute vec4 aB;',
          'varying float vI; varying float vWarm; varying float vR;',
          'void main() {',
          '  float T = EV_TAU * uTime / EV_PERIOD;',
          '  vec3 p = position;',
          '  p.x += 0.55 * sin(T + aA.y * EV_TAU) + 0.25 * sin(3.0 * T + aA.z * EV_TAU);',
          '  p.y += 0.22 * sin(2.0 * T + aA.z * EV_TAU) + 0.12 * sin(5.0 * T + aA.w * EV_TAU);',
          '  p.z += 0.5 * cos(T + aA.w * EV_TAU) + 0.2 * sin(2.0 * T + aA.y * EV_TAU);',
          '  vec4 mv = viewMatrix * vec4(p, 1.0);',
          '  gl_Position = projectionMatrix * mv;',
          '  float dist = -mv.z;',
          // a flash: a soft rise and a slower fall, aB.x times per period; dim glow between
          '  float ph = fract(aB.x * uTime / EV_PERIOD + aB.y);',
          '  float flash = smoothstep(0.0, 0.05, ph) * exp(-max(ph - 0.05, 0.0) * 12.0);',
          '  float glow = 0.06 + 0.94 * flash;',
          '  vI = ev_present(aA.x) * glow * (0.6 + 0.4 * uLevel) * fo_trans(p) * smoothstep(0.4, 1.2, dist);',
          '  vWarm = aB.w;',
          '  float px = 0.016 * (0.7 + 0.6 * aB.z) * uFocal / max(dist, 0.3);',
          '  vR = max(px, 1.2);',
          '  gl_PointSize = clamp(vR * 3.0, 6.0, 40.0 * uPixelRatio);',
          // a firefly smaller than its sprite (far away) is dimmed accordingly
          '  vI *= clamp(px / vR, 0.3, 1.0);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uColA; uniform vec3 uColB;',
          'varying float vI; varying float vWarm; varying float vR;',
          'void main() {',
          '  vec2 d = (gl_PointCoord - 0.5) * 3.0;',
          '  float r2 = dot(d, d);',
          '  float core = exp(-r2 * 2.2);',
          '  float halo = exp(-r2 * 0.45) * 0.06;',
          '  vec3 c = mix(uColA, uColB, vWarm * 0.6);',
          '  gl_FragColor = vec4(c * (core * 26.0 + halo * 8.0) * vI, 1.0);',
          '}',
        ].join('\n'),
      });
      var fireflies = new THREE.Points(ffGeo, ffMat);
      fireflies.frustumCulled = false;
      fireflies.renderOrder = 22;

      // rain: streaks lit by the moon where it reaches them (shadow map), wet surfaces
      var rainCount = quality === 'high' ? 1300 : 800;
      var rainGeo = new THREE.InstancedBufferGeometry();
      rainGeo.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(18), 3));
      rainGeo.setAttribute('corner', new THREE.Float32BufferAttribute([-1, 0, 1, 0, 1, 1, -1, 0, 1, 1, -1, 1], 2));
      var ra = [], rb = [];
      var rq = ctx.rng('rain');
      for (var ri = 0; ri < rainCount; ri++) {
        ra.push(rq(), rq(), rq(), rq());
        rb.push(Math.max(1, Math.round((8 + rq() * 2.5) * 30 / 11)), 0.4 + rq() * 0.35, 0.5 + rq() * 0.5, 0);
      }
      rainGeo.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(ra), 4));
      rainGeo.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(rb), 4));
      rainGeo.instanceCount = rainCount;
      var rainMat = ctx.material({
        uniforms: Object.assign({}, shared, {
          uLevel: { value: 0 }, uMoonCol: { value: lin('#b4c8e6') },
          uBoxMin: { value: new THREE.Vector3(-6, -0.5, -18) }, uBoxMax: { value: new THREE.Vector3(6, 10.5, 7) },
        }),
        transparent: true,
        blending: THREE.AdditiveBlending,
        vertexShader: DECOR_GLSL + '\n' + DECOR_VERT + '\n' + FO_GLSL + '\n' + [
          'uniform vec3 uBoxMin; uniform vec3 uBoxMax; uniform vec3 uMoonCol;',
          'float pathOffset(float z) { return 0.8 * sin((8.0 - z) * 0.05); }',
          'attribute vec2 corner; attribute vec4 aA; attribute vec4 aB;',
          'varying float vAlong; varying float vAcross; varying vec3 vC;',
          'void main() {',
          '  vec3 size = uBoxMax - uBoxMin;',
          '  float ph = fract(aA.z + aB.x * uTime / EV_PERIOD);',
          '  vec3 dir = normalize(vec3(0.05, -1.0, 0.02));',
          '  vec3 head = uBoxMin + vec3(aA.x * size.x, (1.0 - ph) * size.y, aA.y * size.z);',
          '  head.x += pathOffset(head.z);',
          '  vec3 tail = head - dir * aB.y;',
          '  vec3 hv = (viewMatrix * vec4(head, 1.0)).xyz;',
          '  vec3 tv = (viewMatrix * vec4(tail, 1.0)).xyz;',
          '  float dist = -hv.z;',
          '  if (dist < 0.35 || -tv.z < 0.35) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vC = vec3(0.0); vAlong = 0.0; vAcross = 0.0; return; }',
          '  float w = max(1.1 * uPixelRatio, 0.0035 * uFocal / dist);',
          '  gl_Position = ev_streak(hv, tv, corner, w);',
          '  float env = smoothstep(0.0, 0.05, ph) * smoothstep(1.0, 0.95, ph);',
          '  float lit = fo_shadow(head);',
          '  float phs = fo_phase(dot(normalize(head - cameraPosition), uMoonDir));',
          '  vec3 c = uFogAmb * 1.2 + uMoonCol * (0.02 + phs * lit * 0.55);',
          '  vC = c * ev_present(aA.w) * env * aB.z * smoothstep(0.5, 2.0, dist) * (0.55 + 0.45 * uLevel) * fo_trans(head);',
          '  vC *= min(1.0, 1.6 / (0.6 + w)) * 0.6;',
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

      var stars = D.etoiles(ctx, {
        count: quality === 'high' ? 1100 : 700, azimuth: [4, 38], elevation: [10, 78], size: 1.15, brightness: 6.0,
        tint: ['#cfe0ff', '#f6efe0'],
      });
      stars.object.renderOrder = 11;

      var decors = {
        lucioles: levelOnly(fireflies, [ffMat.uniforms]),
        brume: levelOnly(new THREE.Group(), [], function (v) { applyMist(v); }),
        pluie: levelOnly(rain, [rainMat.uniforms], function (v) { shared.uWet.value = v; }),
        etoiles: stars,
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      var mistLevel = 0;
      function applyMist(v) {
        mistLevel = v;
        var low = quality === 'low' ? 0.75 : 1;
        shared.uFog.value.x = fogBase.density * (1 + 0.35 * v) * low;
        shared.uFog.value.y = fogBase.ground * (1 + 0.8 * v) * low;
        shared.uFog.value.w = v * low;
      }
      applyMist(0);

      // ---------------------------------------------------------------- finish
      var post = ctx.post({
        exposure: 0.95,
        toneMapping: 'aces',
        bloom: { strength: 0.25, threshold: 1.0, knee: 0.6, radius: 1.0 },
        rays: { strength: 0.65, length: 0.5, decay: 0.93, radius: 0.4 },
        aberration: 0.006,
        vignette: 0.42,
        // film grain live only: in the wallpaper loop (recording), a new grain pattern every image
        // is what H.264 at 2.5 MB keeps worst (it took the loop to 3.7 MB at CRF 35)
        grain: ctx.record ? 0 : 0.028,
      });

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = t / ctx.PERIOD * TAU;
        camera.position.set(0.42 * Math.sin(T), camY + 0.05 * Math.sin(2 * T + 0.4), 7.5 + 0.55 * Math.cos(T) - 0.55);
        camera.lookAt(0.6 + 0.3 * Math.sin(T + 0.7), camY + 2.6 + 0.12 * Math.sin(T), -40);
      }
      update(0);
      var moonScreen = new THREE.Vector3();

      // the mist, the motes and the rain sample the moon's shadow map: one tiny render makes it
      // (and compiles the programs) before the first frame
      function primeShadows() {
        var rt = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType });
        renderer.setRenderTarget(rt);
        renderer.render(scene, camera);
        renderer.setRenderTarget(null);
        rt.dispose();
        var ready = !!(moon.shadow.map && moon.shadow.map.depthTexture);
        shared.uShadowMap.value = ready ? moon.shadow.map.depthTexture : shadowPlaceholder;
        shared.uShadowMatrix.value = moon.shadow.matrix;
        shared.uShadowReady.value = ready ? 1 : 0;
      }
      primeShadows();

      return {
        decors: decors,
        update: update,
        render: function () {
          // the moon on screen, for the light rays of the finish
          camera.updateMatrixWorld();
          moonScreen.copy(moonDir).multiplyScalar(500).add(camera.position).project(camera);
          post.setLight(moonScreen.x * 0.5 + 0.5, moonScreen.y * 0.5 + 0.5);
          post.render(scene, camera);
        },
        setQuality: function (qq) {
          quality = qq;
          post.setQuality(qq);
          patched.forEach(function (m) {
            if (m.alphaTest > 0) m.alphaToCoverage = qq === 'high';
            m.needsUpdate = true;
          });
          var size = qq === 'high' ? 1024 : 512;
          moon.shadow.mapSize.set(size, size);
          if (moon.shadow.map) {
            moon.shadow.map.dispose();
            moon.shadow.map = null;
          }
          shared.uShadowMap.value = shadowPlaceholder;
          primeShadows();
          applyMist(mistLevel);
        },
        describe: function () {
          var d = post.describe();
          d.shadowMap = moon.shadow.mapSize.x;
          d.trees = counts;
          d.ferns = fernList.length;
          return d;
        },
        dispose: function () {
          post.dispose();
          textures.forEach(function (t) { t.dispose(); });
          envRT.dispose();
          moon.dispose();
        },
      };
    },
  });
})();
