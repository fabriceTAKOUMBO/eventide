/*
 * Eventide « Imaginaire »: scenery shared by several scenes (GLSL snippets and builders).
 *   TREELINE: a row of pines drawn by a fragment shader on one wide quad (ragged, drooping
 *             tiers; trees every uSpacing, heights from a hash, a clearing of half-width uGap).
 *   RIDGE:    a mountain or hill profile along x (ridged noise), for silhouettes.
 *   nature:   the kit of the HDR night lake scenes (lac-lune, aurore): see the block at the end.
 */
(function () {
  'use strict';
  var THREE = window.THREE;

  var TREELINE = [
    'uniform float uSpacing; uniform vec2 uHeight; uniform float uWidth; uniform float uGap; uniform float uSeed;',
    'uniform float uDetail; uniform float uSway; uniform float uThin;',
    'float ev_pine(float dx, float y, float h, float w, float s) {',
    '  float t = y / h;',
    '  if (t > 1.0 || t < -0.02) return -1.0;',
    '  float trunk = w * 0.05 * (1.15 - t);',
    '  float crown = -1.0;',
    '  float base = 0.06 + 0.14 * s;',
    // boughs droop: tiers slope down away from the trunk
    '  float tt = t + 0.42 * abs(dx) / h;',
    '  if (tt > base) {',
    '    float c = min((tt - base) / (1.0 - base), 1.0);',
    '    float cone = w * pow(1.0 - c, 0.92) * smoothstep(0.0, 0.05, c);',
    '    float tiers = 8.0 + floor(s * 6.0);',
    '    float k = fract(c * tiers + s * 3.0);',
    '    float tier = 1.0 - 0.3 * pow(k, 0.8);',
    '    float side = dx < 0.0 ? 1.7 : 3.1;',
    '    float rag = ev_noise(vec2(c * tiers * 2.2, side + s * 13.0)) - 0.5;',
    '    float fine = ev_noise(vec2(c * tiers * 8.0 * uDetail, side * 2.0 + s * 7.0)) - 0.5;',
    '    float needle = uDetail > 0.85 ? ev_noise(vec2(c * tiers * 34.0 * uDetail, side * 5.0 + s * 3.0)) - 0.5 : 0.0;',
    '    crown = cone * tier * (1.0 + 0.34 * rag + 0.24 * fine + 0.16 * needle * uDetail);',
    '  }',
    '  return max(trunk, crown) - abs(dx);',
    '}',
    // signed distance-like value: > 0 inside a tree
    'float ev_treeDist(float x, float y) {',
    '  float cell = floor(x / uSpacing);',
    '  float best = -1e3;',
    '  for (int i = -2; i <= 2; i++) {',
    '    float c = cell + float(i);',
    '    float hs = ev_hash12(vec2(c, uSeed));',
    '    float cx = (c + 0.15 + 0.7 * ev_hash12(vec2(c + 7.0, uSeed))) * uSpacing;',
    '    if (abs(cx) < uGap * (0.75 + 0.5 * ev_hash12(vec2(c, uSeed + 3.0)))) continue;',
    '    if (ev_hash12(vec2(c, uSeed + 5.0)) < uThin) continue;',
    '    float h = mix(uHeight.x, uHeight.y, hs);',
    '    float sw = uSway * h * ev_wave(1.0, hs, uTime) * (y / h) * (y / h);',
    '    best = max(best, ev_pine(x - cx - sw, y, h, h * uWidth * (0.85 + 0.3 * hs), hs));',
    '  }',
    '  return best;',
    '}',
  ].join('\n');

  var RIDGE = [
    // profile in [0, 1] along x: broad shapes plus sharp ridges
    'float ev_ridge(float x, float seed, float freq) {',
    '  float a = ev_noise(vec2(x * freq, seed));',
    '  float b = 1.0 - abs(ev_noise(vec2(x * freq * 2.1, seed + 5.0)) * 2.0 - 1.0);',
    '  float c = ev_noise(vec2(x * freq * 5.3, seed + 9.0));',
    '  float d = ev_noise(vec2(x * freq * 13.0, seed + 13.0));',
    '  float e = ev_noise(vec2(x * freq * 37.0, seed + 17.0));',
    '  return clamp(0.52 * a + 0.24 * pow(b, 1.6) + 0.14 * c + 0.07 * d + 0.03 * e, 0.0, 1.0);',
    '}',
  ].join('\n');

  // A vertical quad of the given half-width and height, standing on y = 0 at depth z; the
  // fragment shader gets vWorld and vLocal (x along the row, y up).
  var ROW_VERTEX = [
    'varying vec3 vWorld; varying vec2 vLocal;',
    'void main() {',
    '  vec4 w = modelMatrix * vec4(position, 1.0);',
    '  vWorld = w.xyz; vLocal = position.xy;',
    '  gl_Position = projectionMatrix * viewMatrix * w;',
    '}',
  ].join('\n');

  function rowQuad(material, z, halfWidth, top, bottom) {
    bottom = bottom === undefined ? -0.5 : bottom;
    var geo = new THREE.PlaneGeometry(halfWidth * 2, top - bottom, 1, 1);
    geo.translate(0, (top + bottom) / 2, 0);
    var mesh = new THREE.Mesh(geo, material);
    mesh.position.set(0, 0, z);
    return mesh;
  }

  window.EventideScenery = {
    TREELINE: TREELINE,
    RIDGE: RIDGE,
    ROW_VERTEX: ROW_VERTEX,
    rowQuad: rowQuad,
  };
})();

/*
 * Nature kit for the HDR night landscapes around a lake (`lac-lune`, `aurore`; post.js finish),
 * on window.EventideScenery.nature. Everything procedural, built once at start-up:
 *   - textures: tileable noise, spruce spray (as the forest v2), far-spruce silhouettes (atlas of
 *     four, with a snow mask of the upper surfaces), lake ripples (gradients of a tileable field of
 *     waves with whole wave numbers, so that sliding whole tiles per period loops exactly);
 *   - terrain: gradient noise in JS, a chunked polar height field around the camera (only the
 *     chunks in view are drawn) with the key light's visibility (horizon march) and an occlusion
 *     term baked per vertex: mountains shadow themselves without a shadow map;
 *   - night air (GLSL): haze and ground fog decreasing with height, a forward-scattering lobe lit
 *     by the key light, a band of mist lying on the water (Lorentzian profile centred on the water
 *     plane, integrated analytically: the mirrored camera of the reflection sees exactly the same
 *     mist), drifting and lit through the trees where the shadow map says so;
 *   - patched three.js PBR materials (that air, world position, hooks), instanced conifers (card
 *     crowns near the camera, as the forest v2; camera-facing silhouettes far away), the water
 *     (planar reflection in HDR, ripples, Fresnel, glitter of the key light from a microfacet
 *     distribution whose roughness grows as the ripples get smaller than a pixel).
 */
(function () {
  'use strict';
  var THREE = window.THREE;
  var TAU = Math.PI * 2;
  var TREE_H = 22;   // reference height of the crown geometries (instances scale it)

  function lin(hex) {
    return new THREE.Color(hex).convertSRGBToLinear();
  }

  // ------------------------------------------------------------------ textures
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

  // A small raster of anti-aliased strokes: coverage (a), shade (s), tint (t), snow (u).
  function raster(w, h) {
    return { w: w, h: h, a: new Float32Array(w * h), s: new Float32Array(w * h), t: new Float32Array(w * h), u: new Float32Array(w * h) };
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
  // RGBA bytes (R shade, G tint, B snow, A coverage) with mipmaps that keep the alpha-tested
  // coverage (each level's alpha is scaled so that as many texels pass 0.5 as in level 0).
  function coverageTexture(c) {
    var w = c.w, h = c.h, data = new Uint8Array(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      var a = c.a[i];
      data[i * 4] = Math.round((a > 0.02 ? c.s[i] : 0.55) * 255);
      data[i * 4 + 1] = Math.round((a > 0.02 ? c.t[i] : 0.5) * 255);
      data[i * 4 + 2] = Math.round(Math.max(0, Math.min(1, c.u[i])) * 255);
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
          var r = 0, g = 0, b = 0, sa = 0;
          for (var oy = 0; oy < 2; oy++) {
            for (var ox = 0; ox < 2; ox++) {
              var sx = Math.min(sw - 1, x * 2 + ox), sy = Math.min(sh - 1, y * 2 + oy), k = (sy * sw + sx) * 4;
              var aa = src[k + 3] / 255 + 0.004;
              r += src[k] * aa; g += src[k + 1] * aa; b += src[k + 2] * aa; sa += aa;
            }
          }
          var j = (y * nw + x) * 4;
          dst[j] = Math.round(r / sa); dst[j + 1] = Math.round(g / sa); dst[j + 2] = Math.round(b / sa);
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

  // Snow on the upper surfaces of a raster: covered texels with open sky a few texels above them
  // (y grows downward in the raster), patchy.
  function snowMask(c, depth, rng) {
    var w = c.w, h = c.h;
    for (var x = 0; x < w; x++) {
      var run = 0;
      for (var y = 0; y < h; y++) {
        var i = y * w + x;
        if (c.a[i] < 0.35) { run = 0; continue; }
        run++;
        var lump = 0.75 + 0.5 * Math.sin(x * 0.9 + Math.sin(y * 0.37) * 3.0);
        c.u[i] = Math.max(c.u[i], run <= depth * lump ? 1 - 0.25 * rng() : 0);
      }
    }
  }

  // Spruce spray (one branch seen from above), as the forest v2: a main shoot carrying alternate
  // branchlets, which carry short twigs; every shoot is a bottle-brush of short needles.
  function sprayTexture(rng, snow) {
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
    if (snow) {
      // a spray seen from above carries snow in lumps along its shoots: B = snow cover
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          var i = y * W + x;
          var u = x / W, v = (y / H - 0.5) * 2;
          var lump = 0.5 + 0.5 * Math.sin(x * 0.21 + Math.sin(y * 0.13) * 2.2) * Math.sin(y * 0.29 + x * 0.05);
          c.u[i] = c.a[i] > 0.3 ? Math.max(0, Math.min(1, (1 - Math.abs(v) * 1.25) * 1.6 * (0.45 + 0.7 * lump) - 0.25 * u)) : 0;
        }
      }
    }
    return coverageTexture(c);
  }

  // Four spruce silhouettes side by side (for far, camera-facing trees): drooping tiers of ragged
  // boughs around a thin trunk. R shade (tips lighter), G tint, B snow on upper surfaces. k: scale
  // of the resolution (1: 64x192 a tree; 2 or 3 for trees a few hundred pixels tall).
  function silhouetteTexture(rng, snow, k) {
    k = k || 1;
    var CW = 64 * k, H = 192 * k, W = CW * 4, c = raster(W, H);
    function st(x0, y0, x1, y1, r0, r1, sh, ti) { stroke(c, x0, y0, x1, y1, r0 * k, r1 * k, sh, ti); }
    for (var t4 = 0; t4 < 4; t4++) {
      var cx = t4 * CW + CW / 2;
      var top = (4 + rng() * 6) * k, base = H - 2 * k;
      var crownBase = base - (14 + rng() * 22) * k;
      var halfW = CW * (0.36 + rng() * 0.08);
      st(cx, base, cx, top + 6 * k, 1.4, 0.5, 0.25, 0.5);
      var tiers = (15 + Math.floor(rng() * 5)) * (k > 1 ? 1.6 : 1);
      for (var t = 0; t < tiers; t++) {
        var f = (t + rng() * 0.5) / tiers;   // 0 at the crown base, 1 at the top
        var y = crownBase + (top - crownBase) * f;
        var w = halfW * Math.pow(1 - f, 0.95) * (0.8 + rng() * 0.35) + 1.5 * k;
        for (var side = -1; side <= 1; side += 2) {
          // a bough: a drooping line out to the tip, and needle tufts hanging from it
          var droop = (3 + 6 * (1 - f) + rng() * 3) * k;
          var x1 = cx + side * w, y1 = y + droop;
          st(cx, y, x1, y1, 1.6, 0.6, 0.35, 0.5 + (rng() - 0.5) * 0.3);
          var tufts = Math.max(2, Math.round(w / (2.2 * (k > 1 ? 1.4 : 1))));
          for (var q = 0; q < tufts; q++) {
            var s0 = (q + rng()) / tufts;
            var px = cx + (x1 - cx) * s0, py = y + (y1 - y) * s0 * s0;
            var hang = (2 + rng() * 4 * (1 - f * 0.5)) * k;
            st(px, py - k, px + side * rng() * 2 * k, py + hang, 1.5 + rng() * 0.8, 0.6, 0.3 + 0.6 * s0 + (rng() - 0.5) * 0.15, 0.5 + (rng() - 0.5) * 0.3);
          }
        }
      }
      st(cx, top + 8 * k, cx, top, 1.2, 0.4, 0.6, 0.5);
    }
    if (snow) snowMask(c, 6 * k, rng);
    return coverageTexture(c);
  }

  // Ripples: a tileable field of waves with whole wave numbers (8..26 per tile), amplitude falling
  // with the wave number; RG = slope (x, y) in [0, 1], B = height. Mipmaps average the slopes out.
  function rippleTexture(rng) {
    var N = 128, waves = [];
    while (waves.length < 56) {
      var k = 7 + Math.pow(rng(), 0.8) * 19, ang = rng() * TAU;
      var m = Math.round(Math.cos(ang) * k), n = Math.round(Math.sin(ang) * k * 0.75);
      if (!m && !n) continue;
      waves.push([m, n, Math.pow(Math.hypot(m, n), -1.7), rng() * TAU]);
    }
    var gx = new Float32Array(N * N), gy = new Float32Array(N * N), hh = new Float32Array(N * N), gmax = 0, hmax = 0;
    for (var y = 0; y < N; y++) {
      for (var x = 0; x < N; x++) {
        var i = y * N + x, sx = 0, sy = 0, sh = 0;
        for (var w = 0; w < waves.length; w++) {
          var W = waves[w], ph = TAU * (W[0] * x + W[1] * y) / N + W[3];
          var cph = Math.cos(ph);
          sh += W[2] * Math.sin(ph);
          sx += W[2] * TAU * W[0] * cph;
          sy += W[2] * TAU * W[1] * cph;
        }
        gx[i] = sx; gy[i] = sy; hh[i] = sh;
        gmax = Math.max(gmax, Math.abs(sx), Math.abs(sy));
        hmax = Math.max(hmax, Math.abs(sh));
      }
    }
    var data = new Uint8Array(N * N * 4);
    for (var p = 0; p < N * N; p++) {
      data[p * 4] = Math.round((gx[p] / gmax * 0.5 + 0.5) * 255);
      data[p * 4 + 1] = Math.round((gy[p] / gmax * 0.5 + 0.5) * 255);
      data[p * 4 + 2] = Math.round((hh[p] / hmax * 0.5 + 0.5) * 255);
      data[p * 4 + 3] = 255;
    }
    var t = dataTexture(data, N, N, { repeat: true, mips: true, anisotropy: 8 });
    t.userData.slope = gmax;   // slope (per tile) of a texel value of 1
    return t;
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

  // Tapered trunk (as the forest v2); uv: around (m), height (m).
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
        var cx = Math.cos(th), sz = Math.sin(th);
        pos.push(bend + cx * r, y, sz * r);
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

  // Crown of drooping branch cards (as the forest v2). lod 0: a long branch is a row of sprays;
  // 1: one folded card a branch; 2: fewer, larger cards. Vertex colour: occlusion toward the trunk.
  var VARIANTS = [
    { base: 0.22, radius: 0.19, droop: 1.0, n: 6 },
    { base: 0.36, radius: 0.16, droop: 1.3, n: 5 },
    { base: 0.1, radius: 0.215, droop: 0.8, n: 6 },
  ];
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
    function card(root, dirx, dirz, len, width, pitch, tipDrop, roll, c, segs, fold) {
      var base = pos.length / 3;
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

  // Boulder: a displaced icosphere with a few planar cuts, flat underneath (as the forest v2).
  function rockGeometry(rng) {
    var g = new THREE.IcosahedronGeometry(1, 3);
    var p = g.attributes.position;
    var planes = [];
    for (var k = 0; k < 8; k++) {
      var th = rng() * TAU, el = (rng() - 0.25) * 1.3;
      planes.push([Math.cos(th) * Math.cos(el), Math.sin(el), Math.sin(th) * Math.cos(el), 0.66 + rng() * 0.22]);
    }
    var v = new THREE.Vector3(), pn = new THREE.Vector3();
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var n = 0.16 * Math.sin(v.x * 3.1 + 1.3) * Math.sin(v.y * 2.7 + 0.4) * Math.sin(v.z * 3.3 + 2.1)
        + 0.07 * Math.sin(v.x * 7.1 + v.z * 5.3) + 0.05 * Math.sin(v.y * 9.0 + v.x * 6.1)
        + 0.025 * Math.sin(v.x * 17.0 + v.y * 13.0) * Math.sin(v.z * 15.0 - v.y * 11.0);
      v.multiplyScalar(1 + n);
      for (var q = 0; q < planes.length; q++) {
        var pl = planes[q];
        var d = v.x * pl[0] + v.y * pl[1] + v.z * pl[2];
        if (d > pl[3]) v.addScaledVector(pn.set(pl[0], pl[1], pl[2]), pl[3] - d);
      }
      if (v.y < -0.3) v.y = -0.3 + (v.y + 0.3) * 0.2;
      p.setXYZ(i, v.x * 1.25, v.y * 0.72, v.z);
    }
    var map = {}, pos = [], uv = [], idx = [];
    for (var j = 0; j < p.count; j++) {
      var key = Math.round(p.getX(j) * 1e4) + ',' + Math.round(p.getY(j) * 1e4) + ',' + Math.round(p.getZ(j) * 1e4);
      if (map[key] === undefined) {
        map[key] = pos.length / 3;
        pos.push(p.getX(j), p.getY(j), p.getZ(j));
        uv.push(p.getX(j), p.getZ(j));
      }
      idx.push(map[key]);
    }
    g.dispose();
    var out = new THREE.BufferGeometry();
    out.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    out.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    out.setIndex(idx);
    out.computeVertexNormals();
    return out;
  }

  // ------------------------------------------------------------------ terrain (JS)
  // 2D gradient noise in about [-0.7, 0.7], from a seeded permutation.
  function gradientNoise(rng) {
    var perm = [], p = new Uint16Array(512), gx = new Float32Array(256), gy = new Float32Array(256);
    for (var i = 0; i < 256; i++) {
      perm.push(i);
      var a = rng() * TAU;
      gx[i] = Math.cos(a); gy[i] = Math.sin(a);
    }
    for (var j = 255; j > 0; j--) {
      var k = Math.floor(rng() * (j + 1)), tmp = perm[j];
      perm[j] = perm[k]; perm[k] = tmp;
    }
    for (var m = 0; m < 512; m++) p[m] = perm[m & 255];
    return function (x, y) {
      var xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
      var X = xi & 255, Y = yi & 255;
      var a = p[p[X] + Y], b = p[p[X + 1] + Y], c = p[p[X] + Y + 1], d = p[p[X + 1] + Y + 1];
      var u = xf * xf * xf * (xf * (xf * 6 - 15) + 10), v = yf * yf * yf * (yf * (yf * 6 - 15) + 10);
      var n00 = gx[a] * xf + gy[a] * yf, n10 = gx[b] * (xf - 1) + gy[b] * yf;
      var n01 = gx[c] * xf + gy[c] * (yf - 1), n11 = gx[d] * (xf - 1) + gy[d] * (yf - 1);
      var x0 = n00 + (n10 - n00) * u, x1 = n01 + (n11 - n01) * u;
      return x0 + (x1 - x0) * v;
    };
  }
  // fbm in about [-1, 1]
  function fbm(noise, x, y, oct) {
    var s = 0, a = 1, n = 0;
    for (var o = 0; o < oct; o++) {
      s += a * noise(x, y);
      n += a;
      var nx = 1.6 * x - 1.2 * y + 3.1, ny = 1.2 * x + 1.6 * y - 1.7;
      x = nx; y = ny; a *= 0.5;
    }
    return s / n * 1.6;
  }
  // ridged multifractal in [0, 1]: sharp crests, smoother valleys (each octave weighted by the
  // previous one, as Musgrave's)
  function ridged(noise, x, y, oct) {
    var s = 0, a = 0.5, w = 1, n = 0;
    for (var o = 0; o < oct; o++) {
      var r = 1 - Math.abs(noise(x, y) * 1.45);
      r = Math.max(0, r);
      r *= r;
      s += r * a * w;
      n += a;
      w = Math.min(1, r * 1.8);
      var nx = 1.62 * x - 1.18 * y + 5.3, ny = 1.18 * x + 1.62 * y - 2.9;
      x = nx; y = ny; a *= 0.5;
    }
    return s / n;
  }

  // A chunked polar height field around the origin: azimuth th (0 = toward -z, positive toward
  // +x) in [th0, th1], radius from r0 to r1 (geometric spacing). Bakes per vertex `aBake`:
  // x = visibility of the key light (march toward it over the field), y = occlusion (how far the
  // vertex lies below its surroundings). Outside the grid, the march reads o.fallback(x, z) (e.g.
  // a coarser grid) or o.height. Returns {chunks: [geometry], sample(x, z), normalAt(x, z)}.
  function polarTerrain(o) {
    var nT = o.nTheta, nR = o.nR, H = new Float32Array((nT + 1) * (nR + 1));
    var th = new Float32Array(nT + 1), rr = new Float32Array(nR + 1);
    var k = Math.pow(o.r1 / o.r0, 1 / nR);
    for (var i = 0; i <= nT; i++) th[i] = o.th0 + (o.th1 - o.th0) * i / nT;
    for (var j = 0; j <= nR; j++) rr[j] = o.r0 * Math.pow(k, j);
    for (var jj = 0; jj <= nR; jj++) {
      for (var ii = 0; ii <= nT; ii++) {
        H[jj * (nT + 1) + ii] = o.height(rr[jj] * Math.sin(th[ii]), -rr[jj] * Math.cos(th[ii]));
      }
    }
    var lnk = Math.log(k);
    function sample(x, z) {
      var r = Math.hypot(x, z), a = Math.atan2(x, -z);
      var fi = (a - o.th0) / (o.th1 - o.th0) * nT, fj = Math.log(Math.max(r, 1e-3) / o.r0) / lnk;
      if (fi < 0 || fi > nT || fj < 0 || fj > nR) return o.fallback ? o.fallback(x, z) : o.height(x, z);
      var i0 = Math.min(nT - 1, Math.floor(fi)), j0 = Math.min(nR - 1, Math.floor(fj));
      var u = fi - i0, v = fj - j0, w = nT + 1;
      var h00 = H[j0 * w + i0], h10 = H[j0 * w + i0 + 1], h01 = H[(j0 + 1) * w + i0], h11 = H[(j0 + 1) * w + i0 + 1];
      return (h00 * (1 - u) + h10 * u) * (1 - v) + (h01 * (1 - u) + h11 * u) * v;
    }
    var L = o.light, lh = Math.hypot(L.x, L.z), lx = L.x / lh, lz = L.z / lh, slope = L.y / lh;
    var steps = o.bakeSteps || 22, maxD = o.bakeDistance || 4000;
    var w1 = nT + 1;
    var bake = new Float32Array(w1 * (nR + 1) * 2);
    var nor = new Float32Array(w1 * (nR + 1) * 3);
    for (var b = 0; b <= nR; b++) {
      var r0 = rr[b];
      var dr = rr[Math.min(nR, b + 1)] - rr[Math.max(0, b - 1)];
      for (var a2 = 0; a2 <= nT; a2++) {
        var idx = b * w1 + a2, h = H[idx];
        var x = r0 * Math.sin(th[a2]), z = -r0 * Math.cos(th[a2]);
        // normal from the grid (polar derivatives to cartesian)
        var dhr = (H[Math.min(nR, b + 1) * w1 + a2] - H[Math.max(0, b - 1) * w1 + a2]) / dr;
        var dht = (H[b * w1 + Math.min(nT, a2 + 1)] - H[b * w1 + Math.max(0, a2 - 1)]) / ((th[Math.min(nT, a2 + 1)] - th[Math.max(0, a2 - 1)]) * r0);
        var st = Math.sin(th[a2]), ct = Math.cos(th[a2]);
        var gxx = dhr * st + dht * ct, gzz = -dhr * ct + dht * st;
        var nl = Math.hypot(gxx, 1, gzz);
        nor[idx * 3] = -gxx / nl; nor[idx * 3 + 1] = 1 / nl; nor[idx * 3 + 2] = -gzz / nl;
        // key light: the steepest terrain angle above the ray toward the light
        var occl = -1;
        var d = Math.max(4, r0 * 0.004);
        for (var s = 0; s < steps && d < maxD; s++) {
          var e = (sample(x + lx * d, z + lz * d) - (h + 1.5 + slope * d)) / d;
          if (e > occl) occl = e;
          d *= Math.pow(maxD / 4, 1 / steps);
        }
        bake[idx * 2] = 1 - Math.max(0, Math.min(1, (occl + 0.035) / 0.07));
        // occlusion: mean height of a ring around the vertex
        var R = o.aoRadius ? o.aoRadius(r0) : Math.max(30, r0 * 0.06), sum = 0;
        for (var q = 0; q < 6; q++) sum += sample(x + R * Math.cos(q * 1.047), z + R * Math.sin(q * 1.047));
        bake[idx * 2 + 1] = 1 - Math.max(0, Math.min(0.75, (sum / 6 - h) / (R * 0.9)));
      }
    }
    var chunks = [], per = Math.ceil(nT / (o.chunks || 1));
    for (var c0 = 0; c0 < nT; c0 += per) {
      var c1 = Math.min(nT, c0 + per), cw = c1 - c0 + 1;
      var pos = new Float32Array(cw * (nR + 1) * 3), nn = new Float32Array(cw * (nR + 1) * 3), bb = new Float32Array(cw * (nR + 1) * 2);
      var ind = [];
      for (var jr = 0; jr <= nR; jr++) {
        for (var ic = 0; ic < cw; ic++) {
          var src = jr * w1 + c0 + ic, dst = jr * cw + ic;
          pos[dst * 3] = rr[jr] * Math.sin(th[c0 + ic]); pos[dst * 3 + 1] = H[src]; pos[dst * 3 + 2] = -rr[jr] * Math.cos(th[c0 + ic]);
          nn[dst * 3] = nor[src * 3]; nn[dst * 3 + 1] = nor[src * 3 + 1]; nn[dst * 3 + 2] = nor[src * 3 + 2];
          bb[dst * 2] = bake[src * 2]; bb[dst * 2 + 1] = bake[src * 2 + 1];
          if (jr < nR && ic < cw - 1) {
            var p0 = jr * cw + ic, p1 = p0 + cw;
            ind.push(p0, p0 + 1, p1, p0 + 1, p1 + 1, p1);   // counter-clockwise seen from above
          }
        }
      }
      var g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      g.setAttribute('normal', new THREE.Float32BufferAttribute(nn, 3));
      g.setAttribute('aBake', new THREE.Float32BufferAttribute(bb, 2));
      g.setAttribute('uv', new THREE.Float32BufferAttribute(new Float32Array(cw * (nR + 1) * 2), 2));
      g.setIndex(ind);
      g.computeBoundingSphere();
      g.userData.th = [th[c0], th[c1]];   // azimuth range of the chunk
      chunks.push(g);
    }
    return { chunks: chunks, sample: sample, normalAt: function (x, z) {
      var e = 2;
      var hx = sample(x + e, z) - sample(x - e, z), hz = sample(x, z + e) - sample(x, z - e);
      return new THREE.Vector3(-hx / (2 * e), 1, -hz / (2 * e)).normalize();
    } };
  }

  // ------------------------------------------------------------------ GLSL
  // Night air. Written for the patched three.js materials and for ShaderMaterials (which have
  // uTime, EV_PERIOD, EV_TAU through the runtime's common GLSL).
  var AIR_GLSL = [
    'uniform vec3 uLightDir; uniform vec3 uLightFog; uniform vec3 uFogAmb;',
    'uniform vec4 uFog;',        // haze density at the water (1/m), ground-fog density (1/m), its falloff (1/m), mist level
    'uniform vec4 uMist;',       // band centre y (m), band half-width (m), band density (1/m), noise scale (1/m)
    'uniform vec4 uAirExt;',     // haze falloff (1/m), mist drift x, mist drift z, longest air path (m)
    'uniform sampler2D uNoiseTex;',
    'uniform sampler2DShadow uShadowMap; uniform mat4 uShadowMatrix; uniform float uShadowReady;',
    'float na_phase(float c) {',
    '  float a = 0.3276 / pow(1.6724 - 1.64 * c, 1.5);',
    '  float b = 0.8775 / pow(1.1225 - 0.7 * c, 1.5);',
    '  return (0.78 * a + 0.22 * b) * 0.0796;',
    '}',
    'float na_shadow(vec3 wp) {',
    '  vec4 sc = uShadowMatrix * vec4(wp, 1.0);',
    '  sc.xyz /= sc.w;',
    '  if (uShadowReady < 0.5 || sc.x < 0.0 || sc.x > 1.0 || sc.y < 0.0 || sc.y > 1.0 || sc.z > 1.0) return 1.0;',
    '  return texture(uShadowMap, vec3(sc.xy, sc.z - 0.002));',
    '}',
    // noise drifting over the period and looping (two copies half a period apart, sin^2 weights)
    'float na_loopNoise(vec2 p, vec2 drift) {',
    '  float tau = uTime / EV_PERIOD;',
    '  float s = sin(3.14159265 * tau); vec2 w = vec2(s * s, 1.0 - s * s);',
    '  float a = texture2D(uNoiseTex, p + drift * EV_PERIOD * (fract(tau) - 0.5)).r;',
    '  float b = texture2D(uNoiseTex, p + drift * EV_PERIOD * (fract(tau + 0.5) - 0.5) + vec2(0.37, 0.71)).r;',
    '  float v = w.x * (a - 0.5) + w.y * (b - 0.5);',
    '  return clamp(0.5 + v / sqrt(w.x * w.x + w.y * w.y), 0.0, 1.0);',
    '}',
    // optical depth of a layer of density exp(-k y) along the segment (the mirrored camera of the
    // reflection lies under the water: it starts at the surface)
    'float na_expOD(float y0, float dy, float L, float k) {',
    '  y0 = max(y0, 0.0);',
    '  float a = k * dy * L;',
    '  return exp(-k * y0) * (abs(a) > 1e-4 ? (1.0 - exp(-a)) / (k * dy) : L);',
    '}',
    // optical depth of the mist band (Lorentzian profile) along the segment
    'float na_bandOD(float y0, float dy, float L) {',
    '  float yc = uMist.x, w = uMist.y;',
    '  if (abs(dy) > 1e-4) return w * (atan((y0 + dy * L - yc) / w) - atan((y0 - yc) / w)) / dy;',
    '  float q = (y0 - yc) / w;',
    '  return L / (1.0 + q * q);',
    '}',
    'float na_mistLevel() { return 0.4 + 3.6 * uFog.w; }',
    'vec3 na_air(vec3 col, vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = max(length(d), 1e-3);',
    '  vec3 dir = d / L;',
    '  float ph = na_phase(dot(dir, uLightDir));',
    '  float od = uFog.x * na_expOD(cameraPosition.y, dir.y, L, uAirExt.x) + uFog.y * na_expOD(cameraPosition.y, dir.y, L, uFog.z);',
    '  float T = exp(-od);',
    '  col = col * T + (uFogAmb + uLightFog * ph) * (1.0 - T);',
    '  float odm = na_bandOD(cameraPosition.y, dir.y, L) * uMist.z * na_mistLevel();',
    '  if (odm > 0.002) {',
    '    float lit = 1.0;',
    '#ifndef NA_LOW',
    // patches drifting on the water: the noise where the ray meets the water plane (for the
    // mirrored rays too: the same patches in the reflection), the mean for the rays that do not
    '    float toward = dir.y * sign(uMist.x - cameraPosition.y);',
    '    float wgt = smoothstep(0.004, 0.05, toward);',
    '    if (wgt > 0.0) {',
    '      vec3 pc = cameraPosition + dir * clamp((uMist.x - cameraPosition.y) / dir.y, 0.0, L);',
    '      float n = na_loopNoise(pc.xz * uMist.w, uAirExt.yz);',
    '      odm *= mix(1.0, 0.15 + 3.2 * n * n, wgt);',
    '      lit = mix(1.0, na_shadow(vec3(pc.x, 0.6, pc.z)), wgt);',
    '    }',
    '#endif',
    '    vec3 mist = uFogAmb * 1.5 + uLightFog * ph * (0.1 + 0.9 * lit);',
    '    float Tm = exp(-odm);',
    '    col = col * Tm + mist * (1.0 - Tm);',
    '  }',
    '  return col;',
    '}',
    // the same air for the sky (a ray that leaves the layers)
    'vec3 na_skyAir(vec3 col, vec3 dir) {',
    '  float L = uAirExt.w;',
    '  float ph = na_phase(dot(dir, uLightDir));',
    '  float od = uFog.x * na_expOD(cameraPosition.y, dir.y, L, uAirExt.x) + uFog.y * na_expOD(cameraPosition.y, dir.y, L, uFog.z);',
    '  float T = exp(-od);',
    '  col = col * T + (uFogAmb + uLightFog * ph) * (1.0 - T);',
    '  float Tm = exp(-na_bandOD(cameraPosition.y, dir.y, L) * uMist.z * na_mistLevel());',
    '  return col * Tm + (uFogAmb * 1.5 + uLightFog * ph) * (1.0 - Tm);',
    '}',
    // transmittance only (emissive points, glints)
    'float na_trans(vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = max(length(d), 1e-3);',
    '  vec3 dir = d / L;',
    '  float od = uFog.x * na_expOD(cameraPosition.y, dir.y, L, uAirExt.x) + uFog.y * na_expOD(cameraPosition.y, dir.y, L, uFog.z)',
    '    + na_bandOD(cameraPosition.y, dir.y, L) * uMist.z * na_mistLevel();',
    '  return exp(-od);',
    '}',
  ].join('\n');

  // Bump from a procedural height h (Mikkelsen's surface gradient), view space.
  var BUMP_GLSL = [
    'vec3 na_bump(vec3 n, vec3 surf, float h, float scale) {',
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
    'vec4 naW = vec4(transformed, 1.0);',
    '#ifdef USE_INSTANCING',
    'naW = instanceMatrix * naW;',
    '#endif',
    'vNaWorld = (modelMatrix * naW).xyz;',
    'vNaNormal = normalize(mat3(modelMatrix) * objectNormal);',
  ].join('\n');

  // Light through thin needles and blades, seen against the key light (after the direct lights).
  function translucency(amount, tint) {
    return [
      '#if NUM_DIR_LIGHTS > 0',
      '{',
      '  float naBack = saturate(dot(-geometryViewDir, directLight.direction));',
      '  float naThin = pow(naBack, 4.0) * 0.85 + 0.15 * saturate(dot(-geometryNormal, directLight.direction));',
      '  reflectedLight.directDiffuse += directLight.color * material.diffuseColor * vec3(' + tint.join(', ') + ') * (' + amount + ' * naThin);',
      '}',
      '#endif',
    ].join('\n');
  }

  // Patched three.js materials: the night air, world position and normal, hooks (as the forest v2).
  function pbrFactory(shared, quality) {
    var patched = [];
    var state = { quality: quality };
    function pbr(Kind, params, hooks) {
      var m = new Kind(params);
      hooks = hooks || {};
      m.onBeforeCompile = function (shader) {
        Object.keys(shared).forEach(function (k) { shader.uniforms[k] = shared[k]; });
        Object.assign(shader.uniforms, hooks.uniforms || {});
        var head = 'varying vec3 vNaWorld;\nvarying vec3 vNaNormal;\nvarying vec2 vNaUv;\nuniform float uTime;\n#define EV_PERIOD 30.0\n#define EV_TAU 6.28318530718\n';
        shader.vertexShader = shader.vertexShader
          .replace('#include <common>', '#include <common>\n' + head + (hooks.vertexPars || ''))
          .replace('#include <begin_vertex>', '#include <begin_vertex>\nvNaUv = uv;\n' + (hooks.vertex || ''))
          .replace('#include <project_vertex>', '#include <project_vertex>\n' + WORLD_VERTEX);
        shader.fragmentShader = shader.fragmentShader
          .replace('#include <common>', '#include <common>\n' + head + (state.quality === 'low' ? '#define NA_LOW 1\n' : '') +
            AIR_GLSL + '\n' + BUMP_GLSL + '\n' + (hooks.fragmentPars || ''))
          .replace('#include <map_fragment>', hooks.map || '#include <map_fragment>')
          .replace('#include <color_fragment>', '#include <color_fragment>\n' + (hooks.color || ''))
          .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\n' + (hooks.roughness || ''))
          .replace('#include <normal_fragment_maps>', '#include <normal_fragment_maps>\n' + (hooks.normal || ''))
          .replace('#include <lights_fragment_begin>', '#include <lights_fragment_begin>\n' + (hooks.light || ''))
          .replace('#include <lights_fragment_end>', '#include <lights_fragment_end>\n' +
            'reflectedLight.directSpecular *= ' + (hooks.drySpecular !== undefined ? hooks.drySpecular : 0.25).toFixed(3) + ';\n' +
            (hooks.lightEnd || ''))
          .replace('#include <fog_fragment>', 'gl_FragColor.rgb = na_air(gl_FragColor.rgb, vNaWorld);');
      };
      m.customProgramCacheKey = function () { return 'na-' + hooks.key + '-' + state.quality; };
      patched.push(m);
      return m;
    }
    // texture with R = shade, G = tint, B = snow, A = coverage (sprays)
    function cardMap(tintA, tintB, shadeLo, shadeHi) {
      return [
        'vec4 naTx = texture2D(map, vMapUv);',
        'diffuseColor.rgb *= mix(vec3(' + tintA.join(', ') + '), vec3(' + tintB.join(', ') + '), naTx.g) * mix(' + shadeLo + ', ' + shadeHi + ', naTx.r);',
        'diffuseColor.a *= naTx.a;',
      ].join('\n');
    }
    // a new quality: the materials recompile (alpha to coverage only with the MSAA of 'high')
    function setQuality(q) {
      state.quality = q;
      patched.forEach(function (m) {
        if (m.alphaTest > 0) m.alphaToCoverage = q === 'high';
        m.needsUpdate = true;
      });
    }
    return { pbr: pbr, cardMap: cardMap, patched: patched, setQuality: setQuality };
  }

  // ------------------------------------------------------------------ conifers
  // Near conifers: instanced trunks and card crowns at three levels of detail (as the forest v2).
  // list: [{x, y, z, s, variant (0..2), rot, lod (0..2)}]; returns the meshes (added to the scene
  // by the caller) and a describe() count.
  function cardConifers(K, list, opts) {
    var THREEm = THREE;
    var trunkGeos = [
      trunkGeometry(10, [-0.4, 0, 0.12, 0.35, 0.7, 1.2, 2.0, 3.2, 4.8, 7, 10, 13.5, 17, 20, 22], true),
      trunkGeometry(6, [-0.4, 0, 0.35, 1.2, 3.2, 7, 12, 17, 22], true),
      trunkGeometry(5, [-0.4, 0, 2.5, 8, 15, 22], false),
    ];
    var crownGeos = [[], [], []];
    var used = [false, false, false];
    list.forEach(function (t) { used[t.lod] = true; });
    for (var l = 0; l < 3; l++) {
      for (var v = 0; v < 3; v++) crownGeos[l].push(used[l] ? crownGeometry(v, l, opts.rng('crown' + v + l)) : null);
    }
    var dummy = new THREEm.Matrix4(), q = new THREEm.Quaternion(), e3 = new THREEm.Vector3(), sv = new THREEm.Vector3();
    var euler = new THREEm.Euler();
    function matrix(t, crown) {
      euler.set(t.lean || 0, t.rot, (t.lean || 0) * 0.7);
      q.setFromEuler(euler);
      var k = crown ? (t.cs || 1) : 1;
      return dummy.compose(e3.set(t.x, t.y, t.z), q, sv.set(t.s * k, t.s * (0.95 + 0.1 * ((t.rot * 7) % 1)), t.s * k)).clone();
    }
    var meshes = [];
    for (var lod = 0; lod < 3; lod++) {
      var sub0 = list.filter(function (t) { return t.lod === lod; });
      if (!sub0.length) {
        trunkGeos[lod].dispose();
        continue;
      }
      var trunk = new THREEm.InstancedMesh(trunkGeos[lod], opts.barkMat, sub0.length);
      sub0.forEach(function (t, i) { trunk.setMatrixAt(i, matrix(t)); });
      trunk.castShadow = opts.castShadow !== false;
      trunk.receiveShadow = true;
      trunk.frustumCulled = false;
      meshes.push(trunk);
      for (var vv = 0; vv < 3; vv++) {
        var sub = sub0.filter(function (t) { return t.variant === vv; });
        if (!sub.length) continue;
        var crown = new THREEm.InstancedMesh(crownGeos[lod][vv], opts.needleMat, sub.length);
        sub.forEach(function (t, i) { crown.setMatrixAt(i, matrix(t, true)); });
        crown.castShadow = opts.castShadow !== false;
        crown.receiveShadow = true;
        crown.frustumCulled = false;
        meshes.push(crown);
      }
    }
    for (var l2 = 0; l2 < 3; l2++) {
      for (var v2 = 0; v2 < 3; v2++) {
        var g = crownGeos[l2][v2];
        if (g && !meshes.some(function (m) { return m.geometry === g; })) g.dispose();
      }
    }
    return meshes;
  }

  // Far conifers: camera-facing silhouettes (two triangles each, one draw call), lit by the key
  // light (pseudo-normal across the tree, light through the edges against it), sky light, snow.
  // list: [{x, y, z, h, cell (0..3), wr (width / height), tint (0..1)}]
  function billboardConifers(ctx, shared, list, o) {
    var g = new THREE.InstancedBufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute([-0.5, 0, 0, 0.5, 0, 0, 0.5, 1, 0, -0.5, 0, 0, 0.5, 1, 0, -0.5, 1, 0], 3));
    var a = new Float32Array(list.length * 4), b = new Float32Array(list.length * 4);
    list.forEach(function (t, i) {
      a[i * 4] = t.x; a[i * 4 + 1] = t.y; a[i * 4 + 2] = t.z; a[i * 4 + 3] = t.h;
      b[i * 4] = t.cell; b[i * 4 + 1] = t.wr; b[i * 4 + 2] = t.tint; b[i * 4 + 3] = t.snow || 0;
    });
    g.setAttribute('aPos', new THREE.InstancedBufferAttribute(a, 4));
    g.setAttribute('aVar', new THREE.InstancedBufferAttribute(b, 4));
    g.instanceCount = list.length;
    var vertex = [
      'attribute vec4 aPos; attribute vec4 aVar;',
      'varying vec2 vUv; varying vec3 vWorld; varying vec3 vRight; varying vec3 vVar; varying float vV;',
      'void main() {',
      '  vec3 toCam = cameraPosition - aPos.xyz;',
      '  vec3 right = normalize(vec3(toCam.z, 0.0, -toCam.x));',
      '  float h = aPos.w, w = h * aVar.y;',
      '  vec3 wp = aPos.xyz + right * position.x * w + vec3(0.0, position.y * h, 0.0);',
      '  vUv = vec2((aVar.x + position.x + 0.5) * 0.25, 1.0 - position.y);',
      '  vWorld = wp; vRight = right; vVar = aVar.zwx; vV = position.y;',
      '  gl_Position = projectionMatrix * viewMatrix * vec4(wp, 1.0);',
      '}',
    ].join('\n');
    var m = ctx.material({
      uniforms: Object.assign({}, shared, {
        uAtlas: { value: o.atlas },
        uKey: { value: o.key },            // key light colour x intensity
        uSky: { value: o.sky },            // sky light (irradiance / pi)
        uAlbedo: { value: o.albedo },
        uSnowAlbedo: { value: o.snowAlbedo || new THREE.Vector3(0.8, 0.85, 0.9) },
        uSnow: { value: o.snow || 0 },
        uBack: { value: o.back !== undefined ? o.back : 0.6 },
      }),
      vertexShader: vertex,
      fragmentShader: (ctx.quality === 'low' ? '#define NA_LOW 1\n' : '') + AIR_GLSL + '\n' + [
        'uniform sampler2D uAtlas; uniform vec3 uKey; uniform vec3 uSky; uniform vec3 uAlbedo; uniform vec3 uSnowAlbedo;',
        'uniform float uSnow; uniform float uBack;',
        'varying vec2 vUv; varying vec3 vWorld; varying vec3 vRight; varying vec3 vVar; varying float vV;',
        'void main() {',
        '  vec4 tx = texture2D(uAtlas, vUv);',
        // as three.js with alpha to coverage: a soft edge one pixel wide (the MSAA samples make
        // it), and nothing where the coverage is nil (the reflection has no MSAA)
        '#ifdef NA_LOW',
        '  if (tx.a < 0.5) discard;',
        '  float cov = 1.0;',
        '#else',
        '  float cov = smoothstep(0.5, 0.5 + fwidth(tx.a), tx.a);',
        '  if (cov <= 0.0) discard;',
        '#endif',
        '  vec3 V = normalize(cameraPosition - vWorld);',
        '  float across = (fract(vUv.x * 4.0) - 0.5) * 2.0;',
        '  vec3 n = normalize(vRight * across * 0.85 + vec3(0.0, 0.4, 0.0) + vec3(V.x, 0.0, V.z) * 0.55);',
        '  vec3 alb = uAlbedo * mix(0.55, 1.25, tx.r) * mix(0.8, 1.2, vVar.x);',
        '  float snow = tx.b * uSnow * (0.6 + 0.4 * vVar.y);',
        // snow lies on the upper surfaces of the boughs: it faces the sky
        '  float ndl = dot(normalize(n + vec3(0.0, 1.8 * snow, 0.0)), uLightDir);',
        '  alb = mix(alb, uSnowAlbedo, snow);',
        '  vec3 c = alb * uSky * (0.35 + 0.65 * vV) * (0.75 + 0.25 * n.y + 0.4 * snow);',
        '  c += alb * uKey * max(ndl, 0.0) * 0.3183;',
        // light through the thin outer needles (the soft edge of the silhouette) against the light
        '  float back = pow(max(dot(-V, uLightDir), 0.0), 6.0);',
        '  c += uKey * uAlbedo * back * uBack * (1.0 - smoothstep(0.5, 0.95, tx.a)) * 2.0;',
        '  c = na_air(c, vWorld);',
        '  gl_FragColor = vec4(c, cov);',
        '}',
      ].join('\n'),
    });
    m.alphaToCoverage = ctx.quality === 'high';
    m.transparent = false;
    var mesh = new THREE.Mesh(g, m);
    mesh.frustumCulled = false;
    if (o.castShadow) {
      // into the key light's shadow map: the same silhouettes, turned toward the light (the shadow
      // camera is cameraPosition there), cut out by their coverage
      mesh.customDepthMaterial = ctx.material({
        uniforms: { uAtlas: { value: o.atlas } },
        vertexShader: vertex,
        fragmentShader: [
          'uniform sampler2D uAtlas;',
          'varying vec2 vUv;',
          'void main() { if (texture2D(uAtlas, vUv).a < 0.5) discard; gl_FragColor = vec4(1.0); }',
        ].join('\n'),
      });
      m.shadowSide = THREE.DoubleSide;   // (three.js would draw the back faces into the map)
      mesh.castShadow = true;
    }
    return mesh;
  }

  // ------------------------------------------------------------------ water
  // Fragment shader of the lake (for ctx.mirror): ripples from three octaves of the ripple texture
  // (each sliding whole tiles per period), Fresnel between the HDR reflection (already lit and
  // fogged along the mirrored path) and the dark water body, the key light's glitter. Defines:
  // NA_GLINT (glitter of the key light).
  var WATER_GLSL = [
    'uniform sampler2D uRipple; uniform vec3 uDeep; uniform vec3 uGlint;',
    'uniform vec4 uWave;',        // amplitude (near), amplitude (far), distance of the change (m), reflection distortion
    'uniform vec4 uTiles;',       // tile size of the three octaves (m), slope scale
    'uniform float uQuiet;',      // glints kept in the lower third of the screen
    'varying vec4 vMirror; varying vec3 vWorld;',
    'void main() {',
    '  vec3 toCam = cameraPosition - vWorld;',
    '  float dist = length(toCam);',
    '  vec3 V = toCam / dist;',
    '  float T = uTime / EV_PERIOD;',
    '  vec2 p = vWorld.xz * vec2(0.62, 1.0);',
    '  vec2 uv1 = p / uTiles.x + vec2(0.0, 1.0) * T;',
    '  vec2 uv2 = p / uTiles.y + vec2(1.0, 1.0) * T + 0.31;',
    '  vec2 uv3 = p / uTiles.z + vec2(-1.0, 2.0) * T + 0.67;',
    '  float a1 = 1.0, a2 = 0.7, a3 = 0.45;',
    '  vec2 g = (texture2D(uRipple, uv1).rg - 0.5) * a1 + (texture2D(uRipple, uv2).rg - 0.5) * a2 + (texture2D(uRipple, uv3).rg - 0.5) * a3;',
    '  float amp = mix(uWave.x, uWave.y, smoothstep(4.0, uWave.z, dist)) * uTiles.w;',
    '  g *= amp;',
    // the slopes the mipmaps averaged out (ripples smaller than a pixel) become roughness
    '  vec3 fp = vec3(length(fwidth(uv1)), length(fwidth(uv2)), length(fwidth(uv3))) * 128.0;',
    '  vec3 lost = smoothstep(vec3(0.6), vec3(7.0), fp);',
    '  float s2 = (lost.x * a1 * a1 + lost.y * a2 * a2 + lost.z * a3 * a3) * amp * amp * 0.03;',
    '  vec3 n = normalize(vec3(-g.x * 0.62, 1.0, -g.y));',
    '  vec2 uv = vMirror.xy / vMirror.w + n.xz * vec2(0.6, 1.0) * uWave.w;',
    '  vec3 refl = ev_mirror(uv);',
    '  float nv = max(dot(V, n), 0.0);',
    '  float F = 0.02 + 0.98 * pow(1.0 - nv, 5.0);',
    '  vec3 c = refl * F + na_air(uDeep, vWorld) * (1.0 - F);',
    '#ifdef NA_GLINT',
    // glitter: anisotropic Beckmann microfacets (the ripples run across the view: smaller slopes
    // along x), the key light a disc that widens the lobe; facets smaller than the ripples flash
    // at fixed times (whole numbers of flashes a period), averaged out once smaller than a pixel
    '  vec3 Hh = normalize(uLightDir + V);',
    '  vec3 tx = normalize(vec3(1.0, 0.0, 0.0) - n * n.x);',
    '  vec3 tz = cross(tx, n);',
    '  float hn = max(dot(Hh, n), 1e-3);',
    '  float sx = dot(Hh, tx) / hn, sz = dot(Hh, tz) / hn;',
    '  float az2 = 0.0011 + s2, ax2 = 0.0011 + s2 * 0.38;',
    '  float D = exp(-(sx * sx / ax2 + sz * sz / az2)) / (3.14159 * sqrt(ax2 * az2) * hn * hn * hn * hn);',
    '  float Fl = 0.02 + 0.98 * pow(1.0 - max(dot(V, Hh), 0.0), 5.0);',
    '  vec2 cq = vWorld.xz * vec2(2.0, 0.9);',
    '  vec2 ci = floor(cq);',
    '  float hs = ev_hash12(ci + 17.0);',
    '  float fl = pow(max(0.0, sin(EV_TAU * (floor(2.0 + hs * 5.0) * uTime / EV_PERIOD + hs * 7.31))), 12.0);',
    // a round spot at a random place of its cell (a twenty-fifth of it; the mean stays 1)
    '  vec2 cj = vec2(ev_hash12(ci + 3.1), ev_hash12(ci + 7.7)) * 0.6 + 0.2;',
    '  float spot = 1.0 - smoothstep(0.08, 0.26, length((fract(cq) - cj) * vec2(1.0, 2.2)));',
    '  float sp = mix(0.7 + 60.0 * fl * spot, 1.0, smoothstep(0.35, 1.4, fwidth(cq.x)));',
    '  float sy = gl_FragCoord.y / uViewport.y;',
    '  float quiet = mix(uQuiet, 1.0, smoothstep(0.22, 0.36, sy)) * smoothstep(0.03, 0.16, sy);',
    '  c += uGlint * D * Fl * sp / (4.0 * max(nv, 0.08)) * na_trans(vWorld) * quiet;',
    '#endif',
    '  gl_FragColor = vec4(c, 1.0);',
    '}',
  ].join('\n');

  // ShaderMaterials built with the night air: recompile them with (low) or without its light path
  function setLowAir(materials, low) {
    materials.forEach(function (m) {
      var fs = m.fragmentShader.replace('#define NA_LOW 1\n', '');
      m.fragmentShader = (low ? '#define NA_LOW 1\n' : '') + fs;
      m.needsUpdate = true;
    });
  }

  window.EventideScenery = window.EventideScenery || {};
  window.EventideScenery.nature = {
    setLowAir: setLowAir,
    TREE_H: TREE_H,
    lin: lin,
    dataTexture: dataTexture,
    noiseTexture: noiseTexture,
    sprayTexture: sprayTexture,
    silhouetteTexture: silhouetteTexture,
    rippleTexture: rippleTexture,
    trunkGeometry: trunkGeometry,
    crownGeometry: crownGeometry,
    rockGeometry: rockGeometry,
    VARIANTS: VARIANTS,
    gradientNoise: gradientNoise,
    fbm: fbm,
    ridged: ridged,
    polarTerrain: polarTerrain,
    AIR_GLSL: AIR_GLSL,
    BUMP_GLSL: BUMP_GLSL,
    WATER_GLSL: WATER_GLSL,
    translucency: translucency,
    pbrFactory: pbrFactory,
    cardConifers: cardConifers,
    billboardConifers: billboardConifers,
  };
})();
