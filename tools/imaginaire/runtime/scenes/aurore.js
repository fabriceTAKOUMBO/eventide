/*
 * « Aurore boréale », version 2: an arctic night by a still lake, drawn with the HDR finish of
 * post.js (as the forest v2) and the nature kit of scenery.js.
 *
 *   - The aurora: three curtains, physically inspired: thin vertical sheets folding slowly along
 *     their length (static folds, folds that breathe once a period, a slow travelling ripple),
 *     a sharp ragged lower edge, green emission (557.7 nm) falling with height and faint red and
 *     violet tops (630 nm), vertical rays drifting slowly along the curtain, folds seen edge-on
 *     brighter (a longer path through the sheet), extinction near the horizon. HDR emission: the
 *     bloom of the finish makes their glow. Calm: no flicker, no sudden surge.
 *   - The aurora is also the light: a dim green key light from its direction (shadow map over the
 *     spruces of the left shore, which the mist samples), breathing with the curtains, and a
 *     green-tinted sky light; snowy mountains (polar height field, visibility of that light and
 *     occlusion baked per vertex), rock on the steep faces.
 *   - A still lake mirrors the mountains and the far curtain through a saddle of the ridge (planar
 *     reflection in HDR, faint ripples); a snowy bank with boulders in front keeps the lower third
 *     dark; snow-laden spruces near the left shore and on the far shores.
 *   - The camera drifts on a small closed path: parallax between bank, spruces, shores, ranges.
 * Everything that moves is a function of the scene time t (modulo 30 s): the period loops.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;
  var TAU = Math.PI * 2;
  var DEG = Math.PI / 180;

  function smax(a, b, k) {
    var h = Math.max(k - Math.abs(a - b), 0) / k;
    return Math.max(a, b) + h * h * k * 0.25;
  }
  function segDist(x, z, x0, z0, x1, z1) {
    var dx = x1 - x0, dz = z1 - z0;
    var t = Math.max(0, Math.min(1, ((x - x0) * dx + (z - z0) * dz) / (dx * dx + dz * dz)));
    return Math.hypot(x - x0 - dx * t, z - z0 - dz * t);
  }

  // One curtain of aurora: a ribbon (u along, v up) whose ground track folds slowly.
  var CURTAIN_VERTEX = [
    'uniform vec4 uTrack;',   // ground track from (x, z) to (x, z) (m): the curtain runs obliquely, receding
    'uniform vec4 uShape;',   // height (m); lateral folds (m): static, breathing, travelling ripple
    'uniform vec4 uFreq;',    // waves along the curtain: static, breathing, ripple; seed
    'uniform float uBase;',   // altitude of the lower edge (m)
    'varying vec2 vUv; varying float vEdgeOn; varying vec3 vWorld; varying float vS;',
    'vec3 curtainPoint(float u, float T) {',
    '  vec2 a = uTrack.xy, b = uTrack.zw;',
    '  vec2 dir = normalize(b - a);',
    '  vec2 side = vec2(-dir.y, dir.x);',
    '  float d = uShape.y * sin(EV_TAU * (uFreq.x * u + uFreq.w))',
    '    + uShape.z * sin(EV_TAU * (uFreq.y * u + uFreq.w * 1.7)) * sin(EV_TAU * (T + uFreq.w))',
    '    + uShape.w * sin(EV_TAU * (uFreq.z * u - T + uFreq.w * 2.3));',
    '  vec2 p = mix(a, b, u) + side * d;',
    '  return vec3(p.x, 0.0, p.y);',
    '}',
    'void main() {',
    '  float T = uTime / EV_PERIOD;',
    '  float u = position.x;',
    '  vec3 p = curtainPoint(u, T);',
    '  vec3 tang = normalize(curtainPoint(u + 0.002, T) - curtainPoint(u - 0.002, T));',
    '  vec3 nrm = vec3(-tang.z, 0.0, tang.x);',
    '  float base = uBase + 380.0 * sin(EV_TAU * (1.3 * u + uFreq.w * 3.1)) + 120.0 * sin(EV_TAU * (4.7 * u - T + uFreq.w));',
    '  float top = base + uShape.x * (0.8 + 0.2 * sin(EV_TAU * (2.1 * u + uFreq.w)));',
    '  vec3 wp = vec3(p.x, mix(base, top, position.y), p.z);',
    '  vec3 vdir = normalize(wp - cameraPosition);',
    // the path through a thin sheet grows as it is seen edge-on: the folds light up
    '  vEdgeOn = 0.3 / (abs(dot(nrm, vdir)) + 0.3);',
    '  vUv = vec2(u, position.y);',
    '  vS = u * length(uTrack.zw - uTrack.xy);',
    '  vWorld = wp;',
    '  gl_Position = projectionMatrix * viewMatrix * vec4(wp, 1.0);',
    '}',
  ].join('\n');

  var CURTAIN_FRAGMENT = [
    'uniform vec4 uFreq; uniform sampler2D uNoiseTex; uniform vec3 uGreen; uniform vec3 uTop;',
    'uniform float uGain; uniform float uGlobal; uniform float uRayScale;',
    'varying vec2 vUv; varying float vEdgeOn; varying vec3 vWorld; varying float vS;',
    // noise drifting slowly and looping (two copies half a period apart, sin^2 weights)
    'float loopTex(vec2 p, float drift) {',
    '  float tau = uTime / EV_PERIOD;',
    '  float s = sin(3.14159265 * tau); vec2 w = vec2(s * s, 1.0 - s * s);',
    '  float a = texture2D(uNoiseTex, p + vec2(drift * (fract(tau) - 0.5), 0.0)).b;',
    '  float b = texture2D(uNoiseTex, p + vec2(drift * (fract(tau + 0.5) - 0.5), 0.0) + vec2(0.37, 0.21)).b;',
    '  float v = w.x * (a - 0.5) + w.y * (b - 0.5);',
    '  return clamp(0.5 + v / sqrt(w.x * w.x + w.y * w.y), 0.0, 1.0);',
    '}',
    'void main() {',
    '  float u = vUv.x, v = vUv.y;',
    '  float T = uTime / EV_PERIOD;',
    '  float s = vS / uRayScale;',
    // rays: fine vertical striations sliding slowly along the curtain, over a static coarser set
    '  float r1 = loopTex(vec2(s, 0.31 + uFreq.w), 0.05);',
    '  float r2 = texture2D(uNoiseTex, vec2(s * 0.41 + 0.5, 0.71 + uFreq.w)).g;',
    '  float rays = smoothstep(0.38, 0.86, r1 * 0.62 + r2 * 0.5);',
    '  rays = 0.12 + 1.3 * rays * rays;',
    // a sharp, slightly ragged lower edge; green falling with height; faint red-violet tops
    '  float jag = (texture2D(uNoiseTex, vec2(s * 1.7, 0.13 + uFreq.w)).b - 0.5) * 0.035 + (1.3 - rays) * 0.018;',
    '  float h = v - jag;',
    '  float edge = smoothstep(-0.004, 0.03, h);',
    '  float green = edge * (exp(-max(h, 0.0) * 3.4) + 0.12 * exp(-max(h, 0.0) * 1.1));',
    '  float red = smoothstep(0.28, 0.72, v) * (1.0 - smoothstep(0.82, 1.0, v));',
    // brightness: patches along the curtain, a slow surge travelling along it, the ends
    '  float patchy = 0.4 + 0.8 * smoothstep(0.2, 0.78, texture2D(uNoiseTex, vec2(u * 1.6 + uFreq.w, 0.5 + uFreq.w)).r);',
    '  float surge = 0.72 + 0.28 * sin(EV_TAU * (1.15 * u - T + uFreq.w * 5.0));',
    '  float ends = smoothstep(0.0, 0.12, u) * smoothstep(1.0, 0.86, u);',
    '  float I = rays * patchy * surge * ends * uGain * uGlobal * (0.15 + 2.2 * vEdgeOn * vEdgeOn);',
    // a real curtain is about a kilometre thick: a fold seen exactly edge-on is a band, not a
    // one-pixel line (cap how much of the sheet piles up in one pixel against its face-on footprint)
    '  float faceOn = length(vWorld - cameraPosition) / uFocal;',
    '  I *= min(1.0, 5.0 * faceOn / max(fwidth(vS), 1e-3));',
    '  vec3 col = (uGreen * green + uTop * red * (0.6 + 0.4 * rays)) * I * (1.0 - smoothstep(0.8, 1.0, v));',
    // extinction through the air near the horizon
    '  vec3 dir = normalize(vWorld - cameraPosition);',
    '  col *= exp(-0.05 / max(dir.y + 0.015, 0.01));',
    '  gl_FragColor = vec4(col, 1.0);',
    '}',
  ].join('\n');

  E.register({
    id: 'aurore',
    decors: ['neige', 'etoiles', 'etoiles-filantes', 'brume'],
    defaults: { etoiles: 50, neige: 30 },
    post: true,

    build: function (ctx) {
      var N = window.EventideScenery.nature;
      var lin = N.lin;
      var scene = ctx.scene, camera = ctx.camera, renderer = ctx.renderer;
      var quality = ctx.quality, high = quality === 'high';
      camera.fov = 50;
      camera.near = 0.5;
      camera.far = 60000;
      var CAM_Y = 2.2;

      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFShadowMap;
      renderer.shadowMap.autoUpdate = false;

      // the light of the aurora comes from the north, high
      var lightAz = 0 * DEG, lightEl = 58 * DEG;
      var lightDir = new THREE.Vector3(Math.sin(lightAz) * Math.cos(lightEl), Math.sin(lightEl), -Math.cos(lightAz) * Math.cos(lightEl));
      var noiseTex = N.noiseTexture(ctx.rng('noise'));
      var rippleTex = N.rippleTexture(ctx.rng('ripple'));
      var atlasTex = N.silhouetteTexture(ctx.rng('atlas'), true, 1);
      var atlasNear = N.silhouetteTexture(ctx.rng('atlas3'), true, 3);
      var textures = [noiseTex, rippleTex, atlasTex, atlasNear];

      var shadowPlaceholder = new THREE.DepthTexture(1, 1);
      shadowPlaceholder.compareFunction = THREE.LessEqualCompare;
      shadowPlaceholder.needsUpdate = true;
      textures.push(shadowPlaceholder);
      var shared = {
        uTime: ctx.uniforms.uTime,
        uLightDir: { value: lightDir },
        uLightFog: { value: new THREE.Vector3(0.0035, 0.011, 0.0085) },
        uFogAmb: { value: new THREE.Vector3(0.0016, 0.0032, 0.0062) },
        uFog: { value: new THREE.Vector4(0.00006, 0.00022, 1 / 160, 0) },
        uMist: { value: new THREE.Vector4(0.0, 2.2, 0.0007, 1 / 120) },
        uAirExt: { value: new THREE.Vector4(1 / 1800, 0.7 / 120, -0.25 / 120, 60000) },
        uNoiseTex: { value: noiseTex },
        uShadowMap: { value: shadowPlaceholder },
        uShadowMatrix: { value: new THREE.Matrix4() },
        uShadowReady: { value: 0 },
      };
      var fogBase = { haze: shared.uFog.value.x, ground: shared.uFog.value.y };
      var K = N.pbrFactory(shared, quality);
      var pbr = K.pbr;

      var post = ctx.post({
        exposure: 1.0,
        toneMapping: 'aces',
        bloom: { strength: 0.3, threshold: 0.8, knee: 0.6, radius: 1.0 },
        aberration: 0.004,
        vignette: 0.4,
        grain: ctx.record ? 0 : 0.026,
      });

      // ---------------------------------------------------------------- lights
      var keyColor = lin('#a9ecd6');
      var keyBase = 0.46;
      var key = new THREE.DirectionalLight(keyColor, keyBase);
      var target = new THREE.Vector3(-70, 0, -150);
      key.target.position.copy(target);
      key.position.copy(target).addScaledVector(lightDir, 600);
      key.castShadow = true;
      var shadowSize = high ? 1024 : 512;
      key.shadow.mapSize.set(shadowSize, shadowSize);
      var sc = key.shadow.camera;
      sc.left = -140; sc.right = 140; sc.top = 140; sc.bottom = -140; sc.near = 200; sc.far = 1100;
      sc.updateProjectionMatrix();
      key.shadow.bias = -0.0005;
      key.shadow.normalBias = 0.12;
      key.shadow.radius = 2.5;
      scene.add(key);
      scene.add(key.target);
      var skyLight = lin('#2b4d5c'), groundLight = lin('#0b1016'), hemiBase = 0.8;
      var hemi = new THREE.HemisphereLight(skyLight, groundLight, hemiBase);
      scene.add(hemi);
      var keyV = new THREE.Vector3(keyColor.r, keyColor.g, keyColor.b).multiplyScalar(keyBase);
      var keyV0 = keyV.clone();
      var skyV = new THREE.Vector3(skyLight.r, skyLight.g, skyLight.b).multiplyScalar(hemiBase / Math.PI);
      var skyV0 = skyV.clone();

      // ---------------------------------------------------------------- terrain
      var nA = N.gradientNoise(ctx.rng('hA')), nB = N.gradientNoise(ctx.rng('hB')), nC = N.gradientNoise(ctx.rng('hC'));
      function shoreR(th) {
        return 720 + 130 * nA(th * 2.1, 0.3) + 40 * nA(th * 7.0, 2.5);
      }
      function height(x, z) {
        var r = Math.hypot(x, z), th = Math.atan2(x, -z);
        // low hills on the far shore, snowy forest
        var dA = 1250 + 200 * nA(th * 2.4, 6.1), uA = (r - dA) / 400;
        var hA = 150 * (0.5 + 0.6 * N.fbm(nA, th * 3.3, 1.1, 3)) * Math.exp(-uA * uA * 1.3);
        hA *= 0.8 + 0.4 * N.fbm(nA, x / 230, z / 230, 4);
        // the massif, right of centre, and its range
        var dB = 3700 + 500 * nB(th * 1.6, 2.2), uB = (r - dB) / 1100;
        var massif = 0.55 + 0.75 * Math.exp(-Math.pow((th - 0.12) / 0.2, 2));
        var hB = 900 * massif * (0.6 + 0.5 * N.fbm(nB, th * 2.4, 3.3, 3)) * Math.exp(-uB * uB * 1.15);
        hB *= 0.45 + 1.0 * N.ridged(nB, x / 620, z / 620, 5);
        // a far range with a low saddle left of centre (the far curtain shows through it)
        var dC = 9000 + 1500 * nC(th * 1.2, 1.7), uC = (r - dC) / 2600;
        var saddle = 1.0 - 0.75 * Math.exp(-Math.pow((th + 0.07) / 0.09, 2));
        var hC = 1700 * saddle * (0.5 + 0.6 * N.fbm(nC, th * 2.0, 5.1, 3)) * Math.exp(-uC * uC);
        hC *= 0.45 + 1.0 * N.ridged(nC, x / 1000, z / 1000, 5);
        var land = smax(smax(hA, hB * (1.0 - 0.6 * Math.exp(-Math.pow((th + 0.07) / 0.1, 2))), 60), hC, 120);
        var sr = shoreR(th);
        var rise = Math.max(0, Math.min(1, (r - sr) / 260));
        var h = land * rise * rise * (3 - 2 * rise) + Math.max(-25, Math.min(30, (r - sr) * 0.08));
        // the snowy bank in front of the camera, with drifts
        var edge = z + 14.5 + 1.6 * nA(x * 0.12, 0.7) + 0.8 * nA(x * 0.4, 1.9);
        var bank = Math.max(-1.2, Math.min(0.45, edge * 0.32)) + 0.22 * N.fbm(nB, x / 5, z / 5, 3) * Math.min(1, Math.max(0, edge));
        // the left shore: a low wooded point
        var spit = 5.0 * Math.exp(-Math.pow(segDist(x, z, -24, -75, -170, -300) / 22, 2)) * (0.8 + 0.4 * N.fbm(nA, x / 35, z / 35, 3)) - 1.4;
        return Math.max(h, bank, spit);
      }
      var far = N.polarTerrain({
        th0: -64 * DEG, th1: 64 * DEG, nTheta: high ? 520 : 380, r0: 520, r1: 24000, nR: high ? 210 : 150, chunks: 10,
        height: height, light: lightDir, bakeSteps: 22, bakeDistance: 7000,
      });
      var near = N.polarTerrain({
        th0: -80 * DEG, th1: 80 * DEG, nTheta: 220, r0: 2, r1: 580, nR: 110, chunks: 8,
        height: height, light: lightDir, bakeSteps: 14, bakeDistance: 500, aoRadius: function (r) { return Math.max(1.2, r * 0.05); },
        fallback: far.sample,
      });
      function groundAt(x, z) {
        return Math.hypot(x, z) < 550 ? near.sample(x, z) : far.sample(x, z);
      }

      var terrainMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.9, metalness: 0 }, {
        key: 'terrain',
        drySpecular: 0.05,
        vertexPars: 'attribute vec2 aBake; varying vec2 vBake;',
        vertex: 'vBake = aBake;',
        fragmentPars: 'varying vec2 vBake;',
        color: [
          'vec3 naP = vNaWorld;',
          'float naSlope = 1.0 - clamp(vNaNormal.y, 0.0, 1.0);',
          'float naN1 = texture2D(uNoiseTex, naP.xz * 0.0019).r;',
          'float naN2 = texture2D(uNoiseTex, naP.xz * 0.0105).g;',
          'float naN3 = texture2D(uNoiseTex, naP.xz * 0.047 + vec2(0.0, naP.y * 0.021)).b;',
          'float naCell = texture2D(uNoiseTex, naP.xz * 0.04).a;',
          'float naFine = texture2D(uNoiseTex, naP.xz * 0.7).b;',
          // snow everywhere it can hold; dark rock on the steep faces and in the gullies; the
          // snowy forest of the far shore and the hills (dark crowns, snow between them)
          'float naRock = smoothstep(0.42, 0.66, naSlope + 0.3 * (naN3 - 0.5) + 0.15 * (naN2 - 0.5));',
          'float naForest = smoothstep(330.0, 260.0, naP.y + 120.0 * (naN1 - 0.5)) * smoothstep(0.7, 0.45, naSlope) * step(700.0, length(naP.xz));',
          'vec3 naAlb = vec3(0.78, 0.82, 0.88) * (0.88 + 0.16 * naN2 + 0.06 * naFine);',
          // the near shore: wind-scoured tundra and stones, snow lying in the hollows
          'float naNear = 1.0 - smoothstep(30.0, 80.0, length(naP.xz - cameraPosition.xz));',
          'float naG1 = texture2D(uNoiseTex, naP.xz * 0.6).r, naG2 = texture2D(uNoiseTex, naP.xz * 2.3).g;',
          'float naPatch = smoothstep(0.26, 0.4, naG1 * 0.45 + naG2 * 0.45 + (1.0 - vBake.y) * 2.0 + 0.06);',
          'vec3 naTundra = mix(vec3(0.016, 0.014, 0.012), vec3(0.04, 0.036, 0.03), naFine) * (0.7 + 0.6 * naG2);',
          // wind-packed snow, a few low stones and tussocks breaking through
          'naAlb = mix(naAlb, mix(naTundra, naAlb * 0.46, 0.35 + 0.65 * naPatch), naNear);',
          'naAlb = mix(naAlb, vec3(0.022, 0.023, 0.026) * (0.7 + 0.6 * naN3), naRock);',
          'naAlb = mix(naAlb, naAlb * (0.12 + 0.5 * smoothstep(0.15, 0.55, naCell)), naForest * 0.85);',
          'diffuseColor.rgb = naAlb;',
          'float naH = naRock * naN3 + (1.0 - naRock) * (naN2 * 0.6 + naFine * 0.4) + naNear * (1.0 - naPatch) * naG2;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.82, 0.95, naRock);',
        normal: 'normal = na_bump(normal, -vViewPosition, naH, 0.05 * smoothstep(12000.0, 200.0, length(vViewPosition)) + 0.003);',
        lightEnd: [
          'reflectedLight.directDiffuse *= vBake.x;',
          'reflectedLight.directSpecular *= vBake.x;',
          'reflectedLight.indirectDiffuse *= vBake.y;',
        ].join('\n'),
      });
      var chunkMeshes = [];
      [far, near].forEach(function (grid, gi) {
        grid.chunks.forEach(function (g) {
          var m = new THREE.Mesh(g, terrainMat);
          m.receiveShadow = gi === 1;
          m.frustumCulled = false;
          m.userData.th = g.userData.th;
          chunkMeshes.push(m);
          scene.add(m);
        });
      });
      var fwd = new THREE.Vector3();
      function cullChunks() {
        camera.getWorldDirection(fwd);
        var yaw = Math.atan2(fwd.x, -fwd.z);
        var half = Math.atan(Math.tan(camera.fov * DEG / 2) * camera.aspect) + 3 * DEG;
        chunkMeshes.forEach(function (m) {
          m.visible = m.userData.th[1] > yaw - half && m.userData.th[0] < yaw + half;
        });
      }

      // ---------------------------------------------------------------- snow-laden spruces
      var treeRng = ctx.rng('trees');
      var nearTrees = [], boards = [];
      for (var at = 0; at < 6000 && nearTrees.length < (high ? 46 : 30); at++) {
        var f = Math.pow(treeRng(), 1.5);
        var sx = -24 + (-170 + 24) * f + (treeRng() - 0.5) * 40, sz = -75 + (-300 + 75) * f + (treeRng() - 0.5) * 40;
        var gy = groundAt(sx, sz);
        if (gy < 0.9 || Math.atan2(sx, -sz) > -6 * DEG) continue;
        var ok = true;
        for (var j = 0; j < nearTrees.length; j++) {
          if (Math.hypot(nearTrees[j].x - sx, nearTrees[j].z - sz) < 4.5) { ok = false; break; }
        }
        if (!ok) continue;
        nearTrees.push({ x: sx, y: gy - 0.3, z: sz, h: 8 + 14 * Math.pow(treeRng(), 0.8), cell: Math.floor(treeRng() * 4), wr: 0.34 + treeRng() * 0.1, tint: treeRng(), snow: treeRng() });
      }
      var want = high ? 8000 : 4000;
      for (var at2 = 0; at2 < want * 12 && boards.length < want; at2++) {
        var th = (treeRng() * 2 - 1) * 62 * DEG;
        var r = 300 * Math.pow(2600 / 300, treeRng());
        var bx = r * Math.sin(th), bz = -r * Math.cos(th);
        var by = groundAt(bx, bz);
        if (by < 0.8 || by > 300 + 80 * nA(bx / 300, bz / 300)) continue;
        if (1 - (Math.hypot(bx, bz) < 550 ? near : far).normalAt(bx, bz).y > 0.5) continue;
        var grove = 0.5 + 0.5 * N.fbm(nB, bx / 160, bz / 160, 3);
        var dens = by < 50 ? 0.9 : Math.min(1, Math.max(0.06, grove * 1.5 - 0.25));
        if (treeRng() > dens) continue;
        boards.push({ x: bx, y: by - 0.6, z: bz, h: (by < 50 ? 10 : 7) + Math.pow(treeRng(), 0.7) * 13 * (0.7 + 0.6 * grove), cell: Math.floor(treeRng() * 4), wr: 0.3 + treeRng() * 0.12, tint: treeRng(), snow: treeRng() });
      }
      var treeAlbedo = new THREE.Vector3(0.012, 0.02, 0.016);
      var snowAlbedo = new THREE.Vector3(0.66, 0.72, 0.78);
      var billboards = N.billboardConifers(ctx, shared, boards, {
        atlas: atlasTex, key: keyV, sky: skyV, albedo: treeAlbedo, snowAlbedo: snowAlbedo, snow: 1.0, back: 0.3,
      });
      scene.add(billboards);
      var nearBoards = N.billboardConifers(ctx, shared, nearTrees, {
        atlas: atlasNear, key: keyV, sky: skyV, albedo: treeAlbedo, snowAlbedo: snowAlbedo, snow: 1.0, back: 0.3, castShadow: true,
      });
      scene.add(nearBoards);

      // ---------------------------------------------------------------- boulders in the snow
      var rockGeo = N.rockGeometry(ctx.rng('rock'));
      var rockMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.85, metalness: 0 }, {
        key: 'rock',
        drySpecular: 0.05,
        color: [
          'float naR1 = texture2D(uNoiseTex, vNaWorld.xz * 0.9 + vNaWorld.y * 0.6).g;',
          'float naR2 = texture2D(uNoiseTex, vNaWorld.xy * 1.7).b;',
          'vec3 naRk = mix(vec3(0.016, 0.017, 0.019), vec3(0.04, 0.04, 0.042), naR1 * 0.7 + naR2 * 0.3);',
          // a cap of snow on what faces the sky
          'float naCap = smoothstep(0.45, 0.75, vNaNormal.y + 0.25 * (naR2 - 0.5));',
          'diffuseColor.rgb = mix(naRk, vec3(0.7, 0.75, 0.8), naCap);',
        ].join('\n'),
        normal: 'normal = na_bump(normal, -vViewPosition, naR1 * 0.6 + naR2 * 0.4, 0.01);',
      });
      [[-2.3, 0.05, -10.5, 0.75, 0.4], [2.9, 0.0, -12.8, 1.05, 2.1], [-4.6, 0.1, -15.5, 1.2, 4.0], [1.2, -0.15, -18.5, 0.55, 1.3]].forEach(function (b) {
        var m = new THREE.Mesh(rockGeo, rockMat);
        m.position.set(b[0], groundAt(b[0], b[2]) + b[1], b[2]);
        m.scale.set(b[3], b[3] * 0.75, b[3] * 1.1);
        m.rotation.y = b[4];
        scene.add(m);
      });

      // ---------------------------------------------------------------- sky
      var skyMat = ctx.material({
        uniforms: Object.assign({}, shared, {
          uZenith: { value: lin('#010309') },
          uHorizon: { value: lin('#0d1a28').multiplyScalar(0.6) },
          uAirglow: { value: lin('#3fd59a').multiplyScalar(0.012) },
          uGlow: { value: lin('#3cf2a0').multiplyScalar(0.006) },
          uGlobal: { value: 1 },
        }),
        vertexShader: 'varying vec3 vDir;\nvoid main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + N.AIR_GLSL + '\n' + [
          'uniform vec3 uZenith; uniform vec3 uHorizon; uniform vec3 uAirglow; uniform vec3 uGlow; uniform float uGlobal;',
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  vec3 col = mix(uHorizon, uZenith, smoothstep(-0.05, 0.55, d.y));',
          // airglow: a faint green band a few degrees above the horizon
          '  col += uAirglow * exp(-abs(d.y - 0.07) * 14.0);',
          // the diffuse glow of the aurora around its curtains (north, up to mid-sky)
          '  float north = smoothstep(0.1, -0.85, d.z) * smoothstep(-0.02, 0.15, d.y) * (1.0 - smoothstep(0.35, 0.95, d.y));',
          '  float var1 = texture2D(uNoiseTex, vec2(atan(d.x, -d.z) * 0.35, d.y * 0.8) + 0.2).r;',
          '  col += uGlow * north * (0.5 + var1) * uGlobal;',
          '  col = na_skyAir(col, d);',
          '  gl_FragColor = vec4(col, 1.0);',
          '}',
        ].join('\n'),
        side: THREE.BackSide,
        depthWrite: false,
      });
      var sky = new THREE.Mesh(new THREE.SphereGeometry(50000, 48, 24), skyMat);
      sky.renderOrder = 10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- the aurora
      var auroraGlobal = { value: 1 };
      var green = lin('#46ff9c');
      // [ground track from x, z to x, z (m)], lower edge (m), [height, folds: static, breathing,
      // travelling (m)], [waves along it, seed]
      var curtains = [
        // near: high, its lower edge across the upper left corner
        { track: [-9000, -2000, 12000, -8500], base: 3400, shape: [5200, 900, 450, 160], freq: [1.7, 3.1, 7.0, 0.13], gain: 0.4, rays: 5200, red: 1.0 },
        // main: across the sky above the massif, receding slightly to the right
        { track: [-9000, -10000, 14000, -17000], base: 3150, shape: [11000, 1300, 650, 250], freq: [2.4, 3.9, 8.0, 0.57], gain: 0.85, rays: 7000, red: 0.8 },
        // far: low, behind the ranges; seen through the saddle and in the lake
        { track: [-14000, -30000, 16000, -36000], base: 2500, shape: [8000, 1800, 800, 300], freq: [1.6, 2.8, 6.0, 0.83], gain: 0.6, rays: 9000, red: 0.15 },
      ];
      var curtainMeshes = curtains.map(function (o, i) {
        var seg = 320, pos = [], idx = [];
        for (var k = 0; k <= seg; k++) {
          pos.push(k / seg, 0, 0, k / seg, 1, 0);
          if (k < seg) idx.push(k * 2, k * 2 + 1, k * 2 + 2, k * 2 + 1, k * 2 + 3, k * 2 + 2);
        }
        var g = new THREE.BufferGeometry();
        g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
        g.setIndex(idx);
        var m = ctx.material({
          uniforms: {
            uTrack: { value: new THREE.Vector4(o.track[0], o.track[1], o.track[2], o.track[3]) },
            uBase: { value: o.base },
            uShape: { value: new THREE.Vector4(o.shape[0], o.shape[1], o.shape[2], o.shape[3]) },
            uFreq: { value: new THREE.Vector4(o.freq[0], o.freq[1], o.freq[2], o.freq[3]) },
            uNoiseTex: { value: noiseTex },
            uGreen: { value: green },
            uTop: { value: new THREE.Vector3(0.5, 0.04, 0.3).multiplyScalar(o.red) },
            uGain: { value: o.gain },
            uGlobal: auroraGlobal,
            uRayScale: { value: o.rays },
          },
          vertexShader: CURTAIN_VERTEX,
          fragmentShader: CURTAIN_FRAGMENT,
          transparent: true,
          depthWrite: false,
          blending: THREE.AdditiveBlending,
          side: THREE.DoubleSide,
        });
        var mesh = new THREE.Mesh(g, m);
        mesh.frustumCulled = false;
        mesh.renderOrder = 12 + i;
        scene.add(mesh);
        return mesh;
      });

      // ---------------------------------------------------------------- the lake
      var lake = ctx.mirror({
        y: 0,
        size: [12000, 6000],
        center: [0, -2900],
        scale: high ? 0.4 : 0.3,
        type: post.floatTargets ? THREE.HalfFloatType : undefined,
        uniforms: Object.assign({}, shared, {
          uRipple: { value: rippleTex },
          uDeep: { value: new THREE.Vector3(0.0008, 0.0016, 0.0024) },
          uGlint: { value: new THREE.Vector3() },
          uWave: { value: new THREE.Vector4(0.07, 0.16, 120, 0.012) },
          uTiles: { value: new THREE.Vector4(14, 5.2, 1.9, 1.0) },
          uQuiet: { value: 1 },
        }),
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + N.AIR_GLSL + '\n' + N.WATER_GLSL,
      });
      scene.add(lake);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function levelOnly(object, extra) {
        object.visible = false;
        return { object: object, setLevel: function (v) { if (extra) extra(v); } };
      }
      var stars = D.etoiles(ctx, {
        count: high ? 1400 : 900, radius: 45000, azimuth: [0, 46], elevation: [3, 85], size: 1.0, brightness: 3.2,
        band: { normal: [-0.6, 0.3, 0.7], width: 0.15, count: high ? 1600 : 1000 },
        tint: ['#cfdcff', '#fff1df'],
      });
      stars.object.renderOrder = 11;
      stars.object.layers.set(1);
      // in the visible sky (the top of the view is about 29 degrees up)
      var meteors = D['etoiles-filantes'](ctx, { radius: 44000, azimuth: [0, 13], elevation: [17, 27] });
      meteors.object.material.uniforms.uColor.value.multiplyScalar(4);
      meteors.object.renderOrder = 16;
      meteors.object.layers.set(1);
      var snow = D.neige(ctx, {
        count: high ? 1700 : 1000, box: { min: [-7, -0.2, -24], max: [7, 10, 1] }, size: [0.02, 0.05], color: '#71837e', opacity: 0.85,
      });
      snow.object.layers.set(1);
      var mistLevel = 0;
      function applyMist(v) {
        mistLevel = v;
        var low = high ? 1 : 0.8;
        shared.uFog.value.x = fogBase.haze * (1 + 0.15 * v) * low;
        shared.uFog.value.y = fogBase.ground * (1 + 0.8 * v) * low;
        shared.uFog.value.w = v * low;
      }
      applyMist(0);
      var decors = {
        neige: snow,
        etoiles: stars,
        'etoiles-filantes': meteors,
        brume: levelOnly(new THREE.Group(), applyMist),
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      // ---------------------------------------------------------------- time
      var lookY = CAM_Y + Math.tan(4 * DEG) * 400;
      function update(t) {
        var T = t / ctx.PERIOD * TAU;
        camera.position.set(0.35 * Math.sin(T), CAM_Y + 0.05 * Math.sin(2 * T + 0.4), 0.3 * Math.cos(T));
        camera.lookAt(1.6 * Math.sin(T + 0.6), lookY + 1.2 * Math.sin(T), -400);
        // the aurora breathes slowly (one cycle a period, and a softer second harmonic); the
        // landscape it lights follows
        var g = 0.88 + 0.09 * Math.sin(T + 0.6) + 0.04 * Math.sin(2 * T + 2.1);
        auroraGlobal.value = g;
        skyMat.uniforms.uGlobal.value = g;
        key.intensity = keyBase * g;
        hemi.intensity = hemiBase * (0.85 + 0.15 * g);
        keyV.copy(keyV0).multiplyScalar(g);
        skyV.copy(skyV0).multiplyScalar(0.85 + 0.15 * g);
      }
      update(0);

      function primeShadows() {
        renderer.shadowMap.needsUpdate = true;
        var rt = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType });
        renderer.setRenderTarget(rt);
        chunkMeshes.forEach(function (m) { m.visible = true; });
        renderer.render(scene, camera);
        renderer.setRenderTarget(null);
        rt.dispose();
        var ready = !!(key.shadow.map && key.shadow.map.depthTexture);
        shared.uShadowMap.value = ready ? key.shadow.map.depthTexture : shadowPlaceholder;
        shared.uShadowMatrix.value = key.shadow.matrix;
        shared.uShadowReady.value = ready ? 1 : 0;
      }
      primeShadows();

      return {
        decors: decors,
        update: update,
        render: function () {
          camera.updateMatrixWorld();
          cullChunks();
          post.render(scene, camera);
        },
        setQuality: function (q) {
          quality = q;
          post.setQuality(q);
          K.setQuality(q);
          N.setLowAir([skyMat, lake.material, billboards.material, nearBoards.material], q === 'low');
          // fewer far spruces in 'low' (they were drawn in random order: a uniform thinning)
          billboards.geometry.instanceCount = Math.round(boards.length * (q === 'low' ? 0.6 : 1));
          billboards.material.alphaToCoverage = q === 'high';
          nearBoards.material.alphaToCoverage = q === 'high';
          var size = q === 'high' ? 1024 : 512;
          key.shadow.mapSize.set(size, size);
          if (key.shadow.map) {
            key.shadow.map.dispose();
            key.shadow.map = null;
          }
          shared.uShadowMap.value = shadowPlaceholder;
          primeShadows();
          applyMist(mistLevel);
        },
        describe: function () {
          var d = post.describe();
          d.shadowMap = key.shadow.mapSize.x;
          d.trees = { near: nearTrees.length, silhouettes: boards.length };
          d.curtains = curtainMeshes.length;
          return d;
        },
        dispose: function () {
          post.dispose();
          textures.forEach(function (t) { t.dispose(); });
          key.dispose();
        },
      };
    },
  });
})();
