/*
 * « Lac sous la lune », version 2: a mountain lake at night under a veiled moon, drawn with the
 * HDR finish of post.js (as the forest v2) and the nature kit of scenery.js.
 *
 *   - Moon low over the far ranges (one directional light; a shadow map over the wooded spit on
 *     the left, which the mist on the water samples), veils of high cloud lit silver near it, its
 *     aureole in the air; light rays from the moon in the finish.
 *   - Three ranges of real 3D mountains (polar height field, gradient and ridged noise, moonlight
 *     visibility and occlusion baked per vertex): forested hills on the far shore, a blue middle
 *     range, high peaks with snowfields; haze between them lit by the moon (aerial perspective).
 *   - Spruces: card crowns on the spit (as the forest v2), thousands of camera-facing silhouettes
 *     on the far shore and the hills.
 *   - The lake: real planar reflection (HDR), ripples sliding over the period, Fresnel, the moon's
 *     glitter path from a microfacet distribution; reeds and boulders near the viewer; a band of
 *     mist on the water that drifts and is lit by the moon through the trees.
 *   - The camera drifts on a small closed path: parallax between reeds, spit, shores and ranges.
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

  E.register({
    id: 'lac-lune',
    decors: ['brume', 'etoiles', 'etoiles-filantes', 'lucioles', 'neige'],
    defaults: { etoiles: 60, brume: 30 },
    post: true,

    build: function (ctx) {
      var N = window.EventideScenery.nature;
      var lin = N.lin;
      var scene = ctx.scene, camera = ctx.camera, renderer = ctx.renderer;
      var quality = ctx.quality, high = quality === 'high';
      camera.fov = 50;
      camera.near = 0.5;
      camera.far = 40000;
      var CAM_Y = 2.6;

      renderer.shadowMap.enabled = true;
      renderer.shadowMap.type = THREE.PCFShadowMap;
      renderer.shadowMap.autoUpdate = false;   // the light and the trees never move: drawn once

      var moonAz = -4 * DEG, moonEl = 22 * DEG;
      var moonDir = new THREE.Vector3(Math.sin(moonAz) * Math.cos(moonEl), Math.sin(moonEl), -Math.cos(moonAz) * Math.cos(moonEl));
      var noiseTex = N.noiseTexture(ctx.rng('noise'));
      var rippleTex = N.rippleTexture(ctx.rng('ripple'));
      var atlasTex = N.silhouetteTexture(ctx.rng('atlas'), false, 1);
      var atlasNear = N.silhouetteTexture(ctx.rng('atlas2'), false, 2);
      var textures = [noiseTex, rippleTex, atlasTex, atlasNear];

      var shadowPlaceholder = new THREE.DepthTexture(1, 1);
      shadowPlaceholder.compareFunction = THREE.LessEqualCompare;
      shadowPlaceholder.needsUpdate = true;
      textures.push(shadowPlaceholder);
      var shared = {
        uTime: ctx.uniforms.uTime,
        uLightDir: { value: moonDir },
        uLightFog: { value: new THREE.Vector3(0.04, 0.05, 0.07) },
        uFogAmb: { value: new THREE.Vector3(0.0028, 0.005, 0.0105) },
        uFog: { value: new THREE.Vector4(0.00012, 0.0004, 1 / 170, 0) },
        uMist: { value: new THREE.Vector4(0.0, 1.7, 0.0008, 1 / 150) },
        uAirExt: { value: new THREE.Vector4(1 / 1700, 0.8 / 150, 0.3 / 150, 40000) },
        uNoiseTex: { value: noiseTex },
        uShadowMap: { value: shadowPlaceholder },
        uShadowMatrix: { value: new THREE.Matrix4() },
        uShadowReady: { value: 0 },
      };
      var fogBase = { haze: shared.uFog.value.x, ground: shared.uFog.value.y };
      var K = N.pbrFactory(shared, quality);
      var pbr = K.pbr;

      // ---------------------------------------------------------------- finish (first: the
      // reflection uses its target type)
      var post = ctx.post({
        exposure: 1.12,
        toneMapping: 'aces',
        bloom: { strength: 0.22, threshold: 1.0, knee: 0.6, radius: 1.0 },
        rays: { strength: 0.4, length: 0.45, decay: 0.93, radius: 0.28 },
        aberration: 0.005,
        vignette: 0.4,
        grain: ctx.record ? 0 : 0.026,
      });

      // ---------------------------------------------------------------- lights
      var moonColor = lin('#c6d2ea');
      var moonI = 2.2;
      var moon = new THREE.DirectionalLight(moonColor, moonI);
      var target = new THREE.Vector3(-70, 0, -240);
      moon.target.position.copy(target);
      moon.position.copy(target).addScaledVector(moonDir, 700);
      moon.castShadow = true;
      var shadowSize = high ? 1024 : 512;
      moon.shadow.mapSize.set(shadowSize, shadowSize);
      var sc = moon.shadow.camera;
      sc.left = -140; sc.right = 140; sc.top = 85; sc.bottom = -85; sc.near = 100; sc.far = 1400;
      sc.updateProjectionMatrix();
      moon.shadow.bias = -0.0005;
      moon.shadow.normalBias = 0.12;
      moon.shadow.radius = 2;
      scene.add(moon);
      scene.add(moon.target);
      var skyLight = lin('#30476e'), groundLight = lin('#0a0d10'), hemiI = 0.35;
      scene.add(new THREE.HemisphereLight(skyLight, groundLight, hemiI));
      var keyV = new THREE.Vector3(moonColor.r, moonColor.g, moonColor.b).multiplyScalar(moonI);
      var skyV = new THREE.Vector3(skyLight.r, skyLight.g, skyLight.b).multiplyScalar(hemiI / Math.PI);

      // ---------------------------------------------------------------- terrain
      var nA = N.gradientNoise(ctx.rng('hA')), nB = N.gradientNoise(ctx.rng('hB')), nC = N.gradientNoise(ctx.rng('hC'));
      function shoreR(th) {
        return 760 + 150 * nA(th * 2.0, 0.5) + 45 * nA(th * 7.0, 3.5);
      }
      function height(x, z) {
        var r = Math.hypot(x, z), th = Math.atan2(x, -z);
        // forested hills on the far shore
        var dA = 1300 + 230 * nA(th * 2.3, 7.1), uA = (r - dA) / 430;
        var hA = 195 * (0.55 + 0.6 * N.fbm(nA, th * 3.1, 2.2, 3)) * Math.exp(-uA * uA * 1.3);
        hA *= 0.8 + 0.4 * N.fbm(nA, x / 240, z / 240, 4);
        // the middle range
        var dB = 2850 + 420 * nB(th * 1.7, 1.3), uB = (r - dB) / 950;
        var hB = 560 * (0.5 + 0.65 * N.fbm(nB, th * 2.6, 4.4, 3)) * Math.exp(-uB * uB * 1.2);
        hB *= 0.45 + 1.0 * N.ridged(nB, x / 560, z / 560, 5);
        // the high peaks
        var dC = 6500 + 1100 * nC(th * 1.3, 2.7), uC = (r - dC) / 2300;
        var hC = 1800 * (0.45 + 0.7 * N.fbm(nC, th * 2.2, 8.1, 3)) * Math.exp(-uC * uC);
        hC *= 0.4 + 1.05 * N.ridged(nC, x / 950, z / 950, 5);
        var land = smax(smax(hA, hB, 60), hC, 120);
        var sr = shoreR(th);
        var rise = Math.max(0, Math.min(1, (r - sr) / 280));
        var h = land * rise * rise * (3 - 2 * rise) + Math.max(-25, Math.min(30, (r - sr) * 0.08));
        // the bank under the camera
        var bank = (z + 3.8) * 0.5 - 0.25 + 0.25 * nA(x * 0.5, z * 0.5);
        // a low wooded spit from the left, and a farther wooded point on the right
        var spit = 5.5 * Math.exp(-Math.pow(segDist(x, z, -12, -96, -150, -380) / 19, 2)) * (0.8 + 0.4 * N.fbm(nA, x / 30, z / 30, 3)) - 1.5;
        var point = 9.0 * Math.exp(-Math.pow(segDist(x, z, 55, -360, 240, -560) / 32, 2)) * (0.8 + 0.4 * N.fbm(nB, x / 50, z / 50, 3)) - 2.5;
        return Math.max(h, bank, spit, point);
      }
      var far = N.polarTerrain({
        th0: -64 * DEG, th1: 64 * DEG, nTheta: high ? 520 : 380, r0: 560, r1: 17000, nR: high ? 210 : 150, chunks: 10,
        height: height, light: moonDir, bakeSteps: 22, bakeDistance: 7000,
      });
      var near = N.polarTerrain({
        th0: -80 * DEG, th1: 80 * DEG, nTheta: 200, r0: 2, r1: 620, nR: 100, chunks: 8,
        height: height, light: moonDir, bakeSteps: 14, bakeDistance: 500, aoRadius: function (r) { return Math.max(1.5, r * 0.05); },
        fallback: far.sample,
      });
      function groundAt(x, z) {
        return Math.hypot(x, z) < 590 ? near.sample(x, z) : far.sample(x, z);
      }

      var terrainHooks = {
        key: 'terrain',
        drySpecular: 0.02,
        uniforms: { uTreeLine: { value: 420 }, uSnowLine: { value: 1250 } },
        vertexPars: 'attribute vec2 aBake; varying vec2 vBake;',
        vertex: 'vBake = aBake;',
        fragmentPars: 'varying vec2 vBake; uniform float uTreeLine; uniform float uSnowLine;',
        color: [
          'vec3 naP = vNaWorld;',
          'float naSlope = 1.0 - clamp(vNaNormal.y, 0.0, 1.0);',
          'float naN1 = texture2D(uNoiseTex, naP.xz * 0.0019).r;',
          'float naN2 = texture2D(uNoiseTex, naP.xz * 0.0105).g;',
          'float naN3 = texture2D(uNoiseTex, naP.xz * 0.047 + vec2(0.0, naP.y * 0.021)).b;',
          'float naCell = texture2D(uNoiseTex, naP.xz * 0.04).a;',
          // forest below a ragged tree line, alpine turf and scree, rock on the steep faces, snow
          // on the high gentle slopes; the bank and the spit: dark turf and stones, wet at the water
          'float naTreeLine = uTreeLine + 140.0 * (naN1 - 0.5) - 300.0 * naSlope;',
          'float naForest = smoothstep(naTreeLine + 25.0, naTreeLine - 25.0, naP.y) * smoothstep(0.8, 0.55, naSlope);',
          'float naRock = smoothstep(0.32, 0.58, naSlope + 0.3 * (naN2 - 0.5));',
          'float naSnowLine = uSnowLine + 260.0 * (naN1 - 0.5) + 140.0 * (naN3 - 0.5);',
          'float naSnow = smoothstep(naSnowLine - 30.0, naSnowLine + 70.0, naP.y) * smoothstep(0.66, 0.44, naSlope + 0.25 * (naN3 - 0.5));',
          'vec3 naAlb = mix(vec3(0.034, 0.036, 0.027), vec3(0.052, 0.052, 0.055), naRock);',
          // under the canopy: the floor is in the trees' shade, only their dark crowns show
          'naAlb = mix(naAlb, vec3(0.005, 0.0075, 0.006) * (0.6 + 0.8 * smoothstep(0.1, 0.6, naCell)), naForest);',
          'naAlb = mix(naAlb, vec3(0.70, 0.74, 0.80), naSnow);',
          'naAlb *= 0.8 + 0.4 * naN2;',
          'float naWet = smoothstep(1.2, 0.05, naP.y) * step(length(naP.xz), 700.0);',
          'naAlb *= 1.0 - 0.45 * naWet;',
          'diffuseColor.rgb = naAlb;',
          'float naH = naRock * naN3 + naForest * (1.0 - naCell) * 0.6 + naSnow * naN2 * 0.3;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(mix(0.93, 0.8, naWet), 0.7, naSnow);',
        normal: 'normal = na_bump(normal, -vViewPosition, naH, 0.06 * smoothstep(9000.0, 300.0, length(vViewPosition)) + 0.004);',
        lightEnd: [
          'reflectedLight.directDiffuse *= vBake.x;',
          'reflectedLight.directSpecular *= vBake.x;',
          'reflectedLight.indirectDiffuse *= vBake.y * (1.0 - 0.6 * naForest);',
        ].join('\n'),
      };
      var terrainMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.92, metalness: 0 }, terrainHooks);
      // the chunks are long wedges (their bounding spheres never leave the view): they are shown
      // by azimuth instead, against the camera's horizontal field (the reflection has the same)
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

      // ---------------------------------------------------------------- spruces
      var treeRng = ctx.rng('trees');
      var cards = [], boards = [];
      function slopeAt(x, z) {
        return 1 - (Math.hypot(x, z) < 590 ? near : far).normalAt(x, z).y;
      }
      // the spit: a few dozen card spruces, closest first
      var spitTrees = [];
      for (var at = 0; at < 6000 && spitTrees.length < (high ? 52 : 34); at++) {
        var f = Math.pow(treeRng(), 1.6);
        var sx = -12 + (-150 + 12) * f + (treeRng() - 0.5) * 36, sz = -96 + (-380 + 96) * f + (treeRng() - 0.5) * 36;
        var gy = groundAt(sx, sz);
        if (gy < 0.9 || Math.atan2(sx, -sz) > -5.5 * DEG) continue;
        var ok = true;
        for (var j = 0; j < spitTrees.length; j++) {
          if (Math.hypot(spitTrees[j].x - sx, spitTrees[j].z - sz) < 4.2) { ok = false; break; }
        }
        if (!ok) continue;
        var d = Math.hypot(sx, sz);
        spitTrees.push({ x: sx, y: gy - 0.15, z: sz, s: 0.5 + treeRng() * 0.5, variant: Math.floor(treeRng() * 3), rot: treeRng() * TAU, lean: (treeRng() - 0.5) * 0.05, lod: d < 140 ? 0 : d < 230 ? 1 : 2, d: d });
      }
      // seen from the height of the eye, the near spruces are dense silhouettes too (their
      // branch cards, made to be seen from under the canopy, would be edge-on here)
      spitTrees.forEach(function (t) {
        (t.d < 300 ? cards : boards).push({ x: t.x, y: t.y, z: t.z, h: 9 + 13 * t.s, cell: Math.floor(treeRng() * 4), wr: 0.38 + treeRng() * 0.08, tint: treeRng() });
      });
      // far shores and hills: silhouettes, dense along the shore, thinner up the slopes
      var want = high ? 9000 : 4500;
      for (var at2 = 0; at2 < want * 12 && boards.length < want; at2++) {
        var th = (treeRng() * 2 - 1) * 62 * DEG;
        var r = 330 * Math.pow(2600 / 330, treeRng());
        var bx = r * Math.sin(th), bz = -r * Math.cos(th);
        var by = groundAt(bx, bz);
        if (by < 0.8 || by > 400 + 80 * nA(bx / 300, bz / 300)) continue;
        if (slopeAt(bx, bz) > 0.55) continue;
        var grove = 0.5 + 0.5 * N.fbm(nB, bx / 180, bz / 180, 3);
        var dens = by < 60 ? 1.0 : Math.min(1, Math.max(0.08, grove * 1.5 - 0.2));
        if (treeRng() > dens) continue;
        var tall = (by < 60 ? 14 : 9) + Math.pow(treeRng(), 0.7) * 16 * (0.7 + 0.6 * grove);
        boards.push({ x: bx, y: by - 0.5, z: bz, h: tall, cell: Math.floor(treeRng() * 4), wr: 0.38 + treeRng() * 0.14, tint: treeRng() });
      }
      var billboards = N.billboardConifers(ctx, shared, boards, {
        atlas: atlasTex, key: keyV, sky: skyV, albedo: new THREE.Vector3(0.016, 0.024, 0.018), back: 0.8,
      });
      scene.add(billboards);
      var spitBoards = N.billboardConifers(ctx, shared, cards, {
        atlas: atlasNear, key: keyV, sky: skyV, albedo: new THREE.Vector3(0.016, 0.024, 0.018), back: 0.8, castShadow: true,
      });
      scene.add(spitBoards);

      // ---------------------------------------------------------------- boulders by the shore
      var rockGeo = N.rockGeometry(ctx.rng('rock'));
      var rockMat = pbr(THREE.MeshStandardMaterial, { color: 0xffffff, roughness: 0.6, metalness: 0 }, {
        key: 'rock',
        drySpecular: 0.04,
        color: [
          'float naR1 = texture2D(uNoiseTex, vNaWorld.xz * 0.9 + vNaWorld.y * 0.6).g;',
          'float naR2 = texture2D(uNoiseTex, vNaWorld.xy * 1.7).b;',
          'diffuseColor.rgb = mix(vec3(0.018, 0.019, 0.02), vec3(0.042, 0.041, 0.04), naR1 * 0.7 + naR2 * 0.3);',
          'float naWetR = smoothstep(0.35, -0.05, vNaWorld.y);',
          'diffuseColor.rgb *= 1.0 - 0.5 * naWetR;',
        ].join('\n'),
        roughness: 'roughnessFactor = mix(0.85, 0.6, naWetR);',
        normal: 'normal = na_bump(normal, -vViewPosition, naR1 * 0.6 + naR2 * 0.4, 0.01);',
      });
      [[-1.45, -0.32, -8.6, 0.62, 0.4], [2.1, -0.36, -13.5, 0.9, 2.1], [-0.55, -0.4, -23, 0.55, 4.0], [-3.2, -0.3, -12.5, 1.0, 1.0]].forEach(function (b) {
        var m = new THREE.Mesh(rockGeo, rockMat);
        m.position.set(b[0], b[1], b[2]);
        m.scale.set(b[3], b[3] * 0.8, b[3] * 1.1);
        m.rotation.y = b[4];
        scene.add(m);
      });

      // ---------------------------------------------------------------- reeds
      var reedRng = ctx.rng('reeds');
      var ra = [], rb = [];
      function cluster(az0, az1, r0, r1, count) {
        var c0 = (az0 + az1) / 2 * DEG, cr = (r0 + r1) / 2;
        for (var i = 0; i < count; i++) {
          // a clump: denser in the middle
          var a = c0 + (reedRng() + reedRng() - 1) * (az1 - az0) / 2 * DEG;
          var rr = cr + (reedRng() + reedRng() - 1) * (r1 - r0) / 2;
          var leaf = reedRng() < 0.28;
          ra.push(rr * Math.sin(a), -rr * Math.cos(a), leaf ? 0.6 + reedRng() * 0.7 : 1.0 + reedRng() * 1.4, reedRng() * TAU);
          rb.push(leaf ? 0.022 + reedRng() * 0.012 : 0.007 + reedRng() * 0.006, leaf ? 0.25 + reedRng() * 0.35 : 0.04 + reedRng() * 0.16, reedRng(), leaf ? 1 : 0);
        }
      }
      cluster(-12.5, -6, 9, 17, high ? 110 : 70);
      cluster(6.5, 12.5, 12, 20, high ? 80 : 50);
      var reedGeo = new THREE.InstancedBufferGeometry();
      var rv = [], SEG = 7;
      for (var s = 0; s < SEG; s++) {
        var u0 = s / SEG, u1 = (s + 1) / SEG;
        rv.push(-1, u0, 0, 1, u0, 0, 1, u1, 0, -1, u0, 0, 1, u1, 0, -1, u1, 0);
      }
      reedGeo.setAttribute('position', new THREE.Float32BufferAttribute(rv, 3));
      reedGeo.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(ra), 4));
      reedGeo.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(rb), 4));
      reedGeo.instanceCount = ra.length / 4;
      var REED_VERTEX = [
        'attribute vec4 aA; attribute vec4 aB;',
        // the stem's point at u (0 base, 1 top): leaning and swaying slowly (whole turns a period)
        'vec3 reedPoint(float u) {',
        '  float T = EV_TAU * uTime / EV_PERIOD;',
        '  float sway = 0.03 * sin(T + aB.z * EV_TAU) + 0.015 * sin(2.0 * T + aB.z * 9.0);',
        '  float bend = (aB.y + sway * (1.0 + aB.w)) * u * u;',
        '  vec2 dir = vec2(cos(aA.w), sin(aA.w));',
        '  return vec3(aA.x + dir.x * bend * aA.z, -0.3 + u * aA.z * (1.0 - 0.35 * bend * bend), aA.y + dir.y * bend * aA.z);',
        '}',
      ].join('\n');
      var reedMat = ctx.material({
        uniforms: Object.assign({}, shared, { uKey: { value: keyV }, uSky: { value: skyV }, uAlb: { value: new THREE.Vector3(0.016, 0.018, 0.011) } }),
        side: THREE.DoubleSide,
        vertexShader: REED_VERTEX + '\n' + [
          'varying vec3 vWorld; varying float vU; varying float vEdge;',
          'void main() {',
          '  float u = position.y;',
          '  vec3 p = reedPoint(u);',
          '  vec3 toCam = normalize(cameraPosition - p);',
          '  vec3 side = normalize(vec3(toCam.z, 0.0, -toCam.x));',
          '  float w = aB.x * mix(1.0, 0.12, u * u);',
          '  p += side * position.x * w;',
          '  vWorld = p; vU = u; vEdge = position.x;',
          '  gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);',
          '}',
        ].join('\n'),
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + N.AIR_GLSL + '\n' + [
          'uniform vec3 uKey; uniform vec3 uSky; uniform vec3 uAlb;',
          'varying vec3 vWorld; varying float vU; varying float vEdge;',
          'void main() {',
          '  vec3 V = normalize(cameraPosition - vWorld);',
          '  float back = pow(max(dot(-V, uLightDir), 0.0), 3.0);',
          '  vec3 alb = uAlb * mix(0.55, 1.35, vU);',
          '  vec3 c = alb * uSky * (0.4 + 0.6 * vU);',
          // thin blades glow against the moon, most along their edges
          '  c += alb * uKey * 0.3183 * (0.03 + back * 0.45 * (0.3 + abs(vEdge)));',
          '  c = na_air(c, vWorld);',
          '  gl_FragColor = vec4(c, 1.0);',
          '}',
        ].join('\n'),
      });
      var reeds = new THREE.Mesh(reedGeo, reedMat);
      reeds.frustumCulled = false;
      scene.add(reeds);
      // plumes on a third of the stems, nodding, silver against the moon
      var pa = [], pb = [];
      for (var k = 0; k < ra.length / 4; k++) {
        if (rb[k * 4 + 3] > 0.5 || reedRng() > 0.4) continue;
        pa.push(ra[k * 4], ra[k * 4 + 1], ra[k * 4 + 2], ra[k * 4 + 3]);
        pb.push(rb[k * 4], rb[k * 4 + 1], rb[k * 4 + 2], 0);
      }
      var plumeGeo = new THREE.InstancedBufferGeometry();
      plumeGeo.setAttribute('position', new THREE.Float32BufferAttribute([-1, 0, 0, 1, 0, 0, 1, 1, 0, -1, 0, 0, 1, 1, 0, -1, 1, 0], 3));
      plumeGeo.setAttribute('aA', new THREE.InstancedBufferAttribute(new Float32Array(pa), 4));
      plumeGeo.setAttribute('aB', new THREE.InstancedBufferAttribute(new Float32Array(pb), 4));
      plumeGeo.instanceCount = pa.length / 4;
      var plumeMat = ctx.material({
        uniforms: Object.assign({}, shared, { uKey: { value: keyV }, uSky: { value: skyV } }),
        side: THREE.DoubleSide,
        vertexShader: REED_VERTEX + '\n' + [
          'varying vec3 vWorld; varying vec2 vQ;',
          'void main() {',
          '  vec3 top = reedPoint(1.0);',
          '  vec3 under = reedPoint(0.93);',
          '  vec3 along = normalize(top - under);',
          // the plume hangs from the top of the stem, nodding away from its lean
          '  vec3 hang = normalize(along * 0.35 + vec3(cos(aA.w), -1.6, sin(aA.w)) * 0.5);',
          '  vec3 toCam = normalize(cameraPosition - top);',
          '  vec3 side = normalize(cross(hang, toCam));',
          '  float len = 0.22 + 0.08 * aB.z;',
          '  vec3 p = top + hang * position.y * len + side * position.x * 0.045 * sin(3.14159 * min(1.0, position.y * 1.15 + 0.08));',
          '  vWorld = p; vQ = vec2(position.x, position.y);',
          '  gl_Position = projectionMatrix * viewMatrix * vec4(p, 1.0);',
          '}',
        ].join('\n'),
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + N.AIR_GLSL + '\n' + [
          'uniform vec3 uKey; uniform vec3 uSky;',
          'varying vec3 vWorld; varying vec2 vQ;',
          'void main() {',
          '  float strands = 0.55 + 0.45 * sin(vQ.x * 9.0 + vQ.y * 23.0) * sin(vQ.y * 41.0 - vQ.x * 5.0);',
          '  float a = (1.0 - abs(vQ.x)) * strands;',
          '  if (a < 0.3) discard;',
          '  vec3 V = normalize(cameraPosition - vWorld);',
          '  float back = pow(max(dot(-V, uLightDir), 0.0), 2.0);',
          '  vec3 alb = vec3(0.05, 0.043, 0.032);',
          '  vec3 c = alb * uSky * 0.8 + alb * uKey * 0.3183 * (0.05 + 0.8 * back);',
          '  c = na_air(c, vWorld);',
          '  gl_FragColor = vec4(c, 1.0);',
          '}',
        ].join('\n'),
      });
      var plumes = new THREE.Mesh(plumeGeo, plumeMat);
      plumes.frustumCulled = false;
      scene.add(plumes);

      // ---------------------------------------------------------------- sky (moon, veils)
      var skyMat = ctx.material({
        uniforms: Object.assign({}, shared, {
          uZenith: { value: lin('#02040b') },
          uHorizon: { value: lin('#14223a').multiplyScalar(0.5) },
          uMoonDisc: { value: lin('#f3efe2').multiplyScalar(3.2) },
          uMoonR: { value: 0.0155 },
          uNoMoon: { value: 0 },
        }),
        vertexShader: 'varying vec3 vDir;\nvoid main() { vDir = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + N.AIR_GLSL + '\n' + [
          'uniform vec3 uZenith; uniform vec3 uHorizon; uniform vec3 uMoonDisc; uniform float uMoonR; uniform float uNoMoon;',
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  float c = dot(d, uLightDir);',
          '  vec3 col = mix(uHorizon, uZenith, smoothstep(-0.05, 0.6, d.y));',
          // veils of high cloud (cirrostratus) drifting slowly, lit silver near the moon
          '  vec2 p = d.xz / max(d.y + 0.16, 0.05) * 0.3;',
          '  float v1 = na_loopNoise(p * 0.55 + vec2(0.2, 0.7), vec2(0.0016, 0.0005));',
          '  float v2 = texture2D(uNoiseTex, p * vec2(3.2, 1.4) + v1 * 0.35).g;',
          '  float veil = smoothstep(0.36, 0.82, v1 * 0.8 + v2 * 0.32) * smoothstep(-0.02, 0.22, d.y);',
          '  float ph = na_phase(c);',
          '  col += uLightFog * veil * (0.04 + 0.9 * ph);',
          '  col += uLightFog * ph * 0.12;',
          '  if (uNoMoon < 0.5) {',
          '    float r = acos(clamp(c, -1.0, 1.0));',
          '    float disc = 1.0 - smoothstep(uMoonR * 0.94, uMoonR * 1.03, r);',
          '    if (disc > 0.0) {',
          '      vec3 up = normalize(vec3(0.0, 1.0, 0.0) - uLightDir * uLightDir.y);',
          '      vec3 side = normalize(cross(uLightDir, up));',
          '      vec2 q = vec2(dot(d, side), dot(d, up)) / uMoonR;',
          '      float maria = texture2D(uNoiseTex, q * 0.2 + vec2(0.43, 0.61)).r * 0.6 + texture2D(uNoiseTex, q * 0.5 + 0.2).g * 0.4;',
          '      float limb = sqrt(max(0.0, 1.0 - dot(q, q)));',
          '      vec3 moonC = uMoonDisc * (0.62 + 0.38 * limb) * (1.0 - 0.36 * smoothstep(0.42, 0.66, maria));',
          '      col = mix(col, moonC * (1.0 - veil * 0.45), disc);',
          '    }',
          '  }',
          '  col = na_skyAir(col, d);',
          '  gl_FragColor = vec4(col, 1.0);',
          '}',
        ].join('\n'),
        side: THREE.BackSide,
        depthWrite: false,
      });
      var sky = new THREE.Mesh(new THREE.SphereGeometry(30000, 48, 24), skyMat);
      sky.renderOrder = 10;   // after the opaque scene: only the gaps are shaded
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- the lake
      var lake = ctx.mirror({
        y: 0,
        size: [9000, 5200],
        center: [0, -2500],
        scale: high ? 0.4 : 0.3,
        type: post.floatTargets ? THREE.HalfFloatType : undefined,
        uniforms: Object.assign({}, shared, {
          uRipple: { value: rippleTex },
          uDeep: { value: new THREE.Vector3(0.0012, 0.0022, 0.003) },
          uGlint: { value: new THREE.Vector3(moonColor.r, moonColor.g, moonColor.b * 0.92).multiplyScalar(0.07) },
          uWave: { value: new THREE.Vector4(0.2, 1.0, 60, 0.025) },
          uTiles: { value: new THREE.Vector4(11, 4.1, 1.55, 1.0) },
          uQuiet: { value: 0.035 },
        }),
        fragmentShader: (high ? '' : '#define NA_LOW 1\n') + '#define NA_GLINT 1\n' + N.AIR_GLSL + '\n' + N.WATER_GLSL,
      });
      // the reflection shows the moon's light in the air and the clouds, not its disc: the glitter
      // of the water (a distribution of the ripples' slopes) is the moon's image
      var mirrorBefore = lake.onBeforeRender;
      lake.onBeforeRender = function (a, b, c, d, e, f) {
        skyMat.uniforms.uNoMoon.value = 1;
        mirrorBefore.call(this, a, b, c, d, e, f);
        skyMat.uniforms.uNoMoon.value = 0;
      };
      scene.add(lake);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      function levelOnly(object, extra) {
        object.visible = false;
        return { object: object, setLevel: function (v) { if (extra) extra(v); } };
      }
      var stars = D.etoiles(ctx, {
        count: high ? 900 : 600, radius: 28000, azimuth: [-4, 46], elevation: [4, 80], size: 0.9, brightness: 2.4,
        band: { normal: [0.55, 0.35, 0.75], width: 0.16, count: high ? 1500 : 900 },
        tint: ['#cfdcff', '#fff1df'],
      });
      stars.object.renderOrder = 11;
      stars.object.layers.set(1);
      // in the visible sky (the top of the view is about 30 degrees up)
      var meteors = D['etoiles-filantes'](ctx, { radius: 27000, azimuth: [2, 13], elevation: [17, 27] });
      meteors.object.material.uniforms.uColor.value.multiplyScalar(4);
      meteors.object.renderOrder = 12;
      meteors.object.layers.set(1);
      var fireflies = D.lucioles(ctx, {
        count: high ? 110 : 70, box: { min: [-7, 0.25, -30], max: [7, 2.4, -5] }, size: 0.06, color: '#e6f2a0', lowBias: 1.5,
      });
      fireflies.object.material.uniforms.uColor.value.multiplyScalar(9);
      fireflies.object.layers.set(1);   // points through the 4-tap filter of the small reflection: no
      var snow = D.neige(ctx, {
        count: high ? 1500 : 900, box: { min: [-7, -0.2, -26], max: [7, 9, 1] }, size: [0.02, 0.045], color: '#6f7a8c', opacity: 0.85,
      });
      snow.object.layers.set(1);   // not in the reflection (it would double its cost)
      var mistLevel = 0;
      function applyMist(v) {
        mistLevel = v;
        var low = high ? 1 : 0.8;
        shared.uFog.value.x = fogBase.haze * (1 + 0.12 * v) * low;
        shared.uFog.value.y = fogBase.ground * (1 + 0.6 * v) * low;
        shared.uFog.value.w = v * low;
      }
      applyMist(0);
      var decors = {
        brume: levelOnly(new THREE.Group(), applyMist),
        etoiles: stars,
        'etoiles-filantes': meteors,
        lucioles: fireflies,
        neige: snow,
      };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      // ---------------------------------------------------------------- camera path (loops)
      var lookY = CAM_Y + Math.tan(5 * DEG) * 400;
      function update(t) {
        var T = t / ctx.PERIOD * TAU;
        camera.position.set(0.35 * Math.sin(T), CAM_Y + 0.05 * Math.sin(2 * T + 0.4), 0.3 * Math.cos(T));
        camera.lookAt(1.6 * Math.sin(T + 0.6), lookY + 1.2 * Math.sin(T), -400);
      }
      update(0);
      var moonScreen = new THREE.Vector3();

      // the mist samples the moon's shadow map: one tiny render makes it before the first frame
      function primeShadows() {
        renderer.shadowMap.needsUpdate = true;
        var rt = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType });
        renderer.setRenderTarget(rt);
        chunkMeshes.forEach(function (m) { m.visible = true; });
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
          camera.updateMatrixWorld();
          cullChunks();
          moonScreen.copy(moonDir).multiplyScalar(1000).add(camera.position).project(camera);
          post.setLight(moonScreen.x * 0.5 + 0.5, moonScreen.y * 0.5 + 0.5);
          post.render(scene, camera);
        },
        setQuality: function (q) {
          quality = q;
          post.setQuality(q);
          K.setQuality(q);
          N.setLowAir([reedMat, plumeMat, skyMat, lake.material, billboards.material, spitBoards.material], q === 'low');
          // fewer far spruces in 'low' (they were drawn in random order: a uniform thinning)
          billboards.geometry.instanceCount = Math.round(boards.length * (q === 'low' ? 0.6 : 1));
          billboards.material.alphaToCoverage = q === 'high';
          spitBoards.material.alphaToCoverage = q === 'high';
          var size = q === 'high' ? 1024 : 512;
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
          d.trees = { spit: cards.length, silhouettes: boards.length };
          d.reeds = ra.length / 4;
          return d;
        },
        dispose: function () {
          post.dispose();
          textures.forEach(function (t) { t.dispose(); });
          moon.dispose();
        },
      };
    },
  });
})();
