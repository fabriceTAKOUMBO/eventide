/*
 * « Forêt aux lucioles » (free): a clearing in a pine forest at blue hour. Rows of pines recede
 * into a moonlit mist toward a glow; ferns at the edge of the clearing, fireflies above them.
 *
 * Each row of pines is one wide quad whose fragment shader draws a procedural tree line (ragged
 * tiers of branches, back-lit rims), placed at its own depth: the camera's slow drift gives
 * real parallax between the rows.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  var SCENE_GLSL = [
    'uniform vec3 uFogLow; uniform vec3 uFogHigh; uniform vec3 uGlow; uniform vec3 uGlowDir; uniform float uMist;',
    'vec3 fogColor(vec3 dir) {',
    '  float g = max(dot(dir, uGlowDir), 0.0);',
    '  vec3 c = mix(uFogLow, uFogHigh, smoothstep(-0.02, 0.4, dir.y));',
    '  return c + uGlow * (pow(g, 5.0) * 0.45 + pow(g, 60.0) * 0.55);',
    '}',
    'vec3 applyFog(vec3 col, vec3 worldPos, float density) {',
    '  vec3 d = worldPos - cameraPosition;',
    '  float dist = length(d);',
    '  float f = 1.0 - exp(-dist * density * (1.0 + 0.9 * uMist));',
    '  return mix(col, fogColor(d / dist), clamp(f, 0.0, 1.0));',
    '}',
  ].join('\n');

  // Ferns: arching fronds made of a comb of leaflets.
  function ferns(ctx, sceneMat, r, count) {
    var g = new THREE.InstancedBufferGeometry();
    var seg = 10, fv = [];
    for (var s = 0; s < seg; s++) {
      var a0 = s / seg, a1 = (s + 1) / seg;
      fv.push(-1, a0, 0, 1, a0, 0, 1, a1, 0, -1, a0, 0, 1, a1, 0, -1, a1, 0);
    }
    g.setAttribute('position', new THREE.Float32BufferAttribute(fv, 3));
    var fa = [], fb = [];
    for (var k = 0; k < count; k++) {
      var clump = Math.floor(r() * 30);
      var cr = ctx.rng('fern' + clump);
      var side = cr() < 0.5 ? -1 : 1;
      var cz = 6.2 - Math.pow(cr(), 0.9) * 16;
      var cx = side * (0.5 + Math.pow(cr(), 0.8) * (1.2 + (6.2 - cz) * 0.35));
      fa.push(cx + (r() - 0.5) * 0.5, cz + (r() - 0.5) * 0.5, r() * Math.PI * 2, 0.6 + r() * 0.55);
      fb.push(r(), 0.35 + r() * 0.5, r(), 0);
    }
    g.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(fa), 4));
    g.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(fb), 4));
    g.instanceCount = count;
    var mesh = new THREE.Mesh(g, sceneMat({
      side: THREE.DoubleSide,
      vertexShader: [
        'attribute vec4 aA; attribute vec4 aB;',
        'varying vec2 vUv; varying vec3 vWorld; varying float vShade;',
        'void main() {',
        '  float u = position.y;',
        '  float len = aA.w * 1.2;',
        '  float sway = 0.06 * ev_wave(2.0, aB.x, uTime) + 0.035 * ev_wave(3.0, aB.z, uTime);',
        '  float pitch = mix(1.2, -0.35, u) * aB.y + 0.3 + sway * u;',
        '  float along = u * len;',
        '  vec3 p = vec3(0.0, sin(pitch) * along * 0.75 + along * 0.3 * (1.0 - u), cos(pitch) * along);',
        '  float w = (0.3 * sin(3.14159 * min(u * 1.12, 1.0)) + 0.02) * aA.w;',
        '  p.x += position.x * w;',
        '  p.y -= abs(position.x) * w * 0.3;',
        '  float c = cos(aA.z), s = sin(aA.z);',
        '  p = vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);',
        '  vec3 wp = vec3(aA.x, -0.02, aA.y) + p;',
        '  vWorld = wp; vUv = vec2(position.x, u); vShade = aB.z;',
        '  gl_Position = projectionMatrix * viewMatrix * vec4(wp, 1.0);',
        '}',
      ].join('\n'),
      fragmentShader: [
        'varying vec2 vUv; varying vec3 vWorld; varying float vShade;',
        'void main() {',
        '  float x = abs(vUv.x);',
        '  float lob = fract(vUv.y * 15.0 + x * 1.3);',
        '  float leaflet = smoothstep(0.0, 0.14, lob) * smoothstep(1.0, 0.5, lob);',
        '  if (x > 0.06 && x > 0.96 * leaflet + 0.04) discard;',
        '  vec3 c = mix(vec3(0.020, 0.040, 0.038), vec3(0.050, 0.090, 0.075), vShade) * (0.6 + 0.5 * vUv.y);',
        // tips catch the moonlight from behind
        '  c += vec3(0.05, 0.09, 0.09) * smoothstep(0.55, 1.0, vUv.y) * smoothstep(0.3, 0.9, x);',
        '  c = applyFog(c, vWorld, 0.02);',
        '  gl_FragColor = vec4(ev_dither(c), 1.0);',
        '}',
      ].join('\n'),
    }));
    mesh.frustumCulled = false;
    return mesh;
  }

  E.register({
    id: 'foret-lucioles',
    decors: ['lucioles', 'brume', 'feuilles', 'pluie', 'etoiles'],
    defaults: { lucioles: 60, brume: 30 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var r = ctx.rng('scene');
      camera.fov = 52;
      camera.near = 0.1;
      camera.far = 1600;

      var glowDir = new THREE.Vector3(0.0, 0.1, -1).normalize();
      var shared = {
        uFogLow: { value: ctx.color('#24485a') },
        uFogHigh: { value: ctx.color('#0d1d33') },
        uGlow: { value: ctx.color('#8fc4cc') },
        uGlowDir: { value: glowDir },
        uMist: { value: 0 },
      };
      function sceneMat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.fragmentShader = SCENE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- sky
      var sky = new THREE.Mesh(new THREE.SphereGeometry(1400, 32, 16), sceneMat({
        side: THREE.BackSide,
        depthWrite: false,
        uniforms: { uZenith: { value: ctx.color('#050a1a') } },
        vertexShader: [
          'varying vec3 vDir;',
          'void main() { vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uZenith;',
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  vec3 c = mix(fogColor(d), uZenith, smoothstep(0.08, 0.75, d.y));',
          // high veils of cloud lit by the hidden moon
          '  vec2 p = d.xz / max(d.y + 0.2, 0.05) * 1.1;',
          '  float cl = ev_loopFbm(p + vec2(3.0, 1.0), vec2(0.015, 0.004), uTime);',
          '  float g = max(dot(d, uGlowDir), 0.0);',
          '  c += uGlow * 0.09 * smoothstep(0.48, 0.85, cl) * smoothstep(0.04, 0.3, d.y) * (0.35 + g);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- ground
      var groundGeo = new THREE.PlaneGeometry(200, 220, 60, 60);
      groundGeo.rotateX(-Math.PI / 2);
      groundGeo.translate(0, 0, -95);
      var gp = groundGeo.attributes.position;
      for (var i = 0; i < gp.count; i++) {
        var x = gp.getX(i), z = gp.getZ(i);
        gp.setY(i, 0.12 * Math.sin(x * 0.35 + z * 0.12) + 0.1 * Math.sin(z * 0.27 - x * 0.2) + Math.max(0, Math.abs(x) - 5) * 0.04);
      }
      groundGeo.computeVertexNormals();
      scene.add(new THREE.Mesh(groundGeo, sceneMat({
        vertexShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  float n = ev_fbm(vWorld.xz * vec2(0.5, 0.9));',
          '  vec3 c = mix(vec3(0.016, 0.030, 0.034), vec3(0.040, 0.066, 0.068), n);',
          // the clearing catches a little light along its length
          '  float path = exp(-pow(vWorld.x * 0.3 - sin(vWorld.z * 0.07) * 0.5, 2.0));',
          '  c += vec3(0.030, 0.050, 0.055) * path * smoothstep(8.0, -30.0, vWorld.z) * (0.6 + 0.8 * ev_noise(vWorld.xz * 2.5));',
          '  c = applyFog(c, vWorld, 0.022);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      })));

      // ---------------------------------------------------------------- rows of pines
      // [z, spacing, height min/max, width ratio, clearing half-width, detail, fog density]
      var rows = [
        [-150, 2.6, [10, 17], 0.17, 0, 0.6, 0.016],
        [-110, 2.8, [11, 18], 0.17, 3, 0.65, 0.016],
        [-78, 3.0, [12, 20], 0.18, 5, 0.7, 0.017],
        [-54, 3.2, [13, 22], 0.18, 6, 0.75, 0.018],
        [-36, 3.4, [15, 24], 0.18, 6.5, 0.8, 0.019],
        [-22, 3.6, [17, 27], 0.17, 6, 0.9, 0.02],
        [-11, 3.2, [22, 32], 0.15, 3.8, 1.0, 0.02],
      ];
      var S = window.EventideScenery;
      if (ctx.quality === 'low') rows = rows.slice(2);
      rows.forEach(function (row, idx) {
        var z = row[0];
        var dist = 9 - z;
        var hMax = row[2][1] * 1.05;
        var mesh = S.rowQuad(sceneMat({
          transparent: false,
          uniforms: {
            uSpacing: { value: row[1] }, uHeight: { value: new THREE.Vector2(row[2][0], row[2][1]) },
            uWidth: { value: row[3] }, uGap: { value: row[4] }, uSeed: { value: idx * 17.0 + 3.0 },
            uDetail: { value: row[5] }, uSway: { value: 0.006 }, uDensity2: { value: row[6] },
            uTree: { value: ctx.color('#050c10') }, uRim: { value: ctx.color('#8cc0c8') },
            uRowMist: { value: 1 - idx / (rows.length - 1) },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.TREELINE + '\n' + [
            'uniform float uDensity2; uniform vec3 uTree; uniform vec3 uRim; uniform float uRowMist;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float x = vLocal.x; float y = vLocal.y;',
            '  float d = ev_treeDist(x, y);',
            '  float aa = fwidth(x) * 0.9;',
            '  float cov = smoothstep(-aa, aa, d);',
            '  if (cov < 0.02) discard;',
            // back-lit rim: the side of each tree facing the glow (toward x = 0) is lighter
            '  float off = aa * 5.0 * sign(-x + 0.001);',
            '  float inner = d < aa * 8.0 ? smoothstep(-aa * 4.0, aa * 4.0, ev_treeDist(x + off, y + aa * 2.0)) : 1.0;',
            '  float rim = (1.0 - inner);',
            // inside the near crowns, a faint texture of branch layers
            '  float tex = 0.75 + 0.5 * ev_noise(vec2(x * 1.6, y * 4.0)) * (1.0 - uRowMist);',
            '  vec3 c = uTree * tex + uRim * rim * mix(0.16, 0.12, uRowMist);',
            // mist pooled between the rows, thicker near the ground
            '  float mist = exp(-max(y, 0.0) * 0.22) * (0.25 + 0.75 * uRowMist);',
            '  c = applyFog(c, vWorld, uDensity2);',
            '  c = mix(c, fogColor(normalize(vWorld - cameraPosition)), clamp(mist * (0.35 + 0.5 * uMist), 0.0, 1.0));',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), z, dist * 0.36 + 6, hMax + 0.5);
        mesh.material.alphaToCoverage = true;
        mesh.renderOrder = -idx;
        scene.add(mesh);
      });

      scene.add(ferns(ctx, sceneMat, r, 300));

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var decors = {
        lucioles: D.lucioles(ctx, {
          count: 210, box: { min: [-6.5, 0.2, -16], max: [6.5, 3.2, 6.5] }, size: 0.17, color: '#e6f49c', lowBias: 1.4,
        }),
        brume: D.brume(ctx, {
          color: '#6b98a4',
          layers: [
            { y: 1.4, z: -64, width: 120, height: 9, opacity: 0.55, scale: 0.1, drift: 0.05, rank: 0.0 },
            { y: 0.9, z: -30, width: 70, height: 5, opacity: 0.45, scale: 0.16, drift: -0.04, rank: 0.15 },
            { y: 0.5, z: -14, width: 40, height: 3.0, opacity: 0.32, scale: 0.24, drift: 0.035, rank: 0.35, color: '#5a8591' },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
        feuilles: D.feuilles(ctx, {
          count: 45, box: { min: [-4.5, -0.2, -5], max: [4.5, 6.5, 5.5] }, size: [0.09, 0.14],
          colors: ['#5a3c1e', '#8a5e2c', '#a8834c'], lightDir: [0, 0.3, -1], light: '#b9dfe4', ambient: '#2a3438',
          fog: '#24485a', fogDensity: 0.03,
        }),
        pluie: D.pluie(ctx, {
          count: 1100, box: { min: [-8, -0.5, -16], max: [8, 9, 7] }, speed: [7, 9.5],
          color: '#a9c6cf', opacity: 0.3, wind: [0.06, 0.0],
        }),
        etoiles: D.etoiles(ctx, {
          count: 900, azimuth: [0, 36], elevation: [12, 75], size: 0.95, tint: ['#cfe0ff', '#f6efe0'],
        }),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      // ---------------------------------------------------------------- camera path (loops)
      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.35 * Math.sin(T), 1.25 + 0.05 * Math.sin(2 * T), 9 + 0.25 * Math.cos(T));
        camera.lookAt(0.5 * Math.sin(T + 0.5), 3.2, -20);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
