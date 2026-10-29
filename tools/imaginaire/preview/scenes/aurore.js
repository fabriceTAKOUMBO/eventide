/*
 * « Aurore boréale »: an arctic night. Curtains of aurora (green, with teal and violet edges)
 * fold slowly above snowy mountains; a still lake mirrors them; snow-laden pines on the shore.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  var SCENE_GLSL = [
    'uniform vec3 uHorizon; uniform vec3 uZenith; uniform vec3 uAuroraTint; uniform float uMist;',
    'vec3 skyBase(vec3 d) {',
    '  vec3 c = mix(uHorizon, uZenith, smoothstep(-0.02, 0.6, d.y));',
    // a faint green airglow low in the sky, toward the aurora
    '  c += uAuroraTint * 0.07 * exp(-abs(d.y - 0.08) * 9.0) * smoothstep(0.2, -0.9, d.z);',
    '  return c;',
    '}',
    'vec3 applyFog(vec3 col, vec3 worldPos, float density) {',
    '  vec3 d = worldPos - cameraPosition;',
    '  float dist = length(d);',
    '  vec3 dir = d / dist;',
    '  float f = 1.0 - exp(-dist * density * (1.0 + 0.8 * uMist));',
    '  return mix(col, skyBase(vec3(dir.x, abs(dir.y) * 0.3, dir.z)), clamp(f, 0.0, 1.0));',
    '}',
  ].join('\n');

  // One curtain of aurora: a vertical ribbon following a slowly folding curve.
  function curtain(ctx, sceneMat, o) {
    var seg = 160;
    var pos = [], uv = [], idx = [];
    for (var i = 0; i <= seg; i++) {
      var u = i / seg;
      pos.push(u, 0, 0, u, 1, 0);
      uv.push(u, 0, u, 1);
      if (i < seg) {
        var a = i * 2;
        idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
      }
    }
    var g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setIndex(idx);
    var m = sceneMat({
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      side: THREE.DoubleSide,
      uniforms: {
        uX: { value: new THREE.Vector2(o.x0, o.x1) }, uZ: { value: o.z }, uBase: { value: o.base },
        uHeightA: { value: o.height }, uFold: { value: new THREE.Vector4(o.fold[0], o.fold[1], o.fold[2], o.fold[3]) },
        uSeed: { value: o.seed }, uGain: { value: o.gain },
        uLow: { value: ctx.color(o.low) }, uMid: { value: ctx.color(o.mid) }, uHigh: { value: ctx.color(o.high) },
      },
      vertexShader: [
        'uniform vec2 uX; uniform float uZ; uniform float uBase; uniform float uHeightA; uniform vec4 uFold; uniform float uSeed;',
        'varying vec2 vUv; varying float vFold;',
        'void main() {',
        '  float u = position.x;',
        '  float T = uTime / EV_PERIOD;',
        '  float x = mix(uX.x, uX.y, u);',
        // the curve folds: travelling waves of whole turns per period
        '  float w1 = sin(EV_TAU * (u * uFold.x + T + uSeed));',
        '  float w2 = sin(EV_TAU * (u * uFold.y - 2.0 * T + uSeed * 1.7));',
        '  float z = uZ + uFold.z * w1 + uFold.w * w2;',
        '  float base = uBase + 18.0 * sin(EV_TAU * (u * 1.3 + T + uSeed * 0.3));',
        '  float h = uHeightA * (0.75 + 0.25 * sin(EV_TAU * (u * 2.1 - T + uSeed)));',
        '  vec3 p = vec3(x, base + position.y * h, z);',
        '  vUv = vec2(u, position.y);',
        // folds facing the viewer look brighter (the curtain is seen edge-on)
        '  vFold = 0.5 + 0.5 * abs(cos(EV_TAU * (u * uFold.x + T + uSeed)));',
        '  gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'uniform float uSeed; uniform float uGain; uniform vec3 uLow; uniform vec3 uMid; uniform vec3 uHigh;',
        'varying vec2 vUv; varying float vFold;',
        'void main() {',
        '  float u = vUv.x; float v = vUv.y;',
        // fine vertical rays, drifting along the curtain (loops over the period)
        '  float rays = ev_loopFbm3(vec2(u * 90.0 + uSeed * 10.0, v * 0.6), vec2(1.2, 0.0), uTime);',
        '  rays = 0.35 + 0.95 * smoothstep(0.3, 0.85, rays);',
        '  float patches = ev_loopFbm3(vec2(u * 6.0 + uSeed, 0.5), vec2(0.12, 0.0), uTime);',
        '  patches = smoothstep(0.25, 0.75, patches);',
        // a bright lower edge, then a long fading glow upward
        '  float edge = smoothstep(0.0, 0.06, v);',
        '  float fall = exp(-v * 3.2);',
        '  float profile = edge * (0.25 * fall + 0.75 * fall * fall) + 0.18 * edge * exp(-v * 1.2) * smoothstep(1.0, 0.6, v);',
        '  vec3 col = mix(uLow, uMid, smoothstep(0.08, 0.45, v));',
        '  col = mix(col, uHigh, smoothstep(0.4, 0.95, v));',
        '  float ends = smoothstep(0.0, 0.12, u) * smoothstep(1.0, 0.88, u);',
        '  float a = profile * rays * patches * vFold * ends * uGain;',
        '  gl_FragColor = vec4(ev_dither(col * a), 1.0);',
        '}',
      ].join('\n'),
    });
    var mesh = new THREE.Mesh(g, m);
    mesh.frustumCulled = false;
    mesh.renderOrder = -6;
    return mesh;
  }

  E.register({
    id: 'aurore',
    decors: ['neige', 'etoiles', 'etoiles-filantes', 'brume'],
    defaults: { etoiles: 50, neige: 30 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var S = window.EventideScenery;
      camera.fov = 54;
      camera.near = 0.1;
      camera.far = 3600;

      var shared = {
        uHorizon: { value: ctx.color('#0f2130') },
        uZenith: { value: ctx.color('#02050d') },
        uAuroraTint: { value: ctx.color('#3dffa0') },
        uMist: { value: 0 },
      };
      function sceneMat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.fragmentShader = SCENE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- sky
      var sky = new THREE.Mesh(new THREE.SphereGeometry(3000, 32, 16), sceneMat({
        side: THREE.BackSide,
        depthWrite: false,
        vertexShader: [
          'varying vec3 vDir;',
          'void main() { vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  gl_FragColor = vec4(ev_dither(skyBase(d)), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- aurora
      // far behind the mountains (the mountains cut their lower edge)
      [
        { x0: -1500, x1: 1250, z: -1250, base: 230, height: 780, fold: [1.3, 2.9, 420, 120], seed: 0.13, gain: 1.15, low: '#4dffa6', mid: '#2fd6b0', high: '#7a55ff' },
        { x0: -1100, x1: 1600, z: -1050, base: 190, height: 560, fold: [2.2, 4.1, 130, 46], seed: 0.57, gain: 0.8, low: '#62ff9c', mid: '#25c8a6', high: '#b05cff' },
        { x0: -1800, x1: 900, z: -1650, base: 330, height: 900, fold: [1.2, 2.6, 230, 90], seed: 0.83, gain: 0.6, low: '#3cf0b0', mid: '#2aa6c8', high: '#5a48ff' },
      ].forEach(function (o) { scene.add(curtain(ctx, sceneMat, o)); });

      // ---------------------------------------------------------------- snowy ranges
      // [z, half-width, height, colour, seed, frequency, fog, snow]
      [
        [-650, 750, 165, '#101e31', 5.0, 0.005, 0.0005, 1.0],
        [-300, 420, 55, '#070f1a', 6.0, 0.012, 0.0009, 0.35],
      ].forEach(function (R, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uTop: { value: R[2] }, uCol: { value: ctx.color(R[3]) }, uSeed: { value: R[4] }, uFreq: { value: R[5] },
            uDens: { value: R[6] }, uSnow: { value: R[7] }, uSnowCol: { value: ctx.color('#9fc9d6') },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.RIDGE + '\n' + [
            'uniform float uTop; uniform vec3 uCol; uniform float uSeed; uniform float uFreq; uniform float uDens; uniform float uSnow; uniform vec3 uSnowCol;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            '  float h = uTop * (0.2 + 0.8 * ev_ridge(x, uSeed, uFreq));',
            '  float aa = fwidth(y) * 1.2;',
            '  float cov = smoothstep(-aa, aa, h - y);',
            '  if (cov < 0.01) discard;',
            '  float hl = uTop * (0.2 + 0.8 * ev_ridge(x - 10.0, uSeed, uFreq));',
            '  float hr = uTop * (0.2 + 0.8 * ev_ridge(x + 10.0, uSeed, uFreq));',
            '  float slope = clamp((hr - hl) / 14.0, -1.0, 1.0) * smoothstep(h * 0.3, h, y);',
            '  float tex = ev_fbm3(vec2(x * 0.025, y * 0.06) + uSeed * 3.0);',
            // snow on the upper slopes, lit by the aurora (greenish) on the faces turned to it
            '  float rel = (y - h * 0.5) / (h * 0.5) + 0.35 * (ev_noise(vec2(x * 0.06, uSeed)) - 0.5) + 0.25 * (tex - 0.5);',
            '  float snow = smoothstep(0.0, 0.25, rel) * uSnow;',
            '  vec3 lit = mix(uSnowCol, uAuroraTint, 0.25) * (0.3 + 0.25 * (y / max(h, 1.0)) + 0.35 * max(slope, 0.0));',
            '  vec3 c = mix(uCol * (0.85 + 0.2 * (tex - 0.5)), lit, snow * 0.75);',
            '  c = applyFog(c, vWorld, uDens);',
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.03, vWorld.z))), exp(-max(y, 0.0) / (uTop * 0.15)) * (0.5 + 0.3 * uMist));',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), R[0], R[1], R[2] + 2, -2);
        m.material.alphaToCoverage = true;
        m.renderOrder = -8 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- snowy pines on the shore
      [
        [-160, 3.2, [5, 16], 0.2, 0, 0.55, 31, 0.0022],
        [-60, 4.2, [7, 22], 0.21, 20, 0.75, 41, 0.0024],
      ].forEach(function (row, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uSpacing: { value: row[1] }, uHeight: { value: new THREE.Vector2(row[2][0], row[2][1]) },
            uWidth: { value: row[3] }, uGap: { value: row[4] }, uSeed: { value: row[6] },
            uDetail: { value: row[5] }, uSway: { value: 0.0 }, uDens: { value: row[7] }, uThin: { value: idx === 0 ? 0.35 : 0.15 },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.TREELINE + '\n' + [
            'uniform float uDens;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            '  float hill = 2.5 * ev_noise(vec2(x * 0.02, uSeed)) + 1.2 * ev_noise(vec2(x * 0.08, uSeed + 2.0));',
            '  float d = max(ev_treeDist(x, y - hill), hill + 0.3 - y);',
            '  float aa = fwidth(x);',
            '  float cov = smoothstep(-aa, aa, d);',
            '  if (cov < 0.01) discard;',
            // snow caught on the top of each tier
            '  float above = ev_treeDist(x, y - hill + aa * 3.0);',
            '  float snowCap = (1.0 - smoothstep(-aa, aa, above)) * step(0.0, y - hill - 0.5);',
            '  float n = ev_noise(vec2(x * 3.0, y * 5.0));',
            '  vec3 c = vec3(0.012, 0.02, 0.03) + vec3(0.13, 0.2, 0.22) * snowCap * (0.5 + 0.5 * n);',
            '  c = applyFog(c, vWorld, uDens);',
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.02, vWorld.z))), exp(-max(y, 0.0) / 2.0) * (0.3 + 0.35 * uMist));',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), row[0], 300, 22, -1);
        m.material.alphaToCoverage = true;
        m.renderOrder = -5 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- still lake
      var lake = ctx.mirror({
        y: 0,
        size: [1000, 1200],
        center: [0, -480],
        scale: 0.4,
        uniforms: Object.assign({ uDeep: { value: ctx.color('#02060c') } }, shared),
        fragmentShader: SCENE_GLSL + '\n' + [
          'uniform vec3 uDeep;',
          'varying vec4 vMirror; varying vec3 vWorld;',
          'void main() {',
          '  vec3 toCam = cameraPosition - vWorld;',
          '  float dist = length(toCam);',
          '  vec3 V = toCam / dist;',
          '  vec2 p = vWorld.xz * vec2(0.7, 2.2);',
          '  float e = 0.07;',
          '  float h0 = ev_loopFbm3(p, vec2(0.0, 0.12), uTime);',
          '  float hx = ev_loopFbm3(p + vec2(e, 0.0), vec2(0.0, 0.12), uTime);',
          '  float hz = ev_loopFbm3(p + vec2(0.0, e), vec2(0.0, 0.12), uTime);',
          '  float amp = 0.18 / (1.0 + dist * 0.01);',
          '  vec2 fw = fwidth(p);',
          '  amp *= 1.0 - smoothstep(0.025, 0.11, max(fw.x, fw.y));',
          '  vec3 n = normalize(vec3(-(hx - h0) / e * amp, 1.0, -(hz - h0) / e * amp * 2.2));',
          '  vec2 uv = clamp(vMirror.xy / vMirror.w + n.xz * vec2(0.01, 0.025), vec2(0.002), vec2(0.998));',
          '  vec3 refl = ev_mirror(uv);',
          '  float fres = 0.04 + 0.96 * pow(1.0 - max(dot(V, n), 0.0), 5.0);',
          '  float far = smoothstep(3.0, 50.0, dist);',
          '  vec3 c = mix(uDeep, refl, clamp(fres * 0.6 + 0.03 + 0.55 * far * far, 0.0, 0.9));',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      });
      lake.layers.set(1);
      scene.add(lake);

      // snowy bank in the foreground (dark, low): a gentle mound on each side
      var bankGeo = new THREE.PlaneGeometry(40, 14, 60, 20);
      bankGeo.rotateX(-Math.PI / 2);
      var bp = bankGeo.attributes.position;
      for (var i = 0; i < bp.count; i++) {
        var bx = bp.getX(i), bz = bp.getZ(i);
        var side = Math.abs(bx);
        var hgt = Math.max(0, side - 2.2 - (bz + 7) * 0.12) * 0.22 + 0.06 * Math.sin(bx * 1.3) * Math.cos(bz * 0.9);
        bp.setY(i, hgt - 0.12);
      }
      bankGeo.computeVertexNormals();
      bankGeo.translate(0, 0, 4);
      var bank = new THREE.Mesh(bankGeo, sceneMat({
        vertexShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz; vNormal = normal;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  if (vWorld.y < 0.0) discard;',
          '  float l = clamp(dot(normalize(vNormal), normalize(vec3(-0.2, 0.7, -1.0))), 0.0, 1.0);',
          '  float n = ev_fbm3(vWorld.xz * 2.0);',
          '  vec3 c = vec3(0.05, 0.08, 0.11) * (0.6 + 0.6 * l) * (0.85 + 0.3 * n) + uAuroraTint * 0.025 * l;',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      scene.add(bank);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var decors = {
        etoiles: D.etoiles(ctx, {
          count: 1500, radius: 2000, azimuth: [0, 44], elevation: [3, 85], size: 1.0,
          band: { normal: [-0.6, 0.3, 0.7], width: 0.15, count: 1500 },
        }),
        'etoiles-filantes': D['etoiles-filantes'](ctx, { radius: 1800, azimuth: [0, 26], elevation: [30, 65] }),
        neige: D.neige(ctx, {
          count: 1700, box: { min: [-9, -0.2, -14], max: [9, 11, 8.5] }, size: [0.02, 0.05], color: '#e8f2f6', opacity: 0.85,
          fall: [1, 2],
        }),
        brume: D.brume(ctx, {
          color: '#5f8796',
          layers: [
            { y: 3, z: -320, width: 900, height: 24, opacity: 0.45, scale: 0.02, drift: 0.25, rank: 0.0, top: 0.6 },
            { y: 1.2, z: -110, width: 300, height: 8, opacity: 0.38, scale: 0.05, drift: -0.12, rank: 0.12, top: 0.5 },
            { y: 0.5, z: -40, width: 120, height: 3.5, opacity: 0.26, scale: 0.12, drift: 0.06, rank: 0.3, top: 0.5 },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });
      decors.neige.object.layers.set(1);

      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.3 * Math.sin(T), 1.8 + 0.04 * Math.sin(2 * T), 10 + 0.2 * Math.cos(T));
        camera.lookAt(0.6 * Math.sin(T + 0.3), 16, -60);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
