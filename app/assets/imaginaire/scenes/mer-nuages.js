/*
 * « Mer de nuages »: above a sea of clouds at dawn. The sun rises on the horizon; the cloud
 * tops catch gold on their faces and lavender in their hollows; mountain peaks rise from the sea
 * in a violet haze; a dark ridge in the foreground. The clouds flow slowly toward the viewer.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  var SCENE_GLSL = [
    'uniform vec3 uZenith; uniform vec3 uMid; uniform vec3 uLow; uniform vec3 uSun; uniform vec3 uSunDir; uniform float uMist;',
    'vec3 skyBase(vec3 d) {',
    '  float g = max(dot(d, uSunDir), 0.0);',
    '  float y = d.y;',
    '  vec3 c = mix(uLow, uMid, smoothstep(0.0, 0.22, y));',
    '  c = mix(c, uZenith, smoothstep(0.18, 0.75, y));',
    '  c += uSun * (pow(g, 5.0) * 0.18 + pow(g, 40.0) * 0.3 + pow(g, 3000.0) * 1.5);',
    '  return c;',
    '}',
    'vec3 applyFog(vec3 col, vec3 worldPos, float density) {',
    '  vec3 d = worldPos - cameraPosition;',
    '  float dist = length(d);',
    '  vec3 dir = d / dist;',
    '  float f = 1.0 - exp(-dist * density * (1.0 + 0.8 * uMist));',
    '  return mix(col, skyBase(vec3(dir.x, max(dir.y, 0.0) * 0.5 + 0.01, dir.z)), clamp(f, 0.0, 1.0));',
    '}',
  ].join('\n');

  E.register({
    id: 'mer-nuages',
    decors: ['oiseaux-vol', 'etoiles', 'etoiles-filantes', 'brume', 'rayons-soleil'],
    defaults: { 'oiseaux-vol': 30, 'rayons-soleil': 40 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var S = window.EventideScenery;
      var r = ctx.rng('scene');
      camera.fov = 52;
      camera.near = 0.1;
      camera.far = 4000;

      var sunDir = new THREE.Vector3(-0.28, 0.045, -1).normalize();
      var shared = {
        uZenith: { value: ctx.color('#1a2a52') },
        uMid: { value: ctx.color('#7d7fa6') },
        uLow: { value: ctx.color('#f2b48c') },
        uSun: { value: ctx.color('#ffcf94') },
        uSunDir: { value: sunDir },
        uMist: { value: 0 },
      };
      function sceneMat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.fragmentShader = SCENE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- sky
      var sky = new THREE.Mesh(new THREE.SphereGeometry(3500, 32, 16), sceneMat({
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
          '  vec3 c = skyBase(d);',
          // a few high streaks of cirrus catching the dawn
          '  vec2 p = d.xz / max(d.y + 0.08, 0.02);',
          '  float ci = ev_loopFbm(p * vec2(0.35, 1.6) + 5.0, vec2(0.02, 0.0), uTime);',
          '  float g = max(dot(d, uSunDir), 0.0);',
          '  c += mix(vec3(0.9, 0.62, 0.62), uSun, g) * 0.16 * smoothstep(0.55, 0.85, ci) * smoothstep(0.06, 0.25, d.y) * (1.0 - smoothstep(0.5, 0.8, d.y));',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- peaks rising from the clouds
      [
        [-1500, 1500, 260, '#4d4a72', 21.0, 0.0018, 0.00035, -60],
        [-900, 900, 170, '#3a3a60', 22.0, 0.003, 0.0004, -40],
        [-480, 520, 95, '#2b2c4c', 23.0, 0.0055, 0.0005, -25],
      ].forEach(function (R, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uTop: { value: R[2] }, uCol: { value: ctx.color(R[3]) }, uSeed: { value: R[4] }, uFreq: { value: R[5] },
            uDens: { value: R[6] }, uBase: { value: R[7] },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.RIDGE + '\n' + [
            'uniform float uTop; uniform vec3 uCol; uniform float uSeed; uniform float uFreq; uniform float uDens; uniform float uBase;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            '  float rr = ev_ridge(x, uSeed, uFreq);',
            '  float h = uBase + (uTop - uBase) * pow(rr, 1.6);',
            '  float aa = fwidth(y) * 1.2;',
            '  float cov = smoothstep(-aa, aa, h - y);',
            '  if (cov < 0.01) discard;',
            // faces turned to the sun (on its side, the left) are lit gold-pink
            '  float hl = uBase + (uTop - uBase) * pow(ev_ridge(x - 12.0, uSeed, uFreq), 1.6);',
            '  float hr = uBase + (uTop - uBase) * pow(ev_ridge(x + 12.0, uSeed, uFreq), 1.6);',
            '  float face = clamp((hr - hl) / 30.0, -1.0, 1.0);',
            '  float crest = smoothstep(uTop * 0.5, 0.0, h - y);',
            '  float tex = ev_fbm3(vec2(x * 0.03, y * 0.05) + uSeed);',
            '  vec3 c = uCol * (0.85 + 0.25 * (tex - 0.5));',
            '  c += uSun * 0.35 * max(face, 0.0) * crest * (0.6 + 0.4 * tex);',
            '  c = applyFog(c, vWorld, uDens);',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), R[0], R[1], R[2] + 2, R[7] - 2);
        m.material.alphaToCoverage = true;
        m.renderOrder = -8 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- the sea of clouds
      // A soft deck, then a few thousand lit cloud puffs (camera-facing sprites, drawn far to
      // near) drifting slowly toward the viewer; each puff lives one period: it swells in, drifts,
      // and melts away, so the sea is always the same and always moving.
      var deckGeo = new THREE.PlaneGeometry(6000, 4000, 1, 1);
      deckGeo.rotateX(-Math.PI / 2);
      deckGeo.translate(0, -3.2, -1900);
      var deck = new THREE.Mesh(deckGeo, sceneMat({
        uniforms: { uHollow: { value: ctx.color('#625d88') } },
        vertexShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uHollow;',
          'varying vec3 vWorld;',
          'void main() {',
          '  float n = ev_loopFbm3(vWorld.xz * vec2(0.02, 0.035), vec2(0.0, 0.03), uTime);',
          '  vec3 V = normalize(cameraPosition - vWorld);',
          '  float toward = pow(max(dot(-V, uSunDir), 0.0), 5.0);',
          '  vec3 c = uHollow * (0.85 + 0.35 * n) + uSun * toward * 0.25;',
          '  c = applyFog(c, vWorld, 0.0004);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      deck.frustumCulled = false;
      deck.renderOrder = -4;
      scene.add(deck);

      var PUFFS = ctx.quality === 'low' ? 800 : 1300;
      var pg = new THREE.InstancedBufferGeometry();
      pg.setAttribute('position', new THREE.Float32BufferAttribute(new Float32Array(18), 3));
      pg.setAttribute('corner', new THREE.Float32BufferAttribute([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1], 2));
      var puffs = [];
      for (var i = 0; i < PUFFS; i++) {
        var u = r();
        var d = 13 * Math.pow(900 / 13, Math.pow(u, 0.95));
        var spread = d * 0.62 + 14;
        var x = (r() * 2 - 1) * spread - 6;
        var z = 14 - d;
        var rad = (2.6 + d * 0.058) * (0.7 + r() * 0.7);
        puffs.push([x, z, rad, r(), r(), r()]);
      }
      puffs.sort(function (a, b) { return a[1] - b[1]; }); // far (most negative z) first
      var pa = [], pb = [];
      puffs.forEach(function (p) {
        pa.push(p[0], p[1], p[2], p[3]);
        pb.push(p[4], p[5], 0, 0);
      });
      pg.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(pa), 4));
      pg.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(pb), 4));
      pg.instanceCount = PUFFS;
      // light, shade with distance and fog are computed per puff (vertex), the fragment only
      // shapes the cauliflower edge: the sea's cost is its overdraw
      var puffMesh = new THREE.Mesh(pg, sceneMat({
        transparent: true,
        depthWrite: false,
        uniforms: { uHollow: { value: ctx.color('#5c5784') }, uLit: { value: ctx.color('#ffd6b4') } },
        vertexShader: [
          'uniform vec3 uZenith; uniform vec3 uMid; uniform vec3 uLow; uniform vec3 uSun; uniform vec3 uSunDir; uniform float uMist;',
          'uniform vec3 uHollow; uniform vec3 uLit;',
          'attribute vec2 corner; attribute vec4 aA; attribute vec4 aB;',
          'varying vec2 vUv; varying float vLife; varying float vSeed;',
          'varying vec3 vShadow; varying vec3 vLight; varying vec3 vRim; varying vec3 vFog; varying float vFogF;',
          'vec3 skyAt(vec3 d) {',
          '  float g = max(dot(d, uSunDir), 0.0);',
          '  vec3 c = mix(uLow, uMid, smoothstep(0.0, 0.22, d.y));',
          '  c = mix(c, uZenith, smoothstep(0.18, 0.75, d.y));',
          '  return c + uSun * (pow(g, 5.0) * 0.18 + pow(g, 40.0) * 0.3);',
          '}',
          'void main() {',
          '  float life = fract(aA.w + uTime / EV_PERIOD);',
          '  float drift = life * 30.0 * 0.9;',
          '  vec3 c = vec3(aA.x, -3.2, aA.y + drift - 13.5);',
          '  float swell = sin(3.14159 * life);',
          '  float rad = aA.z * (0.75 + 0.25 * swell);',
          '  vec3 toCam = normalize(cameraPosition - c);',
          '  vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), toCam));',
          '  vec3 up = cross(toCam, right);',
          // wide, low puffs: they sit on the deck
          '  vec3 wp = c + right * corner.x * rad * 1.5 + up * (corner.y * 0.5 + 0.35) * rad * 0.9;',
          '  vUv = corner; vLife = swell; vSeed = aB.x;',
          '  vec3 d = wp - cameraPosition;',
          '  float dist = length(d);',
          '  float toward = pow(max(dot(d / dist, uSunDir), 0.0), 5.0);',
          '  float shade = mix(0.72, 1.0, smoothstep(15.0, 120.0, dist));',
          '  vShadow = uHollow * shade;',
          '  vLight = mix(vec3(0.94, 0.82, 0.84), uLit, 0.6) * shade;',
          '  vRim = uSun * (0.12 + 0.5 * toward) * shade;',
          '  vFogF = clamp(1.0 - exp(-dist * 0.0004 * (1.0 + 0.8 * uMist)), 0.0, 1.0);',
          '  vec3 dir = d / dist;',
          '  vFog = skyAt(vec3(dir.x, max(dir.y, 0.0) * 0.5 + 0.01, dir.z));',
          '  gl_Position = projectionMatrix * viewMatrix * vec4(wp, 1.0);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec2 vUv; varying float vLife; varying float vSeed;',
          'varying vec3 vShadow; varying vec3 vLight; varying vec3 vRim; varying vec3 vFog; varying float vFogF;',
          'void main() {',
          '  vec2 q = vUv * vec2(1.0, 1.25) + vec2(0.0, 0.25);',
          '  float r0 = length(q);',
          '  if (r0 > 1.25) discard;',
          '  float n = ev_fbm3(vUv * 2.2 + vSeed * 31.0);',
          // a cauliflower edge: a dome eroded by noise
          '  float r = r0 + (n - 0.5) * 0.55;',
          '  float body = 1.0 - smoothstep(0.62, 0.95, r);',
          '  if (body < 0.01) discard;',
          '  float top = clamp(vUv.y * 0.5 + 0.5, 0.0, 1.0);',
          '  float light = clamp(top * 0.75 + n * 0.35 - 0.1, 0.0, 1.0) * (0.75 + 0.5 * clamp(0.5 - vUv.x * 0.35, 0.0, 1.0));',
          '  vec3 c = mix(vShadow, vLight, light);',
          // the rim of each puff glows when the sun is behind it
          '  c += vRim * smoothstep(0.45, 0.85, r) * top;',
          '  c = mix(c, vFog, vFogF);',
          '  gl_FragColor = vec4(ev_dither(c), body * smoothstep(0.0, 0.45, vLife));',
          '}',
        ].join('\n'),
      }));
      puffMesh.frustumCulled = false;
      puffMesh.renderOrder = 1;
      scene.add(puffMesh);

      // ---------------------------------------------------------------- foreground ridge
      // A dark rocky crest across the bottom of the view, a few pines on it, its edge lit by the
      // sun on the left.
      var ridge = S.rowQuad(sceneMat({
        uniforms: {
          uSeedR: { value: 4.2 }, uSpacing: { value: 1.0 }, uHeight: { value: new THREE.Vector2(1.0, 2.6) },
          uWidth: { value: 0.2 }, uGap: { value: 0 }, uSeed: { value: 3.0 }, uDetail: { value: 1.0 }, uSway: { value: 0.004 },
          uThin: { value: 0.62 },
        },
        vertexShader: S.ROW_VERTEX,
        fragmentShader: S.RIDGE + '\n' + S.TREELINE + '\n' + [
          'uniform float uSeedR;',
          'varying vec3 vWorld; varying vec2 vLocal;',
          'float crest(float x) {',
          '  float side = smoothstep(0.0, 10.0, abs(x + 1.0));',
          '  return 0.2 + 4.0 * side * side + 1.2 * ev_ridge(x, uSeedR, 0.16) + 0.2 * ev_noise(vec2(x * 2.5, 1.0));',
          '}',
          'void main() {',
          '  float x = vLocal.x; float y = vLocal.y;',
          '  float h = crest(x);',
          '  float aa = fwidth(y) * 1.2;',
          '  float d = max(h - y, ev_treeDist(x, y - h + 0.12));',
          '  float cov = smoothstep(-aa, aa, d);',
          '  if (cov < 0.01) discard;',
          // the rim of the rock catches the low sun (stronger toward the sun, on the left)
          '  float slope = (crest(x + 0.4) - crest(x - 0.4)) / 0.8;',
          '  float rim = (1.0 - smoothstep(0.0, 0.1, h - y)) * step(0.0, h - y) * clamp(0.4 + slope * 0.8, 0.0, 1.0);',
          '  vec3 c = vec3(0.04, 0.036, 0.062) + uSun * rim * 0.16 * smoothstep(8.0, -10.0, x);',
          '  gl_FragColor = vec4(ev_dither(c), cov);',
          '}',
        ].join('\n'),
      }), 2.0, 40, 9, -6);
      ridge.material.alphaToCoverage = true;
      scene.add(ridge);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var sunFar = sunDir.clone().multiplyScalar(1400);
      var decors = {
        'oiseaux-vol': D['oiseaux-vol'](ctx, {
          size: 1.7, color: '#241f33', fog: '#c9a8a6', fogDensity: 0.004,
          flocks: [
            { count: 7, x0: -70, x1: 70, y: 16, z: -60, spacing: 1.6, phase: 0.1, size: 1.1, dir: 1 },
            { count: 5, x0: -90, x1: 90, y: 24, z: -95, spacing: 2.0, phase: 0.62, size: 1.3, dir: -1 },
          ],
          soaring: [
            { count: 3, x: -14, y: 13, z: -45, dx: 6, dy: 3, dz: 6, radius: [4, 7], size: 1.0, turns: 1 },
          ],
        }),
        'rayons-soleil': D['rayons-soleil'](ctx, {
          origin: [sunFar.x, sunFar.y, sunFar.z], toward: [sunFar.x + 300, sunFar.y + 900, sunFar.z + 500],
          spread: 0.95, count: 11, length: 1500, width: [10, 150], color: '#ffd7a8', intensity: 0.13,
          motes: 0, spreadAxis: [0, 0, 1],
        }),
        etoiles: D.etoiles(ctx, {
          count: 700, radius: 3000, azimuth: [0, 40], elevation: [28, 85], size: 0.9, brightness: 0.8,
        }),
        'etoiles-filantes': D['etoiles-filantes'](ctx, { radius: 2800, azimuth: [10, 24], elevation: [38, 68] }),
        brume: D.brume(ctx, {
          color: '#e9c2b4',
          layers: [
            { y: -1, z: -380, width: 1600, height: 40, opacity: 0.45, scale: 0.012, drift: 0.6, rank: 0.0, top: 0.6 },
            { y: -2, z: -140, width: 600, height: 16, opacity: 0.4, scale: 0.03, drift: -0.3, rank: 0.15, top: 0.55 },
            { y: -1.5, z: -40, width: 200, height: 7, opacity: 0.3, scale: 0.08, drift: 0.12, rank: 0.35, top: 0.5, color: '#c7a6b4' },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.5 * Math.sin(T), 4.4 + 0.05 * Math.sin(2 * T), 14 + 0.3 * Math.cos(T));
        camera.lookAt(-6 + 0.8 * Math.sin(T + 0.3), 5.6, -60);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
