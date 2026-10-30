/*
 * Eventide « Imaginaire »: the decor elements the user adds to a 3D scene (catalog `decors`).
 *
 * Each factory takes (ctx, options) and returns {object, setLevel(0..1), update?(t)}. Everything
 * moves in the vertex shaders as a pure function of uTime (seconds, modulo 30): positions loop
 * a whole number of times per period, so the period loops without a seam. The level sets the
 * density (each element has a rank in [0, 1] and shows when level > rank, with a soft fade) and
 * the intensity. One draw call per decor (two for the sun rays, which carry their dust).
 */
(function () {
  'use strict';

  var THREE = window.THREE;
  var TAU = Math.PI * 2;

  // GLSL shared by the decor shaders (after GLSL.common): both stages, then vertex only.
  var DECOR_GLSL = [
    'uniform float uLevel;',
    'float ev_present(float rank) {',
    '  return clamp((uLevel * uDensity * 1.12 - rank) / 0.12, 0.0, 1.0);',
    '}',
  ].join('\n');
  var DECOR_VERT = [
    'mat3 ev_rotAxis(vec3 a, float ang) {',
    '  float s = sin(ang); float c = cos(ang); float oc = 1.0 - c;',
    '  return mat3(oc * a.x * a.x + c, oc * a.x * a.y + a.z * s, oc * a.z * a.x - a.y * s,',
    '              oc * a.x * a.y - a.z * s, oc * a.y * a.y + c, oc * a.y * a.z + a.x * s,',
    '              oc * a.z * a.x + a.y * s, oc * a.y * a.z - a.x * s, oc * a.z * a.z + c);',
    '}',
    // Clip-space corner of a screen-aligned streak from head to tail (view space), width in px.
    'vec4 ev_streak(vec3 headView, vec3 tailView, vec2 corner, float widthPx) {',
    '  vec4 hc = projectionMatrix * vec4(headView, 1.0);',
    '  vec4 tc = projectionMatrix * vec4(tailView, 1.0);',
    '  vec2 aspect = vec2(uViewport.x / uViewport.y, 1.0);',
    '  vec2 d = (hc.xy / hc.w - tc.xy / tc.w) * aspect;',
    '  float len = length(d);',
    '  vec2 dir = len > 1e-6 ? d / len : vec2(0.0, 1.0);',
    '  vec2 side = vec2(-dir.y, dir.x) / aspect;',
    '  vec4 c = mix(hc, tc, corner.y);',
    '  c.xy += side * corner.x * widthPx / uViewport.y * c.w;',
    '  return c;',
    '}',
  ].join('\n');

  function levelUniform() {
    return { value: 0 };
  }

  function v3(a) {
    return new THREE.Vector3(a[0], a[1], a[2]);
  }

  function boxUniforms(box) {
    return { uBoxMin: { value: v3(box.min) }, uBoxMax: { value: v3(box.max) } };
  }

  function pick(r, range) {
    return range[0] + r() * (range[1] - range[0]);
  }

  function pickInt(r, range) {
    return Math.floor(range[0] + r() * (range[1] - range[0] + 1 - 1e-9));
  }

  function quadCorners(across) {
    // two triangles; corner.x across (-1..1), corner.y along (0..1)
    var g = new THREE.InstancedBufferGeometry();
    var c = across
      ? [-1, 0, 1, 0, 1, 1, -1, 0, 1, 1, -1, 1]
      : [-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1];
    g.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(c.length / 2 * 3), 3));
    g.setAttribute('corner', new THREE.Float32BufferAttribute(c, 2));
    return g;
  }

  function instanced(g, name, data, size) {
    g.setAttribute(name, new THREE.InstancedBufferAttribute(new Float32Array(data), size));
  }

  function finish(object, uLevel, extra) {
    object.frustumCulled = false;
    object.visible = false;
    var decor = {
      object: object,
      setLevel: function (v) { uLevel.value = v; if (extra && extra.onLevel) extra.onLevel(v); },
    };
    if (extra && extra.update) decor.update = extra.update;
    return decor;
  }

  function mat(ctx, uLevel, params) {
    params.uniforms = Object.assign({ uLevel: uLevel }, params.uniforms || {});
    return ctx.material({
      uniforms: params.uniforms,
      vertexShader: DECOR_GLSL + '\n' + DECOR_VERT + '\n' + params.vertexShader,
      fragmentShader: DECOR_GLSL + '\n' + params.fragmentShader,
      transparent: true,
      depthWrite: false,
      blending: params.blending !== undefined ? params.blending : THREE.AdditiveBlending,
      side: params.side !== undefined ? params.side : THREE.FrontSide,
    });
  }

  // ------------------------------------------------------------------ lucioles (fireflies)
  // Warm points of light drifting slowly, each glowing in slow pulses.
  function lucioles(ctx, o) {
    o = Object.assign({ count: 140, size: 0.11, amp: [0.5, 0.3, 0.5], color: '#e9f7a0', lowBias: 1.6 }, o);
    var r = ctx.rng('lucioles');
    var pos = [], a = [], b = [];
    for (var i = 0; i < o.count; i++) {
      pos.push(pick(r, [o.box.min[0], o.box.max[0]]),
        o.box.min[1] + Math.pow(r(), o.lowBias) * (o.box.max[1] - o.box.min[1]),
        pick(r, [o.box.min[2], o.box.max[2]]));
      a.push(r(), r(), r(), r());                 // rank, phases
      b.push(pickInt(r, [2, 5]), r(), r(), r()); // pulses per period, pulse phase, size, warmth
    }
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('aA', new THREE.Float32BufferAttribute(a, 4));
    g.setAttribute('aB', new THREE.Float32BufferAttribute(b, 4));
    var uLevel = levelUniform();
    var m = mat(ctx, uLevel, {
      uniforms: { uColor: { value: ctx.color(o.color) }, uSize: { value: o.size }, uAmp: { value: v3(o.amp) } },
      vertexShader: [
        'uniform float uSize; uniform vec3 uAmp;',
        'attribute vec4 aA; attribute vec4 aB;',
        'varying float vAlpha; varying float vWarm;',
        'void main() {',
        '  float T = EV_TAU * uTime / EV_PERIOD;',
        '  vec3 p = position;',
        '  p.x += uAmp.x * (0.7 * sin(T + aA.y * EV_TAU) + 0.3 * sin(2.0 * T + aA.z * EV_TAU));',
        '  p.y += uAmp.y * (0.6 * sin(2.0 * T + aA.z * EV_TAU) + 0.4 * sin(3.0 * T + aA.w * EV_TAU));',
        '  p.z += uAmp.z * (0.8 * cos(T + aA.w * EV_TAU) + 0.2 * sin(2.0 * T + aA.y * EV_TAU));',
        '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  float pulse = 0.5 + 0.5 * sin(T * aB.x + aB.y * EV_TAU);',
        '  pulse = pulse * pulse * pulse;',
        '  float near = smoothstep(0.35, 1.2, -mv.z);',
        '  vAlpha = ev_present(aA.x) * (0.2 + 0.8 * pulse) * near * (0.55 + 0.45 * uLevel);',
        '  vWarm = aB.w;',
        '  gl_PointSize = min(uSize * (0.7 + 0.6 * aB.z) * uFocal / max(-mv.z, 0.1), 96.0 * uPixelRatio);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor;',
        'varying float vAlpha; varying float vWarm;',
        'void main() {',
        '  vec2 d = gl_PointCoord - 0.5;',
        '  float r2 = dot(d, d) * 4.0;',
        '  float core = exp(-r2 * 20.0);',
        '  float halo = exp(-r2 * 4.0) * 0.42;',
        '  vec3 c = mix(uColor, vec3(1.0, 0.86, 0.55), vWarm * 0.45);',
        '  gl_FragColor = vec4(c * (core * 1.25 + halo) * vAlpha, 1.0);',
        '}',
      ].join('\n'),
    });
    return finish(new THREE.Points(g, m), uLevel);
  }

  // ------------------------------------------------------------------ etoiles (stars)
  // Stars on a dome, a few bright ones and many faint; slow twinkle; optional dense band.
  function etoiles(ctx, o) {
    o = Object.assign({
      count: 1300, radius: 900, azimuth: [0, 60], elevation: [4, 80], size: 1.0,
      band: null, tint: ['#cfe0ff', '#fff4e0'], brightness: 1.0,
    }, o);
    var r = ctx.rng('etoiles');
    var pos = [], a = [];
    function push(az, el, bright, rank) {
      var ca = Math.cos(el);
      pos.push(o.radius * Math.sin(az) * ca, o.radius * Math.sin(el), -o.radius * Math.cos(az) * ca);
      a.push(rank, bright, pickInt(r, [3, 9]), r());
    }
    var s0 = Math.sin(THREE.MathUtils.degToRad(o.elevation[0]));
    var s1 = Math.sin(THREE.MathUtils.degToRad(o.elevation[1]));
    for (var i = 0; i < o.count; i++) {
      var az = THREE.MathUtils.degToRad(o.azimuth[0] + (r() * 2 - 1) * o.azimuth[1]);
      var el = Math.asin(s0 + r() * (s1 - s0));
      var bright = Math.pow(r(), 3.2);
      push(az, el, bright, Math.min(1, r() * 0.75 + (1 - bright) * 0.3));
    }
    if (o.band) {
      // a great circle tilted across the sky: dense faint stars around it
      var n = v3(o.band.normal).normalize();
      var u = new THREE.Vector3(0, 1, 0).cross(n);
      if (u.lengthSq() < 1e-6) u.set(1, 0, 0);
      u.normalize();
      var w = new THREE.Vector3().crossVectors(n, u).normalize();
      var p = new THREE.Vector3();
      for (var j = 0; j < o.band.count; j++) {
        var ang = r() * TAU;
        var off = (r() + r() + r() - 1.5) * o.band.width;
        p.copy(u).multiplyScalar(Math.cos(ang)).addScaledVector(w, Math.sin(ang)).addScaledVector(n, off).normalize();
        if (p.y < s0 || p.y > s1) continue;
        var az2 = Math.atan2(p.x, -p.z);
        var dAz = THREE.MathUtils.radToDeg(az2) - o.azimuth[0];
        dAz = ((dAz + 540) % 360) - 180;
        if (Math.abs(dAz) > o.azimuth[1]) continue;
        push(az2, Math.asin(p.y), Math.pow(r(), 5.0) * 0.5, r());
      }
    }
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('aA', new THREE.Float32BufferAttribute(a, 4));
    var uLevel = levelUniform();
    var m = mat(ctx, uLevel, {
      uniforms: {
        uSize: { value: o.size }, uBright: { value: o.brightness },
        uTintA: { value: ctx.color(o.tint[0]) }, uTintB: { value: ctx.color(o.tint[1]) },
      },
      vertexShader: [
        'uniform float uSize; uniform float uBright;',
        'attribute vec4 aA;',
        'varying float vAlpha; varying float vTint; varying float vSharp;',
        'void main() {',
        '  vec4 mv = modelViewMatrix * vec4(position, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  float tw = 0.5 + 0.5 * ev_wave(aA.z, aA.w, uTime);',
        '  float amp = mix(0.45, 0.2, aA.y);',
        '  vAlpha = ev_present(aA.x) * (0.22 + 0.78 * aA.y) * (1.0 - amp + amp * tw) * uBright * (0.6 + 0.4 * uLevel);',
        '  vTint = fract(aA.w * 7.31);',
        '  float px = uSize * (1.6 + 4.2 * aA.y) * uViewport.y / 1920.0;',
        '  vSharp = clamp(px / 3.0, 0.0, 1.0);',
        '  gl_PointSize = max(px * 2.2, 1.0);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uTintA; uniform vec3 uTintB;',
        'varying float vAlpha; varying float vTint; varying float vSharp;',
        'void main() {',
        '  vec2 d = gl_PointCoord - 0.5;',
        '  float r2 = dot(d, d) * 4.0;',
        '  float core = exp(-r2 * 9.0);',
        '  float halo = exp(-r2 * 2.5) * 0.18 * vSharp;',
        '  vec3 c = mix(uTintA, uTintB, vTint);',
        '  gl_FragColor = vec4(c * (core + halo) * vAlpha, 1.0);',
        '}',
      ].join('\n'),
    });
    var pts = new THREE.Points(g, m);
    pts.renderOrder = -5;
    return finish(pts, uLevel);
  }

  // ------------------------------------------------------------------ etoiles-filantes
  // A few meteors a period (at fixed times), crossing the upper sky with a fading tail.
  function etoilesFilantes(ctx, o) {
    o = Object.assign({ count: 6, radius: 800, azimuth: [0, 28], elevation: [30, 70], color: '#f4f8ff', width: 2.4 }, o);
    var r = ctx.rng('filantes');
    var g = quadCorners(true);
    var ev = [], start = [], dir = [];
    var slot = 30 / o.count;
    var ranks = [0.05, 0.55, 0.3, 0.8, 0.18, 0.68, 0.42, 0.92];
    for (var i = 0; i < o.count; i++) {
      ev.push((i * slot + r() * slot * 0.6 + 1.0) % 30, pick(r, [0.7, 1.25]), ranks[i % ranks.length], pick(r, [0.6, 1.0]));
      start.push(THREE.MathUtils.degToRad(o.azimuth[0] + (r() * 2 - 1) * o.azimuth[1]),
        THREE.MathUtils.degToRad(pick(r, o.elevation)), pick(r, [0.12, 0.2]), 0);
      var side = r() < 0.5 ? -1 : 1;
      var ang = THREE.MathUtils.degToRad(pick(r, [20, 45]));
      dir.push(side * Math.cos(ang), -Math.sin(ang), pick(r, [0.18, 0.32]), 0);
    }
    instanced(g, 'aEv', ev, 4);
    instanced(g, 'aStart', start, 4);
    instanced(g, 'aDir', dir, 4);
    g.instanceCount = o.count;
    var uLevel = levelUniform();
    var m = mat(ctx, uLevel, {
      uniforms: { uColor: { value: ctx.color(o.color) }, uRadius: { value: o.radius }, uWidth: { value: o.width } },
      vertexShader: [
        'uniform float uRadius; uniform float uWidth;',
        'attribute vec2 corner; attribute vec4 aEv; attribute vec4 aStart; attribute vec4 aDir;',
        'varying float vAlong; varying float vAcross; varying float vAlpha;',
        'vec3 dome(vec2 ae) { float c = cos(ae.y); return uRadius * vec3(sin(ae.x) * c, sin(ae.y), -cos(ae.x) * c); }',
        'void main() {',
        '  float dt = mod(uTime - aEv.x, EV_PERIOD);',
        '  float p = dt / aEv.y;',
        '  if (p > 1.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vAlpha = 0.0; vAlong = 0.0; vAcross = 0.0; return; }',
        '  vec2 d = aDir.xy * aDir.z;',
        '  vec2 head = aStart.xy + d * p;',
        '  vec2 tail = head - d * aStart.z / aDir.z * min(1.0, p * 2.5) * 0.9;',
        '  vec3 hv = (modelViewMatrix * vec4(dome(head), 1.0)).xyz;',
        '  vec3 tv = (modelViewMatrix * vec4(dome(tail), 1.0)).xyz;',
        '  gl_Position = ev_streak(hv, tv, corner, uWidth * uViewport.y / 1920.0 * 2.0);',
        '  vAlong = corner.y; vAcross = corner.x;',
        '  vAlpha = ev_present(aEv.z) * aEv.w * pow(sin(3.14159 * p), 0.8);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor;',
        'varying float vAlong; varying float vAcross; varying float vAlpha;',
        'void main() {',
        '  float along = pow(1.0 - vAlong, 2.2);',
        '  float across = exp(-vAcross * vAcross * 5.0);',
        '  gl_FragColor = vec4(uColor * along * across * vAlpha * 1.3, 1.0);',
        '}',
      ].join('\n'),
    });
    var mesh = new THREE.Mesh(g, m);
    mesh.renderOrder = -4;
    return finish(mesh, uLevel);
  }

  // ------------------------------------------------------------------ neige (snow)
  function neige(ctx, o) {
    o = Object.assign({ count: 1500, size: [0.018, 0.05], fall: [1, 2], sway: 0.35, color: '#eef3ff', opacity: 0.85 }, o);
    var r = ctx.rng('neige');
    var pos = [], a = [], b = [];
    for (var i = 0; i < o.count; i++) {
      pos.push(r(), r(), r());
      a.push(r(), pickInt(r, o.fall), r(), pick(r, o.size));          // rank, k fall, phase, size
      b.push(pickInt(r, [1, 3]), r(), r(), pick(r, [0.4, 1.0]));       // sway k, sway phases, sway amp
    }
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('aA', new THREE.Float32BufferAttribute(a, 4));
    g.setAttribute('aB', new THREE.Float32BufferAttribute(b, 4));
    var uLevel = levelUniform();
    var u = boxUniforms(o.box);
    u.uColor = { value: ctx.color(o.color) };
    u.uSway = { value: o.sway };
    u.uOpacity = { value: o.opacity };
    var m = mat(ctx, uLevel, {
      blending: THREE.NormalBlending,
      uniforms: u,
      vertexShader: [
        'uniform vec3 uBoxMin; uniform vec3 uBoxMax; uniform float uSway;',
        'attribute vec4 aA; attribute vec4 aB;',
        'varying float vAlpha; varying float vSoft;',
        'void main() {',
        '  vec3 size = uBoxMax - uBoxMin;',
        '  float ph = fract(aA.z + aA.y * uTime / EV_PERIOD);',
        '  vec3 p = uBoxMin + position * size;',
        '  p.y = uBoxMax.y - ph * size.y;',
        '  float T = EV_TAU * uTime / EV_PERIOD;',
        '  p.x += uSway * aB.w * sin(T * aB.x + aB.y * EV_TAU);',
        '  p.z += uSway * aB.w * 0.6 * cos(T * aB.x + aB.z * EV_TAU);',
        '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  float dist = -mv.z;',
        '  float env = smoothstep(0.0, 0.08, ph) * smoothstep(1.0, 0.9, ph);',
        '  float near = smoothstep(0.5, 1.6, dist);',
        '  float px = aA.w * uFocal / max(dist, 0.1);',
        '  vSoft = clamp((px - 3.0) / 30.0, 0.0, 1.0);',
        '  vAlpha = ev_present(aA.x) * env * near * mix(1.0, 0.45, vSoft);',
        '  gl_PointSize = clamp(px, 1.5, 64.0 * uPixelRatio);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor; uniform float uOpacity;',
        'varying float vAlpha; varying float vSoft;',
        'void main() {',
        '  float r = length(gl_PointCoord - 0.5) * 2.0;',
        '  float a = 1.0 - smoothstep(mix(0.35, 0.05, vSoft), 1.0, r);',
        '  gl_FragColor = vec4(ev_dither(uColor), a * vAlpha * uOpacity);',
        '}',
      ].join('\n'),
    });
    return finish(new THREE.Points(g, m), uLevel);
  }

  // ------------------------------------------------------------------ pluie (rain)
  function pluie(ctx, o) {
    o = Object.assign({ count: 900, speed: [7, 10], length: [0.35, 0.6], wind: [0.12, 0.0], color: '#c9d6e6', opacity: 0.28, width: 1.6 }, o);
    var r = ctx.rng('pluie');
    var height = o.box.max[1] - o.box.min[1];
    var g = quadCorners(true);
    var a = [], b = [];
    for (var i = 0; i < o.count; i++) {
      var k = Math.max(1, Math.round(pick(r, o.speed) * 30 / height));
      a.push(r(), r(), r(), r());                       // x, z, phase, rank
      b.push(k, pick(r, o.length), pick(r, [0.5, 1.0]), 0); // cycles per period, length, brightness
    }
    instanced(g, 'aA', a, 4);
    instanced(g, 'aB', b, 4);
    g.instanceCount = o.count;
    var uLevel = levelUniform();
    var u = boxUniforms(o.box);
    u.uColor = { value: ctx.color(o.color) };
    u.uWind = { value: new THREE.Vector2(o.wind[0], o.wind[1]) };
    u.uOpacity = { value: o.opacity };
    u.uWidth = { value: o.width };
    var m = mat(ctx, uLevel, {
      uniforms: u,
      vertexShader: [
        'uniform vec3 uBoxMin; uniform vec3 uBoxMax; uniform vec2 uWind; uniform float uWidth;',
        'attribute vec2 corner; attribute vec4 aA; attribute vec4 aB;',
        'varying float vAlong; varying float vAcross; varying float vAlpha;',
        'void main() {',
        '  vec3 size = uBoxMax - uBoxMin;',
        '  float ph = fract(aA.z + aB.x * uTime / EV_PERIOD);',
        '  vec3 dir = normalize(vec3(uWind.x, -1.0, uWind.y));',
        '  vec3 head = uBoxMin + vec3(aA.x * size.x, (1.0 - ph) * size.y, aA.y * size.z);',
        '  head.xz += vec2(uWind.x, uWind.y) * (ph - 0.5) * size.y;',
        '  vec3 tail = head - dir * aB.y;',
        '  vec3 hv = (modelViewMatrix * vec4(head, 1.0)).xyz;',
        '  vec3 tv = (modelViewMatrix * vec4(tail, 1.0)).xyz;',
        '  float dist = -hv.z;',
        '  if (dist < 0.3 || -tv.z < 0.3) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); vAlpha = 0.0; vAlong = 0.0; vAcross = 0.0; return; }',
        '  float w = max(uWidth * uPixelRatio, 0.012 * uFocal / dist);',
        '  gl_Position = ev_streak(hv, tv, corner, w);',
        '  float env = smoothstep(0.0, 0.05, ph) * smoothstep(1.0, 0.95, ph);',
        '  vAlpha = ev_present(aA.w) * env * aB.z * smoothstep(0.5, 2.0, dist) * (0.55 + 0.45 * uLevel);',
        '  vAlpha *= min(1.0, 2.2 / (0.6 + w));',
        '  vAlong = corner.y; vAcross = corner.x;',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor; uniform float uOpacity;',
        'varying float vAlong; varying float vAcross; varying float vAlpha;',
        'void main() {',
        '  float across = 1.0 - vAcross * vAcross;',
        '  float along = smoothstep(0.0, 0.2, vAlong) * smoothstep(1.0, 0.45, vAlong);',
        '  gl_FragColor = vec4(uColor * across * along * vAlpha * uOpacity, 1.0);',
        '}',
      ].join('\n'),
    });
    return finish(new THREE.Mesh(g, m), uLevel);
  }

  // ------------------------------------------------------------------ feuilles / petales
  // Small two-sided flakes tumbling down (and across, with wind), lit from one direction.
  function flakes(ctx, o, salt) {
    var r = ctx.rng(salt);
    var g = quadCorners(false);
    var a = [], b = [], c = [], d = [];
    for (var i = 0; i < o.count; i++) {
      a.push(r(), r(), r(), r());                                           // x, z, phase, rank
      b.push(pickInt(r, o.fall), pickInt(r, o.drift), pickInt(r, o.spin), pickInt(r, [2, 5])); // fall k, drift k, spin k, flutter k
      c.push(r(), r(), r(), r());                                           // axis, phases
      d.push(pick(r, o.size), r(), pick(r, o.sway), pickInt(r, [1, 3]));    // size, colour, sway amp, sway k
    }
    instanced(g, 'aA', a, 4);
    instanced(g, 'aB', b, 4);
    instanced(g, 'aC', c, 4);
    instanced(g, 'aD', d, 4);
    g.instanceCount = o.count;
    var uLevel = levelUniform();
    var u = boxUniforms(o.box);
    Object.assign(u, {
      uColorA: { value: ctx.color(o.colors[0]) },
      uColorB: { value: ctx.color(o.colors[1]) },
      uColorC: { value: ctx.color(o.colors[2] || o.colors[1]) },
      uLightDir: { value: v3(o.lightDir).normalize() },
      uLight: { value: ctx.color(o.light) },
      uAmbient: { value: ctx.color(o.ambient) },
      uFog: { value: ctx.color(o.fog || '#000000') },
      uFogDensity: { value: o.fogDensity || 0 },
      uShape: { value: o.shape === 'petal' ? 1 : 0 },
      uOpacity: { value: o.opacity || 1 },
    });
    var m = mat(ctx, uLevel, {
      blending: THREE.NormalBlending,
      side: THREE.DoubleSide,
      uniforms: u,
      vertexShader: [
        'uniform vec3 uBoxMin; uniform vec3 uBoxMax; uniform float uShape;',
        'attribute vec2 corner; attribute vec4 aA; attribute vec4 aB; attribute vec4 aC; attribute vec4 aD;',
        'varying vec2 vUv; varying vec3 vNormal; varying vec3 vView; varying float vAlpha; varying float vMix; varying float vDist;',
        'void main() {',
        '  vec3 size = uBoxMax - uBoxMin;',
        '  float ph = fract(aA.z + aB.x * uTime / EV_PERIOD);',
        '  float dx = aB.y > 0.5 ? fract(aA.x + aB.y * uTime / EV_PERIOD) : aA.x;',
        '  vec3 p = vec3(uBoxMin.x + dx * size.x, uBoxMax.y - ph * size.y, uBoxMin.z + aA.y * size.z);',
        '  float T = EV_TAU * uTime / EV_PERIOD;',
        '  p.x += aD.z * sin(T * aD.w + aC.z * EV_TAU);',
        '  p.z += aD.z * 0.5 * cos(T * aD.w + aC.w * EV_TAU);',
        '  float th = aC.x * EV_TAU; float el = (aC.y - 0.5) * 2.4;',
        '  vec3 axis = normalize(vec3(sin(th) * cos(el), sin(el), cos(th) * cos(el)));',
        '  float ang = EV_TAU * (aB.z * uTime / EV_PERIOD + aC.z);',
        '  float flutter = 0.55 * sin(EV_TAU * (aB.w * uTime / EV_PERIOD + aC.w));',
        '  mat3 R = ev_rotAxis(axis, ang) * ev_rotAxis(vec3(1.0, 0.0, 0.0), flutter);',
        '  vec2 q = corner * vec2(uShape > 0.5 ? 0.78 : 0.55, 1.0);',
        '  vec3 local = vec3(q * aD.x, (corner.x * corner.x) * 0.22 * aD.x);',
        '  vec3 wp = p + R * local;',
        '  vec4 mv = modelViewMatrix * vec4(wp, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  vNormal = normalize(R * vec3(-corner.x * 0.35, 0.0, 1.0));',
        '  vView = normalize(cameraPosition - wp);',
        '  vUv = corner;',
        '  vMix = aD.y;',
        '  vDist = -mv.z;',
        '  float env = smoothstep(0.0, 0.06, ph) * smoothstep(1.0, 0.93, ph);',
        '  if (aB.y > 0.5) env *= smoothstep(0.0, 0.06, dx) * smoothstep(1.0, 0.94, dx);',
        '  vAlpha = ev_present(aA.w) * env * smoothstep(0.4, 1.2, vDist);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColorA; uniform vec3 uColorB; uniform vec3 uColorC; uniform vec3 uLightDir; uniform vec3 uLight; uniform vec3 uAmbient;',
        'uniform vec3 uFog; uniform float uFogDensity; uniform float uShape; uniform float uOpacity;',
        'varying vec2 vUv; varying vec3 vNormal; varying vec3 vView; varying float vAlpha; varying float vMix; varying float vDist;',
        'void main() {',
        '  float y = vUv.y * 0.5 + 0.5;',
        '  float x = abs(vUv.x);',
        '  float w; float shade;',
        '  if (uShape > 0.5) {',
        // cherry petal: rounded, widest above the middle, small notch at the tip
        '    w = 0.95 * pow(sin(3.14159 * clamp(y * 0.82 + 0.1, 0.0, 1.0)), 0.6) * (0.55 + 0.45 * y);',
        '    float notch = 1.0 - (1.0 - smoothstep(0.0, 0.16, x)) * smoothstep(0.86, 1.0, y);',
        '    w *= notch;',
        '    shade = mix(0.82, 1.0, y);',
        '  } else {',
        // leaf: pointed oval with a stem and a midrib
        '    w = 0.92 * pow(sin(3.14159 * clamp(y * 1.05 - 0.05, 0.0, 1.0)), 0.85);',
        '    if (y < 0.08) w = max(w, 0.06);',
        '    shade = 1.0 - 0.25 * (1.0 - smoothstep(0.0, 0.07, x)) * step(0.06, y);',
        '  }',
        '  float edge = 1.0 - smoothstep(w - 0.08, w, x);',
        '  if (edge < 0.01) discard;',
        '  vec3 n = normalize(vNormal); if (!gl_FrontFacing) n = -n;',
        '  float ndl = dot(n, uLightDir);',
        '  float trans = max(0.0, -ndl) * max(0.0, dot(-vView, uLightDir));',
        '  vec3 base = vMix < 0.5 ? mix(uColorA, uColorB, vMix * 2.0) : mix(uColorB, uColorC, vMix * 2.0 - 1.0);',
        '  vec3 col = base * (uAmbient + uLight * max(ndl, 0.0)) * shade + base * uLight * trans * 0.6;',
        '  col = mix(col, uFog, 1.0 - exp(-vDist * uFogDensity));',
        '  gl_FragColor = vec4(ev_dither(col), edge * vAlpha * uOpacity);',
        '}',
      ].join('\n'),
    });
    return finish(new THREE.Mesh(g, m), uLevel);
  }

  function feuilles(ctx, o) {
    o = Object.assign({
      count: 60, size: [0.07, 0.12], fall: [1, 2], drift: [0, 0], spin: [1, 3], sway: [0.25, 0.6],
      colors: ['#7a4a1c', '#a8692a', '#c99a45'], shape: 'leaf',
    }, o);
    return flakes(ctx, o, 'feuilles');
  }

  function petales(ctx, o) {
    o = Object.assign({
      count: 140, size: [0.035, 0.06], fall: [1, 2], drift: [1, 2], spin: [1, 4], sway: [0.15, 0.4],
      colors: ['#f6d3dc', '#f2b8c8', '#fbe9ee'], shape: 'petal',
    }, o);
    return flakes(ctx, o, 'petales');
  }

  // ------------------------------------------------------------------ oiseaux-vol (birds)
  // Distant silhouettes: flocks crossing the view once per period and birds soaring in circles.
  function birdGeometry() {
    // local frame: x = span (right), y = up, z = forward. w (attribute "part"): 0 body, 1 wing
    var v = [
      // body (diamond)
      0, 0, 0.2, 0.035, 0, 0.0, 0, 0, -0.22,
      0, 0, 0.2, 0, 0, -0.22, -0.035, 0, 0.0,
      // tail
      0, 0, -0.16, 0.06, 0, -0.3, -0.06, 0, -0.3,
    ];
    function wing(s) {
      // inner (shoulder -> elbow) and outer (elbow -> tip) panels, swept back
      var sh0 = [s * 0.03, 0, 0.06], sh1 = [s * 0.03, 0, -0.07];
      var el0 = [s * 0.22, 0, 0.04], el1 = [s * 0.22, 0, -0.09];
      var tip = [s * 0.48, 0, -0.12], tip2 = [s * 0.4, 0, -0.16];
      return [].concat(sh0, el0, sh1, sh1, el0, el1, el0, tip, el1, el1, tip, tip2);
    }
    v = v.concat(wing(1), wing(-1));
    var g = new THREE.InstancedBufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(v, 3));
    return g;
  }

  function oiseaux(ctx, o) {
    o = Object.assign({
      flocks: [], soaring: [], size: 1.0, color: '#1c2233', fog: '#8a9ab0', fogDensity: 0.004,
    }, o);
    var r = ctx.rng('oiseaux');
    var g = birdGeometry();
    var a = [], b = [], c = [], d = [];
    var rank = 0;
    var total = o.flocks.reduce(function (s, f) { return s + f.count; }, 0) +
      o.soaring.reduce(function (s, f) { return s + f.count; }, 0);
    // flock: crosses from x0 to x1 once per period (k = 1), loose V formation
    o.flocks.forEach(function (f) {
      for (var i = 0; i < f.count; i++) {
        var row = Math.ceil(i / 2);
        var side = i % 2 === 0 ? 1 : -1;
        var lag = row * f.spacing * (1 + (r() - 0.5) * 0.3);
        a.push(0, f.y + side * row * f.spacing * 0.18 + (r() - 0.5) * f.spacing * 0.3,
          f.z + side * row * f.spacing * 0.6 + (r() - 0.5) * f.spacing,
          (f.phase - lag / (f.x1 - f.x0) + 1) % 1);
        b.push(pickInt(r, [36, 46]), r(), pickInt(r, [1, 2]), r());
        c.push(f.size * pick(r, [0.85, 1.15]), f.x0, f.x1, (rank + 0.5) / total);
        d.push(f.dir || 1, pick(r, [0.04, 0.12]), r(), 0);
        rank++;
      }
    });
    // soaring: circles of radius R around (cx, y, cz), k turns per period
    o.soaring.forEach(function (f) {
      for (var i = 0; i < f.count; i++) {
        a.push(1, f.y + (r() - 0.5) * f.dy, f.z + (r() - 0.5) * f.dz, r());
        b.push(pickInt(r, [30, 40]), r(), pickInt(r, [2, 3]), r());
        c.push(f.size * pick(r, [0.85, 1.15]), f.x + (r() - 0.5) * f.dx, pick(r, f.radius), (rank + 0.5) / total);
        d.push(r() < 0.5 ? -1 : 1, pick(r, [0.02, 0.06]), r(), f.turns || 1);
        rank++;
      }
    });
    // ranks shuffled so that a low level keeps a little of each group
    var order = [];
    for (var j = 0; j < rank; j++) order.push(j);
    for (var k = order.length - 1; k > 0; k--) {
      var s = Math.floor(r() * (k + 1));
      var tmp = order[k]; order[k] = order[s]; order[s] = tmp;
    }
    for (var q = 0; q < rank; q++) c[q * 4 + 3] = (order[q] + 0.5) / rank;
    instanced(g, 'aA', a, 4);
    instanced(g, 'aB', b, 4);
    instanced(g, 'aC', c, 4);
    instanced(g, 'aD', d, 4);
    g.instanceCount = rank;
    var uLevel = levelUniform();
    var m = mat(ctx, uLevel, {
      blending: THREE.NormalBlending,
      side: THREE.DoubleSide,
      uniforms: {
        uColor: { value: ctx.color(o.color) }, uFog: { value: ctx.color(o.fog) },
        uFogDensity: { value: o.fogDensity }, uScale: { value: o.size },
      },
      vertexShader: [
        'uniform float uScale;',
        'attribute vec4 aA; attribute vec4 aB; attribute vec4 aC; attribute vec4 aD;',
        'varying float vAlpha; varying float vDist; varying float vUnder;',
        'void main() {',
        '  float T = uTime / EV_PERIOD;',
        '  vec3 p; vec3 fwd; float bank = 0.0;',
        '  if (aA.x < 0.5) {',
        '    float u = fract(aA.w + T);',
        '    float x = mix(aC.y, aC.z, aD.x > 0.0 ? u : 1.0 - u);',
        '    p = vec3(x, aA.y + aD.y * sin(EV_TAU * (2.0 * T + aD.z)), aA.z);',
        '    fwd = vec3(aD.x, 0.0, 0.0);',
        '  } else {',
        '    float ang = EV_TAU * (aD.w * aD.x * T + aA.w);',
        '    p = vec3(aC.y + aC.z * cos(ang), aA.y + aD.y * sin(EV_TAU * (T + aD.z)), aA.z + aC.z * 0.45 * sin(ang));',
        '    fwd = normalize(vec3(-sin(ang), 0.0, 0.45 * cos(ang)) * aD.x);',
        '    bank = 0.35 * aD.x;',
        '  }',
        '  vec3 right = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));',
        '  vec3 up = cross(right, fwd);',
        '  right = ev_rotAxis(fwd, bank) * right; up = ev_rotAxis(fwd, bank) * up;',
        // wing flap with gliding phases (the envelope loops 1-3 times a period)
        '  float glide = smoothstep(-0.3, 0.5, sin(EV_TAU * (aB.z * T + aB.w)));',
        '  float flap = sin(EV_TAU * (aB.x * T + aB.y));',
        '  float a1 = (0.55 * flap) * glide + 0.12;',
        '  float a2 = (0.35 * sin(EV_TAU * (aB.x * T + aB.y) - 0.6)) * glide + 0.05;',
        '  vec3 lp = position;',
        '  float rr = abs(lp.x); float sx = sign(lp.x);',
        '  if (rr > 0.031) {',
        '    float re = min(rr, 0.22);',
        '    vec2 e = re * vec2(cos(a1), sin(a1));',
        '    vec2 w = e + max(rr - 0.22, 0.0) * vec2(cos(a1 + a2), sin(a1 + a2));',
        '    lp.x = sx * w.x; lp.y = w.y;',
        '  }',
        '  vec3 wp = p + (right * lp.x + up * lp.y + fwd * lp.z) * aC.x * uScale;',
        '  vec4 mv = modelViewMatrix * vec4(wp, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  vDist = -mv.z;',
        '  vUnder = lp.y;',
        '  float edge = 1.0;',
        '  if (aA.x < 0.5) { float u2 = fract(aA.w + T); edge = smoothstep(0.0, 0.04, u2) * smoothstep(1.0, 0.96, u2); }',
        '  vAlpha = ev_present(aC.w) * edge;',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor; uniform vec3 uFog; uniform float uFogDensity;',
        'varying float vAlpha; varying float vDist; varying float vUnder;',
        'void main() {',
        '  float f = 1.0 - exp(-vDist * uFogDensity);',
        '  vec3 c = mix(uColor, uFog, clamp(f, 0.0, 0.92));',
        '  gl_FragColor = vec4(ev_dither(c), vAlpha);',
        '}',
      ].join('\n'),
    });
    var mesh = new THREE.Mesh(g, m);
    return finish(mesh, uLevel);
  }

  // ------------------------------------------------------------------ rayons-soleil
  // Light shafts fanning from the sun, breathing slowly, with dust motes drifting inside.
  function rayons(ctx, o) {
    o = Object.assign({
      count: 9, spread: 0.5, length: 40, width: [0.6, 3.0], color: '#ffe2ae', intensity: 0.12,
      falloff: 1.6, motes: 140, moteColor: '#fff1d0', moteSize: 0.03,
    }, o);
    var r = ctx.rng('rayons');
    var origin = v3(o.origin);
    var center = v3(o.toward).sub(origin).normalize();
    var side = new THREE.Vector3().crossVectors(center, v3(o.spreadAxis || [0, 0, 1])).normalize();
    var g = quadCorners(true);
    var dirs = [], w = [], k = [];
    var rankOrder = [0.0, 0.5, 0.25, 0.75, 0.12, 0.62, 0.37, 0.87, 0.06, 0.56, 0.31, 0.81];
    for (var i = 0; i < o.count; i++) {
      var f = o.count === 1 ? 0 : (i / (o.count - 1)) * 2 - 1;
      var ang = f * o.spread + (r() - 0.5) * o.spread / o.count;
      var d = center.clone().applyAxisAngle(new THREE.Vector3().crossVectors(center, side).normalize(), ang).normalize();
      dirs.push(d.x, d.y, d.z, pick(r, [0.6, 1.0]));
      w.push(pick(r, [o.width[0], o.width[0] * 1.6]), pick(r, [o.width[1] * 0.6, o.width[1]]), r(), rankOrder[i % rankOrder.length]);
      k.push(pickInt(r, [1, 3]), r(), pick(r, [0.7, 1.0]), 0);
    }
    instanced(g, 'aDir', dirs, 4);
    instanced(g, 'aW', w, 4);
    instanced(g, 'aK', k, 4);
    g.instanceCount = o.count;
    var uLevel = levelUniform();
    var shared = {
      uOrigin: { value: origin }, uLength: { value: o.length }, uColor: { value: ctx.color(o.color) },
      uIntensity: { value: o.intensity }, uFalloff: { value: o.falloff },
    };
    var m = mat(ctx, uLevel, {
      uniforms: shared,
      side: THREE.DoubleSide,
      vertexShader: [
        'uniform vec3 uOrigin; uniform float uLength;',
        'attribute vec2 corner; attribute vec4 aDir; attribute vec4 aW; attribute vec4 aK;',
        'varying vec2 vC; varying float vAlpha; varying float vSeed;',
        'void main() {',
        '  vec3 d = aDir.xyz;',
        '  vec3 P = uOrigin + d * corner.y * uLength * aDir.w;',
        '  vec3 toCam = normalize(cameraPosition - P);',
        '  vec3 side = normalize(cross(d, toCam));',
        '  float width = mix(aW.x, aW.y, corner.y);',
        '  vec3 wp = P + side * corner.x * width;',
        '  gl_Position = projectionMatrix * modelViewMatrix * vec4(wp, 1.0);',
        '  vC = corner;',
        '  float breathe = 0.62 + 0.38 * ev_wave(aK.x, aK.y, uTime);',
        '  vAlpha = ev_present(aW.w) * breathe * aK.z * (0.45 + 0.55 * uLevel);',
        '  vSeed = aW.z;',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor; uniform float uIntensity; uniform float uFalloff;',
        'varying vec2 vC; varying float vAlpha; varying float vSeed;',
        'void main() {',
        '  float across = exp(-vC.x * vC.x * 3.2) - 0.04;',
        '  float along = smoothstep(0.0, 0.18, vC.y) * pow(1.0 - vC.y, uFalloff);',
        '  float streak = 0.75 + 0.25 * ev_noise(vec2(vC.x * 3.0 + vSeed * 40.0, vC.y * 2.0));',
        '  float a = max(across, 0.0) * along * streak * vAlpha * uIntensity;',
        '  gl_FragColor = vec4(uColor * a, 1.0);',
        '}',
      ].join('\n'),
    });
    var shafts = new THREE.Mesh(g, m);
    shafts.frustumCulled = false;

    // dust motes, each inside one shaft
    var pos = [], ma = [], mb = [];
    for (var j = 0; j < o.motes; j++) {
      var s = Math.floor(r() * o.count);
      var dir = new THREE.Vector3(dirs[s * 4], dirs[s * 4 + 1], dirs[s * 4 + 2]);
      var along = pick(r, [0.12, 0.7]) * o.length * dirs[s * 4 + 3];
      var wid = THREE.MathUtils.lerp(w[s * 4], w[s * 4 + 1], along / o.length) * 0.7;
      var off = new THREE.Vector3(r() - 0.5, r() - 0.5, r() - 0.5).multiplyScalar(2 * wid);
      var p = origin.clone().addScaledVector(dir, along).add(off);
      pos.push(p.x, p.y, p.z);
      ma.push(w[s * 4 + 3] + r() * 0.3, r(), r(), r());
      mb.push(pickInt(r, [2, 6]), r(), pick(r, [0.5, 1.0]), 0);
    }
    var gm = new THREE.BufferGeometry();
    gm.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    gm.setAttribute('aA', new THREE.Float32BufferAttribute(ma, 4));
    gm.setAttribute('aB', new THREE.Float32BufferAttribute(mb, 4));
    var mm = mat(ctx, uLevel, {
      uniforms: { uColor: { value: ctx.color(o.moteColor) }, uSize: { value: o.moteSize } },
      vertexShader: [
        'uniform float uSize;',
        'attribute vec4 aA; attribute vec4 aB;',
        'varying float vAlpha;',
        'void main() {',
        '  float T = EV_TAU * uTime / EV_PERIOD;',
        '  vec3 p = position + 0.25 * vec3(sin(T + aA.y * EV_TAU), 0.6 * sin(2.0 * T + aA.z * EV_TAU), cos(T + aA.w * EV_TAU));',
        '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
        '  gl_Position = projectionMatrix * mv;',
        '  float tw = 0.5 + 0.5 * ev_wave(aB.x, aB.y, uTime);',
        '  vAlpha = ev_present(min(aA.x * 1.2 + 0.15, 1.0)) * (0.25 + 0.75 * tw * tw) * aB.z * smoothstep(0.6, 2.0, -mv.z);',
        '  gl_PointSize = clamp(uSize * uFocal / max(-mv.z, 0.1), 1.0, 24.0 * uPixelRatio);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform vec3 uColor;',
        'varying float vAlpha;',
        'void main() {',
        '  vec2 d = gl_PointCoord - 0.5;',
        '  float a = exp(-dot(d, d) * 4.0 * 7.0);',
        '  gl_FragColor = vec4(uColor * a * vAlpha * 0.8, 1.0);',
        '}',
      ].join('\n'),
    });
    var motes = new THREE.Points(gm, mm);
    motes.frustumCulled = false;
    var group = new THREE.Group();
    group.add(shafts);
    group.add(motes);
    if (o.renderOrder !== undefined) { shafts.renderOrder = o.renderOrder; motes.renderOrder = o.renderOrder; }
    return finish(group, uLevel, { onLevel: o.onLevel });
  }

  // ------------------------------------------------------------------ brume (mist)
  // Soft banks of mist (vertical sheets at several depths) drifting slowly; the scene may also
  // thicken its own fog with the level (onLevel).
  function brume(ctx, o) {
    o = Object.assign({ layers: [], color: '#b8c4d4', opacity: 0.55, scale: 0.18 }, o);
    var group = new THREE.Group();
    var uLevel = levelUniform();
    var r = ctx.rng('brume');
    o.layers.forEach(function (L, i) {
      var g = new THREE.PlaneGeometry(L.width, L.height, 1, 1);
      var m = mat(ctx, uLevel, {
        blending: THREE.NormalBlending,
        uniforms: {
          uColor: { value: ctx.color(L.color || o.color) },
          uOpacity: { value: L.opacity !== undefined ? L.opacity : o.opacity },
          uScale: { value: L.scale || o.scale },
          uDrift: { value: new THREE.Vector2(L.drift !== undefined ? L.drift : (i % 2 ? -0.05 : 0.06), 0.0) },
          uSeed: { value: new THREE.Vector2(r() * 50, r() * 50) },
          uRank: { value: L.rank !== undefined ? L.rank : i / Math.max(1, o.layers.length) * 0.5 },
          uTop: { value: L.top !== undefined ? L.top : 0.45 },
        },
        vertexShader: [
          'varying vec2 vUv; varying vec3 vWorld;',
          'void main() {',
          '  vUv = uv;',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uColor; uniform float uOpacity; uniform float uScale; uniform vec2 uDrift; uniform vec2 uSeed;',
          'uniform float uRank; uniform float uTop;',
          'varying vec2 vUv; varying vec3 vWorld;',
          'void main() {',
          '  vec2 p = vec2(vWorld.x * 0.45, vWorld.y * 1.3) * uScale + uSeed;',
          '  float n = ev_loopFbm(p, uDrift, uTime);',
          '  float band = smoothstep(0.0, 0.22, vUv.y) * (1.0 - smoothstep(uTop * 0.5, uTop, vUv.y - 0.1));',
          '  float edge = smoothstep(0.0, 0.2, vUv.x) * smoothstep(1.0, 0.8, vUv.x);',
          '  float dens = smoothstep(0.28, 0.72, n + (1.0 - vUv.y) * 0.18);',
          '  float present = clamp((uLevel * 1.15 - uRank) / 0.3, 0.0, 1.0);',
          '  float a = dens * band * edge * uOpacity * present * (0.5 + 0.5 * uLevel);',
          '  gl_FragColor = vec4(ev_dither(uColor), a);',
          '}',
        ].join('\n'),
      });
      var mesh = new THREE.Mesh(g, m);
      mesh.position.set(L.x || 0, L.y, L.z);
      if (L.rotationY) mesh.rotation.y = L.rotationY;
      mesh.renderOrder = L.renderOrder !== undefined ? L.renderOrder : 2;
      mesh.frustumCulled = false;
      group.add(mesh);
    });
    return finish(group, uLevel, { onLevel: o.onLevel });
  }

  window.EventideDecors = {
    lucioles: lucioles,
    etoiles: etoiles,
    'etoiles-filantes': etoilesFilantes,
    neige: neige,
    pluie: pluie,
    feuilles: feuilles,
    petales: petales,
    'oiseaux-vol': oiseaux,
    'rayons-soleil': rayons,
    brume: brume,
    GLSL: DECOR_GLSL,
    GLSL_VERTEX: DECOR_VERT,
  };
})();
