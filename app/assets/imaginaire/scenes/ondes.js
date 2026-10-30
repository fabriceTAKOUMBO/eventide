/*
 * « Ondes lumineuses », version 2 (abstract, hypnotic): an endless dark satin surface slowly
 * crossed by interfering waves, drawn with the HDR finish of post.js (the quality bar of the
 * forest v2).
 *
 *   - The waves: two circular wave trains from sources drifting on closed paths and one long plane
 *     wave; where they meet in phase, the crests rise and glow; a soft ring of light leaves the
 *     centre twice a period. Heights and slopes are analytic (exact normals, no texture).
 *   - The surface: a fan of vertices around the viewer, shaded in the fragment shader: deep
 *     colour, reflection of the horizon glow (Fresnel), emission on the crests that the bloom
 *     softens; it fades into the glow toward the horizon (depth).
 *   - The field of light: fine points riding the surface, brighter on the crests and in the ring;
 *     they fade near the viewer (the lower third stays quiet) and far away (no shimmer).
 *   - No sun here: the light is the glow itself; the finish (bloom, tone curve, grain) makes it
 *     soft. Rain opens rings of light on the field; mist lies on it as a luminous haze.
 * Everything that moves is a function of the scene time t (modulo 30 s): the period loops.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;
  var TAU = Math.PI * 2;

  function lin(hex) {
    return new THREE.Color(hex).convertSRGBToLinear();
  }

  // Waves, shared by the surface, the points and the rain rings (GLSL, after GLSL.common).
  var WAVE_GLSL = [
    'uniform float uRain; uniform float uMist;',
    'uniform vec3 uGlowA; uniform vec3 uGlowB; uniform vec3 uGlowC; uniform vec3 uHorizon; uniform vec3 uDeep;',
    // a circular wave train from s: amplitude a, wavelength l, n crests passing per period
    'float wv_ring(vec2 p, vec2 s, float a, float l, float n, float phase, inout float h, inout vec2 g) {',
    '  vec2 d = p - s; float r = max(length(d), 1e-3);',
    '  float k = EV_TAU / l;',
    '  float ph = k * r - EV_TAU * n * uTime / EV_PERIOD + phase;',
    '  float fall = 1.0 / (1.0 + r * 0.012);',
    '  h += a * fall * sin(ph);',
    '  g += a * fall * cos(ph) * k * d / r;',
    '  return ph;',
    '}',
    'vec3 wv_ph;',   // phases of the three trains (last call of wv_height)
    'float wv_height(vec2 p, out vec2 g, out float pulse) {',
    '  float T = EV_TAU * uTime / EV_PERIOD;',
    '  float h = 0.0; g = vec2(0.0);',
    '  vec2 s1 = vec2(-8.0 + 3.0 * sin(T), -34.0 + 4.0 * cos(T));',
    '  vec2 s2 = vec2(10.0 + 3.0 * cos(T + 1.0), -50.0 + 5.0 * sin(T));',
    '  wv_ph.x = wv_ring(p, s1, 0.42, 14.0, 3.0, 0.0, h, g);',
    '  wv_ph.y = wv_ring(p, s2, 0.38, 17.0, 2.0, 1.3, h, g);',
    // a long swell across them
    '  vec2 dir = normalize(vec2(0.35, 1.0));',
    '  float k3 = EV_TAU / 31.0;',
    '  float ph3 = k3 * dot(p, dir) - T + 2.1;',
    '  h += 0.22 * sin(ph3); g += 0.22 * cos(ph3) * k3 * dir;',
    '  wv_ph.z = ph3;',
    // the ring of light: leaves the centre twice a period, widening and fading
    '  float pp = fract(2.0 * uTime / EV_PERIOD);',
    '  vec2 c = p - vec2(0.0, -38.0);',
    '  float rr = length(c) - pp * 70.0;',
    '  pulse = exp(-rr * rr * 0.12) * smoothstep(0.0, 0.08, pp) * (1.0 - pp) * 0.7;',
    '  h += 0.25 * pulse;',
    // rain: drops at fixed times and places open small rings
    '  if (uRain > 0.001) {',
    '    for (int j = 0; j < 16; j++) {',
    '      float fj = float(j);',
    '      float t0 = fj * EV_PERIOD / 16.0 + 1.1 * ev_hash12(vec2(fj, 1.0));',
    '      float age = mod(uTime - t0, EV_PERIOD);',
    '      if (age > 3.2) continue;',
    '      vec2 cc = vec2((ev_hash12(vec2(fj, 2.0)) - 0.5) * 20.0, -6.0 - ev_hash12(vec2(fj, 3.0)) * 36.0);',
    '      float rd = length(p - cc) - age * 2.0;',
    '      float ring = exp(-rd * rd * 2.5) * (1.0 - age / 3.2) * uRain;',
    '      h += 0.12 * ring;',
    '      pulse += 0.8 * ring;',
    '    }',
    '  }',
    '  return h;',
    '}',
    // the crest lines of the trains: thin lines of light where they are wide on screen, widening
    // into a soft glow (same mean light) where they would shrink below a pixel
    'float wv_line(float ph, float fw) {',
    '  float n = mix(24.0, 1.5, smoothstep(0.25, 1.6, fw));',
    '  return pow(0.5 + 0.5 * sin(ph), n) * sqrt(n / 24.0);',
    '}',
    'float wv_lines(vec3 fw) {',
    '  float a = wv_line(wv_ph.x, fw.x), b = wv_line(wv_ph.y, fw.y), c = wv_line(wv_ph.z, fw.z);',
    // each train alone is faint; where two of them meet the light gathers (interference)
    '  return 0.32 * (a + b) + 0.14 * c + 1.4 * a * b + 0.5 * (a + b) * c;',
    '}',
    // colour of the light: teal in the troughs of the pattern, violet on the crests, a touch of rose
    'vec3 wv_glow(float h, float x) {',
    '  float t = clamp(0.5 + 0.55 * h + x / 90.0, 0.0, 1.0);',
    '  vec3 c = mix(uGlowA, uGlowB, t);',
    '  return mix(c, uGlowC, smoothstep(0.75, 1.0, t) * 0.5);',
    '}',
    // the world above: a dark void with a soft glow band on the horizon (the reflection, the fog)
    'vec3 wv_sky(vec3 d) {',
    '  float y = d.y;',
    '  float band = exp(-abs(y - 0.012) * 20.0) * 0.8 + exp(-abs(y) * 5.0) * 0.2;',
    '  float breathe = 0.88 + 0.12 * ev_wave(1.0, 0.0, uTime);',
    '  vec3 c = uDeep * 0.6 + uHorizon * band * breathe * (1.0 + 0.8 * uMist);',
    '  return c;',
    '}',
    'vec3 wv_fog(vec3 col, vec3 wp) {',
    '  vec3 d = wp - cameraPosition;',
    '  float L = length(d);',
    '  float f = 1.0 - exp(-L * (0.0075 + 0.012 * uMist));',
    '  vec3 dir = d / L;',
    '  return mix(col, wv_sky(vec3(dir.x, max(dir.y, 0.0) * 0.3, dir.z)), f);',
    '}',
  ].join('\n');

  E.register({
    id: 'ondes',
    decors: ['etoiles', 'brume', 'pluie'],
    defaults: { etoiles: 40 },
    post: true,

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var quality = ctx.quality;
      var high = quality === 'high';
      camera.fov = 52;
      camera.near = 0.1;
      camera.far = 3000;

      var shared = {
        uMist: { value: 0 },
        uRain: { value: 0 },
        uGlowA: { value: lin('#33c9c4').multiplyScalar(1.0) },
        uGlowB: { value: lin('#7d6cff').multiplyScalar(1.0) },
        uGlowC: { value: lin('#ff8cc6').multiplyScalar(1.0) },
        uHorizon: { value: lin('#3a3f9a').multiplyScalar(0.55) },
        uDeep: { value: lin('#05061a').multiplyScalar(0.6) },
      };
      function mat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.vertexShader = WAVE_GLSL + '\n' + params.vertexShader;
        params.fragmentShader = WAVE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- the void
      var sky = new THREE.Mesh(new THREE.SphereGeometry(2000, 32, 16), mat({
        side: THREE.BackSide,
        depthWrite: false,
        vertexShader: [
          'varying vec3 vDir;',
          'void main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  gl_FragColor = vec4(wv_sky(d), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = 10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- the surface
      var FR = high ? 150 : 100, FA = high ? 110 : 76;
      var sp = [], si = [];
      for (var ri = 0; ri <= FR; ri++) {
        var dist = 1.5 * Math.pow(1800 / 1.5, ri / FR);
        for (var ai = 0; ai <= FA; ai++) {
          var ang = -0.62 + 1.24 * ai / FA;
          sp.push(Math.sin(ang) * dist, 0, 8 - Math.cos(ang) * dist);
        }
      }
      for (var r2 = 0; r2 < FR; r2++) {
        for (var a2 = 0; a2 < FA; a2++) {
          var c0 = r2 * (FA + 1) + a2, c1 = c0 + FA + 1;
          si.push(c0, c0 + 1, c1, c0 + 1, c1 + 1, c1);
        }
      }
      var surfGeo = new THREE.BufferGeometry();
      surfGeo.setAttribute('position', new THREE.Float32BufferAttribute(sp, 3));
      surfGeo.setIndex(si);
      var surface = new THREE.Mesh(surfGeo, mat({
        vertexShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  vec3 p = position;',
          '  vec2 g; float pulse;',
          '  p.y = wv_height(p.xz, g, pulse) - 1.6;',
          '  vec4 w = modelMatrix * vec4(p, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  vec2 g; float pulse;',
          '  float h = wv_height(vWorld.xz, g, pulse);',
          '  vec3 toCam = cameraPosition - vWorld;',
          '  float dist = length(toCam);',
          '  vec3 V = toCam / dist;',
          // slopes finer than a pixel are flattened (no shimmer far away)
          '  float px = dist / uFocal;',
          '  g *= 1.0 - smoothstep(0.02, 0.09, px);',
          '  vec3 N = normalize(vec3(-g.x, 1.0, -g.y));',
          '  vec3 R = reflect(-V, N);',
          '  float F = 0.04 + 0.96 * pow(1.0 - max(dot(N, V), 0.0), 5.0);',
          '  vec3 env = wv_sky(vec3(R.x, abs(R.y), R.z));',
          '  vec3 ph = wv_ph;',
          '  float lines = wv_lines(fwidth(ph) * 1.0 + vec3(1e-4));',
          '  vec3 glow = wv_glow(h, vWorld.x);',
          '  vec3 col = uDeep * 0.5 + env * F * 1.2;',
          // the crest lines glow, most where the trains meet (quieter near the viewer)
          '  col += glow * (0.015 + 1.1 * lines + 1.6 * pulse) * smoothstep(11.0, 40.0, dist);',
          '  col = wv_fog(col, vWorld);',
          '  gl_FragColor = vec4(col, 1.0);',
          '}',
        ].join('\n'),
      }));
      surface.frustumCulled = false;
      surface.renderOrder = 1;
      scene.add(surface);

      // ---------------------------------------------------------------- the field of light
      var NX = high ? 200 : 150, NZ = high ? 150 : 110;
      var pos = [], rnd = [];
      var jr = ctx.rng('field');
      for (var iz = 0; iz < NZ; iz++) {
        // rows closer together near the viewer, spreading with distance (even on screen)
        var v = iz / (NZ - 1);
        var z = 13 - 4 * Math.pow(150, v);
        var half = 7 + (8 - z) * 0.8;
        var dz = 4 * Math.pow(150, v) * Math.log(150) / (NZ - 1);
        for (var ix = 0; ix < NX; ix++) {
          var u = ix / (NX - 1);
          pos.push((u * 2 - 1) * half + (jr() - 0.5) * (2 * half / NX) * 0.9, 0, z + (jr() - 0.5) * dz * 0.9);
          rnd.push(jr());
        }
      }
      var pg = new THREE.BufferGeometry();
      pg.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      pg.setAttribute('aRnd', new THREE.Float32BufferAttribute(rnd, 1));
      var field = new THREE.Points(pg, mat({
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        vertexShader: [
          'attribute float aRnd;',
          'varying vec3 vC; varying float vSoft;',
          'void main() {',
          '  vec3 p = position;',
          '  vec2 g; float pulse;',
          '  float h = wv_height(p.xz, g, pulse);',
          '  p.y = h - 1.6 + 0.04;',
          '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
          '  gl_Position = projectionMatrix * mv;',
          '  float dist = -mv.z;',
          '  float crest = wv_lines(vec3(0.2 + dist * 0.02));',
          // a slow twinkle, four whole cycles a period
          '  float tw = 0.75 + 0.25 * sin(EV_TAU * (4.0 * uTime / EV_PERIOD + aRnd));',
          '  float I = (0.22 + 1.8 * crest + 3.0 * pulse) * tw;',
          // quiet near the viewer (the lower third), gone before they shimmer far away
          '  I *= smoothstep(8.0, 32.0, dist) * (1.0 - smoothstep(90.0, 220.0, dist));',
          '  float size = 0.035 * uFocal / dist;',
          '  vSoft = clamp(size / 4.0, 0.0, 1.0);',
          '  gl_PointSize = clamp(size * 2.6, 1.5, 16.0 * uPixelRatio);',
          // a point smaller than its sprite carries the light of its true size
          '  I *= clamp(size / 1.2, 0.12, 1.0);',
          '  vec3 fogged = wv_fog(wv_glow(h, p.x) * I, p);',
          '  vC = fogged;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vC; varying float vSoft;',
          'void main() {',
          '  vec2 d = gl_PointCoord - 0.5;',
          '  float r2 = dot(d, d) * 4.0;',
          '  float a = exp(-r2 * mix(9.0, 4.0, vSoft));',
          '  gl_FragColor = vec4(vC * a, 1.0);',
          '}',
        ].join('\n'),
      }));
      field.frustumCulled = false;
      field.renderOrder = 2;
      scene.add(field);

      // ---------------------------------------------------------------- finish
      var post = ctx.post({
        exposure: 1.0,
        toneMapping: 'aces',
        bloom: { strength: 0.5, threshold: 0.55, knee: 0.5, radius: 1.0 },
        aberration: 0.005,
        vignette: 0.42,
        grain: ctx.record ? 0 : 0.022,
      });

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function hex(c) { return '#' + c.getHexString(); }
      var stars = D.etoiles(ctx, {
        count: high ? 1200 : 720, radius: 1500, azimuth: [0, 46], elevation: [5, 85], size: 0.95, brightness: 1.6,
        tint: ['#bcd8ff', '#e9d6ff'], band: { normal: [0.4, 0.5, 0.75], width: 0.12, count: high ? 900 : 540 },
      });
      var rain = D.pluie(ctx, {
        count: high ? 700 : 420, box: { min: [-9, -1.6, -40], max: [9, 9, 6] }, speed: [7, 9.5], color: hex(lin('#8fa8ff')),
        opacity: 0.16, wind: [0.0, 0.0], length: [0.25, 0.45], width: 1.1,
      });
      var rainSet = rain.setLevel;
      rain.setLevel = function (v) { rainSet(v); shared.uRain.value = v; };
      var mist = { object: new THREE.Group(), setLevel: function (v) { shared.uMist.value = v; } };
      mist.object.visible = false;
      var decors = { etoiles: stars, brume: mist, pluie: rain };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = (t / ctx.PERIOD) * TAU;
        camera.position.set(0.8 * Math.sin(T), 2.6 + 0.08 * Math.sin(2 * T), 8 + 0.4 * Math.cos(T));
        camera.lookAt(0.6 * Math.sin(T + 0.6), -5.6, -40);
      }
      update(0);

      return {
        decors: decors,
        update: update,
        render: function () { post.render(scene, camera); },
        setQuality: function (q) {
          quality = q;
          high = q === 'high';
          post.setQuality(q);
        },
        describe: function () {
          var d = post.describe();
          d.points = NX * NZ;
          d.surfaceVertices = (FR + 1) * (FA + 1);
          return d;
        },
        dispose: function () { post.dispose(); },
      };
    },
  });
})();
