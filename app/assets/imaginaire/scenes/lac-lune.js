/*
 * « Lac sous la lune »: a still mountain lake at night. A large moon veiled by thin clouds,
 * ranges of mountains in blue mist, a pine shore; the lake mirrors everything (real reflection,
 * rippled) and the moon lays a path of glints on the water. Reeds in the foreground.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  var SCENE_GLSL = [
    'uniform vec3 uHorizon; uniform vec3 uZenith; uniform vec3 uMoonDir; uniform vec3 uMoonGlow; uniform float uMist;',
    'vec3 skyBase(vec3 d) {',
    '  float g = max(dot(d, uMoonDir), 0.0);',
    '  vec3 c = mix(uHorizon, uZenith, smoothstep(-0.02, 0.55, d.y));',
    '  return c + uMoonGlow * (pow(g, 8.0) * 0.35 + pow(g, 90.0) * 0.5);',
    '}',
    'vec3 applyFog(vec3 col, vec3 worldPos, float density) {',
    '  vec3 d = worldPos - cameraPosition;',
    '  float dist = length(d);',
    '  vec3 dir = d / dist;',
    '  float f = 1.0 - exp(-dist * density * (1.0 + 0.8 * uMist));',
    '  return mix(col, skyBase(vec3(dir.x, abs(dir.y) * 0.3, dir.z)), clamp(f, 0.0, 1.0));',
    '}',
  ].join('\n');

  E.register({
    id: 'lac-lune',
    decors: ['brume', 'etoiles', 'etoiles-filantes', 'lucioles', 'neige'],
    defaults: { etoiles: 60, brume: 30 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var S = window.EventideScenery;
      var r = ctx.rng('scene');
      camera.fov = 50;
      camera.near = 0.1;
      camera.far = 3000;

      var moonDir = new THREE.Vector3(-0.1, 0.43, -1).normalize();
      var shared = {
        uHorizon: { value: ctx.color('#22395a') },
        uZenith: { value: ctx.color('#040817') },
        uMoonDir: { value: moonDir },
        uMoonGlow: { value: ctx.color('#9fb6d6') },
        uMist: { value: 0 },
      };
      function sceneMat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.fragmentShader = SCENE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- sky, moon, veils
      var sky = new THREE.Mesh(new THREE.SphereGeometry(2500, 32, 16), sceneMat({
        side: THREE.BackSide,
        depthWrite: false,
        uniforms: { uMoon: { value: ctx.color('#f4f0e2') } },
        vertexShader: [
          'varying vec3 vDir;',
          'void main() { vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uMoon;',
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  vec3 c = skyBase(d);',
          // the moon: a disc of about 2.3 degrees with soft maria and a bright limb
          '  float ang = acos(clamp(dot(d, uMoonDir), -1.0, 1.0));',
          '  float R = 0.04;',
          '  vec3 tx = normalize(cross(uMoonDir, vec3(0.0, 1.0, 0.0)));',
          '  vec3 ty = cross(tx, uMoonDir);',
          '  vec2 q = vec2(dot(d, tx), dot(d, ty)) / R;',
          '  float disc = 1.0 - smoothstep(0.97, 1.02, length(q));',
          '  float maria = ev_fbm(q * 2.2 + 4.0);',
          '  vec3 moon = uMoon * (0.86 - 0.22 * smoothstep(0.45, 0.75, maria)) * (0.92 + 0.08 * sqrt(max(1.0 - dot(q, q), 0.0)));',
          // thin veils of cloud drifting across, silver-lined near the moon
          '  vec2 p = d.xz / max(d.y + 0.06, 0.02);',
          '  float v = ev_loopFbm(p * vec2(0.55, 1.6) + vec2(2.0, 7.0), vec2(0.03, 0.0), uTime);',
          '  float veil = smoothstep(0.5, 0.82, v) * smoothstep(0.03, 0.2, d.y) * (1.0 - smoothstep(0.6, 0.9, d.y));',
          '  float g = max(dot(d, uMoonDir), 0.0);',
          '  c = mix(c, moon, disc * (1.0 - veil * 0.55));',
          '  c += uMoonGlow * veil * (0.035 + 0.5 * pow(g, 30.0) + 0.12 * pow(g, 6.0));',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- mountains
      // [z, half-width, height, base colour, seed, frequency, fog density, snow]
      var ranges = [
        [-900, 900, 210, '#24375a', 1.0, 0.0028, 0.0011, 0.35],
        [-620, 650, 150, '#1a2a47', 2.0, 0.004, 0.0012, 0.2],
        [-380, 420, 80, '#111d33', 3.0, 0.007, 0.0014, 0.0],
      ];
      ranges.forEach(function (R, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uTop: { value: R[2] }, uCol: { value: ctx.color(R[3]) }, uSeed: { value: R[4] }, uFreq: { value: R[5] },
            uDens: { value: R[6] }, uSnow: { value: R[7] },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.RIDGE + '\n' + [
            'uniform float uTop; uniform vec3 uCol; uniform float uSeed; uniform float uFreq; uniform float uDens; uniform float uSnow;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            '  float h = uTop * (0.25 + 0.75 * ev_ridge(x, uSeed, uFreq));',
            '  float aa = fwidth(y) * 1.2;',
            '  float cov = smoothstep(-aa, aa, h - y);',
            '  if (cov < 0.01) discard;',
            // faint moonlit faces (slope from the profile) and snow near the crests
            '  float hl = uTop * (0.25 + 0.75 * ev_ridge(x - 10.0, uSeed, uFreq));',
            '  float hr = uTop * (0.25 + 0.75 * ev_ridge(x + 10.0, uSeed, uFreq));',
            '  float slope = clamp((hr - hl) / 14.0, -1.0, 1.0);',
            '  float crest = smoothstep(uTop * 0.45, 0.0, h - y);',
            '  float tex = ev_fbm3(vec2(x * 0.02, y * 0.045) + uSeed * 3.0);',
            '  vec3 c = uCol * (0.84 + 0.26 * slope * crest + 0.16 * (tex - 0.5));',
            '  c += vec3(0.14, 0.18, 0.26) * uSnow * crest * smoothstep(0.52, 0.7, tex) * (0.4 + 0.6 * max(slope, 0.0));',
            '  c = applyFog(c, vWorld, uDens);',
            // mist lying on the water at the foot of the mountains
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.02, vWorld.z))), exp(-max(y, 0.0) / (uTop * 0.18)) * (0.55 + 0.3 * uMist));',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), R[0], R[1], R[2] + 2, -2);
        m.material.alphaToCoverage = true;
        m.renderOrder = -8 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- pine shores
      // [z, spacing, heights, width, gap, detail, seed, x offset of the bank]
      var shores = [
        [-210, 3.6, [7, 16], 0.2, 0, 0.5, 11, 0],
        [-120, 4.0, [6, 19], 0.2, 0, 0.6, 23, 0],
      ];
      shores.forEach(function (row, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uSpacing: { value: row[1] }, uHeight: { value: new THREE.Vector2(row[2][0], row[2][1]) },
            uWidth: { value: row[3] }, uGap: { value: row[4] }, uSeed: { value: row[6] },
            uDetail: { value: row[5] }, uSway: { value: 0.0 }, uDens: { value: idx === 0 ? 0.0024 : 0.0022 },
            uBank: { value: idx },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.TREELINE + '\n' + [
            'uniform float uDens; uniform float uBank;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            // the forest rises and falls with the shore (hills), and thins out in places
            '  float hill = 2.2 * ev_noise(vec2(x * 0.02, uSeed)) + 1.4 * ev_noise(vec2(x * 0.07, uSeed + 2.0));',
            '  float d = ev_treeDist(x, y - hill);',
            '  float ground = hill + 0.4 - y;',
            '  d = max(d, ground);',
            '  float aa = fwidth(x) * 1.0;',
            '  float cov = smoothstep(-aa, aa, d);',
            '  if (cov < 0.01) discard;',
            '  vec3 c = vec3(0.012, 0.022, 0.035);',
            '  c = applyFog(c, vWorld, uDens);',
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.02, vWorld.z))), exp(-max(y, 0.0) / 2.5) * (0.35 + 0.35 * uMist));',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), row[0], 280, 30, -1);
        m.material.alphaToCoverage = true;
        m.renderOrder = -5 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- lake (mirror)
      var lake = ctx.mirror({
        y: 0,
        size: [900, 1200],
        center: [0, -500],
        scale: 0.4,
        uniforms: Object.assign({ uDeep: { value: ctx.color('#03070f') }, uGlint: { value: ctx.color('#fff6e0') } }, shared),
        fragmentShader: SCENE_GLSL + '\n' + [
          'uniform vec3 uDeep; uniform vec3 uGlint;',
          'varying vec4 vMirror; varying vec3 vWorld;',
          'float ripple(vec2 p) {',
          '  return ev_loopFbm3(p, vec2(0.0, 0.18), uTime);',
          '}',
          'void main() {',
          '  vec3 toCam = cameraPosition - vWorld;',
          '  float dist = length(toCam);',
          '  vec3 V = toCam / dist;',
          // small ripples, stretched across the view, fading with distance
          '  vec2 p = vWorld.xz * vec2(0.9, 2.6);',
          '  float e = 0.06;',
          '  float h0 = ripple(p);',
          '  float hx = ripple(p + vec2(e, 0.0));',
          '  float hz = ripple(p + vec2(0.0, e));',
          '  float amp = mix(0.22, 0.75, smoothstep(4.0, 60.0, dist)) / (1.0 + dist * 0.006);',
          // ripples finer than a pixel would shimmer: fade them by their footprint on screen
          '  vec2 fw = fwidth(p);',
          '  float sharp = 1.0 - smoothstep(0.025, 0.11, max(fw.x, fw.y));',
          '  amp *= sharp;',
          '  vec3 n = normalize(vec3(-(hx - h0) / e * amp, 1.0, -(hz - h0) / e * amp * 2.6));',
          '  vec2 uv = vMirror.xy / vMirror.w + n.xz * vec2(0.012, 0.03) / (1.0 + dist * 0.02);',
          '  uv = clamp(uv, vec2(0.002), vec2(0.998));',
          '  vec3 refl = ev_mirror(uv);',
          '  float cosv = max(dot(V, n), 0.0);',
          '  float fres = 0.04 + 0.96 * pow(1.0 - cosv, 5.0);',
          // near the viewer the water is dark (the lower third stays readable)
          '  float far = smoothstep(3.0, 40.0, dist);',
          '  vec3 c = mix(uDeep, refl, clamp(fres * 0.7 + 0.04 + 0.45 * far * far, 0.0, 0.88));',
          // the moon path: glints where the ripples face the moon (near), and far away, where the
          // ripples are too small to see, a soft column of glitter under the moon
          '  vec3 R = reflect(-V, n);',
          '  float g = max(dot(R, uMoonDir), 0.0);',
          '  float glint = (pow(g, 320.0) * 1.7 + pow(g, 60.0) * 0.07) * sharp;',
          '  float sparkle = 0.6 + 0.4 * ev_wave(3.0, ev_hash12(floor(vWorld.xz * 3.0)), uTime);',
          '  vec3 R0 = reflect(-V, vec3(0.0, 1.0, 0.0));',
          '  float dAz = atan(R0.x, -R0.z) - atan(uMoonDir.x, -uMoonDir.z);',
          '  float dEl = asin(clamp(R0.y, -1.0, 1.0)) - asin(uMoonDir.y);',
          '  float column = exp(-dAz * dAz / 0.0012) * exp(-dEl * dEl / 0.35);',
          '  float shimmer = 0.75 + 0.25 * sin(EV_TAU * (3.0 * uTime / EV_PERIOD) + vWorld.z * 0.35 + h0 * 6.0);',
          '  c += uGlint * (glint * sparkle * (0.25 + 0.75 * far) + column * shimmer * 0.3 * (1.0 - 0.7 * sharp) * far);',
          '  c = applyFog(c, vWorld, 0.0009);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      });
      lake.layers.set(1);
      scene.add(lake);

      // ---------------------------------------------------------------- reeds (foreground)
      var reedCount = 110;
      var rg = new THREE.InstancedBufferGeometry();
      var seg = 8, rv = [];
      for (var s = 0; s < seg; s++) {
        var a0 = s / seg, a1 = (s + 1) / seg;
        rv.push(-1, a0, 0, 1, a0, 0, 1, a1, 0, -1, a0, 0, 1, a1, 0, -1, a1, 0);
      }
      rg.setAttribute('position', new THREE.Float32BufferAttribute(rv, 3));
      var ra = [], rb = [];
      for (var k = 0; k < reedCount; k++) {
        var side = k % 3 === 0 ? 1 : -1;
        var zr = 6.8 - Math.pow(r(), 0.7) * 5.5;
        var x = side * (0.45 + (6.8 - zr) * 0.2 + Math.pow(r(), 0.8) * 1.3);
        ra.push(x, zr, 0.6 + r() * 1.1, r() * 0.86);
        rb.push(r(), r() * 0.22 * -side, 0.008 + r() * 0.012, r());
      }
      rg.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(ra), 4));
      rg.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(rb), 4));
      rg.instanceCount = reedCount;
      var reeds = new THREE.Mesh(rg, sceneMat({
        side: THREE.DoubleSide,
        vertexShader: [
          'attribute vec4 aA; attribute vec4 aB;',
          'varying vec3 vWorld; varying float vU; varying float vTop;',
          'void main() {',
          '  float u = position.y;',
          '  float lean = aB.y + 0.05 * ev_wave(2.0, aB.x, uTime) + 0.03 * ev_wave(3.0, aB.w, uTime);',
          '  vec3 p = vec3(lean * u * u * aA.z, u * aA.z, 0.0);',
          '  float w = aB.z * (1.0 - u * 0.9);',
          '  p.x += position.x * w;',
          '  vec3 wp = vec3(aA.x, -0.15, aA.y) + p;',
          '  vWorld = wp; vU = u; vTop = aA.w;',
          '  gl_Position = projectionMatrix * viewMatrix * vec4(wp, 1.0);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld; varying float vU; varying float vTop;',
          'void main() {',
          '  vec3 c = vec3(0.010, 0.016, 0.022) + vec3(0.05, 0.06, 0.08) * vU * vU * 0.6;',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      reeds.frustumCulled = false;
      scene.add(reeds);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var decors = {
        etoiles: D.etoiles(ctx, {
          count: 1400, radius: 2000, azimuth: [-4, 42], elevation: [3, 80], size: 1.0,
          band: { normal: [0.55, 0.35, 0.75], width: 0.16, count: 1600 },
        }),
        'etoiles-filantes': D['etoiles-filantes'](ctx, { radius: 1800, azimuth: [0, 26], elevation: [32, 62] }),
        brume: D.brume(ctx, {
          color: '#6f86a6',
          layers: [
            { y: 3, z: -300, width: 900, height: 22, opacity: 0.5, scale: 0.02, drift: 0.25, rank: 0.0, top: 0.6 },
            { y: 1.2, z: -110, width: 300, height: 8, opacity: 0.42, scale: 0.05, drift: -0.12, rank: 0.1, top: 0.5 },
            { y: 0.5, z: -40, width: 120, height: 3.5, opacity: 0.3, scale: 0.12, drift: 0.06, rank: 0.3, top: 0.5 },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
        lucioles: D.lucioles(ctx, {
          count: 110, box: { min: [-5.5, 0.3, -6], max: [5.5, 2.4, 7] }, size: 0.13, color: '#e8f2a8', lowBias: 1.2,
        }),
        neige: D.neige(ctx, {
          count: 1600, box: { min: [-9, -0.2, -14], max: [9, 10, 8.5] }, size: [0.02, 0.05], color: '#e6edf8', opacity: 0.85,
        }),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });
      // snow and fireflies are reflected; snowflakes need not be (they would double the cost)
      decors.neige.object.layers.set(1);

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.3 * Math.sin(T), 1.55 + 0.04 * Math.sin(2 * T), 10 + 0.2 * Math.cos(T));
        camera.lookAt(0.6 * Math.sin(T + 0.3), 7.5, -60);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
