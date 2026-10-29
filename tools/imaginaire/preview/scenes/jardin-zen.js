/*
 * « Jardin zen »: a Japanese dry garden in the golden light of early morning. Raked gravel
 * circles around mossy stones, a clipped hedge, misty hills in a warm haze, a cherry branch in
 * blossom against the light. In the foreground a dark, still pond keeps the lower third calm.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  var SCENE_GLSL = [
    'uniform vec3 uSkyTop; uniform vec3 uSkyLow; uniform vec3 uSun; uniform vec3 uSunDir; uniform vec3 uShade; uniform float uMist;',
    'uniform float uRain;',
    'vec3 skyBase(vec3 d) {',
    '  float g = max(dot(d, uSunDir), 0.0);',
    '  vec3 c = mix(uSkyLow, uSkyTop, smoothstep(0.0, 0.6, d.y));',
    '  c += uSun * (pow(g, 6.0) * 0.22 + pow(g, 60.0) * 0.4 + pow(g, 900.0) * 1.2);',
    '  return mix(c, vec3(dot(c, vec3(0.3, 0.5, 0.2))) * vec3(0.82, 0.88, 0.95), uRain * 0.45);',
    '}',
    'vec3 applyFog(vec3 col, vec3 worldPos, float density) {',
    '  vec3 d = worldPos - cameraPosition;',
    '  float dist = length(d);',
    '  vec3 dir = d / dist;',
    '  float f = 1.0 - exp(-dist * density * (1.0 + 0.45 * uMist + 0.8 * uRain));',
    '  return mix(col, skyBase(vec3(dir.x, max(dir.y, 0.0) * 0.4, dir.z)), clamp(f, 0.0, 1.0));',
    '}',
    // light of a lambert surface: warm sun, cool sky
    'vec3 lightAt(vec3 n, float occ) {',
    '  float sun = max(dot(n, uSunDir), 0.0) * (1.0 - 0.6 * uRain);',
    '  float sky = 0.5 + 0.5 * n.y;',
    '  return uSun * sun * 1.05 + uShade * sky * occ;',
    '}',
  ].join('\n');

  // A bamboo grove along a row: thin leaning culms with nodes, feathery foliage above.
  var BAMBOO_GLSL = [
    'uniform float uSpacing; uniform vec2 uHeight; uniform float uSeed;',
    'float bamboo(float x, float y, float aa) {',
    '  float cell = floor(x / uSpacing);',
    '  float best = -1e3;',
    '  for (int i = -1; i <= 1; i++) {',
    '    float c = cell + float(i);',
    '    float h1 = ev_hash12(vec2(c, uSeed));',
    '    float h2 = ev_hash12(vec2(c, uSeed + 4.0));',
    '    float cx = (c + 0.5 + (h1 - 0.5) * 0.7) * uSpacing;',
    '    float H = mix(uHeight.x, uHeight.y, h2);',
    '    float t = clamp(y / H, 0.0, 1.0);',
    '    float sx = cx + (h1 - 0.5) * 0.25 * y + 0.15 * H * t * t * (h2 - 0.5) + 0.03 * H * t * t * ev_wave(1.0, h1, uTime);',
    '    float w = (0.045 + 0.03 * h2) * (1.0 - 0.6 * t);',
    '    float nodeLen = 0.9 + 0.5 * h1;',
    '    float node = fract(y / nodeLen);',
    '    w *= 1.0 - 0.25 * smoothstep(0.0, 0.04, node) * smoothstep(0.08, 0.04, node);',
    '    best = max(best, min(w - abs(x - sx), H - y));',
    // sprays of narrow leaves hanging from the upper nodes
    '    if (y > H * 0.45 && y < H + 1.0) {',
    '      for (int k = 0; k < 2; k++) {',
    '        float n = floor(y / nodeLen) + float(k);',
    '        float by = n * nodeLen;',
    '        if (by < H * 0.5 || by > H) continue;',
    '        float hn = ev_hash12(vec2(c * 1.7 + n, uSeed + 9.0));',
    '        float tb = by / H;',
    '        float bx = cx + (h1 - 0.5) * 0.25 * by + 0.15 * H * tb * tb * (h2 - 0.5) + 0.03 * H * tb * tb * ev_wave(1.0, h1, uTime);',
    '        for (int s = 0; s < 3; s++) {',
    '          float fs = float(s);',
    '          float ang = -0.5 - 0.9 * fract(hn * 7.0 + fs * 0.37);',
    '          float side = mod(fs + floor(hn * 2.0), 2.0) * 2.0 - 1.0;',
    '          vec2 dir = vec2(cos(ang) * side, sin(ang));',
    '          vec2 q = vec2(x - bx, y - by);',
    '          float u = dot(q, dir);',
    '          float v = abs(q.x * dir.y - q.y * dir.x);',
    '          float L = 0.55 + 0.35 * fract(hn * 13.0 + fs);',
    '          float lw = 0.07 * sin(3.14159 * clamp(u / L, 0.0, 1.0));',
    '          best = max(best, min(lw - v, min(u, L - u)));',
    '        }',
    '      }',
    '    }',
    '  }',
    '  return best;',
    '}',
  ].join('\n');

  function rock(r, radius, squash) {
    var g = new THREE.IcosahedronGeometry(1, 4);
    var p = g.attributes.position;
    var v = new THREE.Vector3();
    var seeds = [r() * 10, r() * 10, r() * 10];
    // a weathered boulder: a lumpy sphere cut by a few planes (split faces, flat tops)
    var cuts = [];
    for (var c = 0; c < 7; c++) {
      var cn = new THREE.Vector3(r() * 2 - 1, r() * 1.4 - 0.2, r() * 2 - 1).normalize();
      cuts.push([cn, 0.72 + r() * 0.2]);
    }
    for (var i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      var n = 1 + 0.2 * Math.sin(v.x * 1.6 + seeds[0]) * Math.cos(v.z * 1.3 + seeds[1]) + 0.08 * Math.sin(v.y * 3.1 + v.x * 2.0 + seeds[2]) + 0.035 * Math.sin(v.x * 9.0 + v.z * 7.0 + v.y * 5.0);
      v.multiplyScalar(n);
      for (var k = 0; k < cuts.length; k++) {
        var over = v.dot(cuts[k][0]) - cuts[k][1];
        if (over > 0) v.addScaledVector(cuts[k][0], -over * 0.92);
      }
      v.y = v.y > 0 ? v.y * squash : v.y * 0.35;
      v.multiplyScalar(radius);
      p.setXYZ(i, v.x, v.y, v.z);
    }
    g.computeVertexNormals();
    return g;
  }

  E.register({
    id: 'jardin-zen',
    decors: ['petales', 'rayons-soleil', 'brume', 'pluie'],
    defaults: { petales: 40, 'rayons-soleil': 30 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      var S = window.EventideScenery;
      var r = ctx.rng('scene');
      camera.fov = 48;
      camera.near = 0.1;
      camera.far = 2000;

      var sunDir = new THREE.Vector3(0.42, 0.2, -1).normalize();
      var shared = {
        uSkyTop: { value: ctx.color('#8ea3b5') },
        uSkyLow: { value: ctx.color('#dcc09f') },
        uSun: { value: ctx.color('#ffd6a0') },
        uSunDir: { value: sunDir },
        uShade: { value: ctx.color('#5d6d86') },
        uMist: { value: 0 },
        uRain: { value: 0 },
      };
      function sceneMat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        params.fragmentShader = SCENE_GLSL + '\n' + params.fragmentShader;
        return ctx.material(params);
      }
      var stones = [
        new THREE.Vector3(-2.2, 0, -11), new THREE.Vector3(2.6, 0, -16), new THREE.Vector3(0.6, 0, -22.5),
      ];

      // ---------------------------------------------------------------- sky
      var sky = new THREE.Mesh(new THREE.SphereGeometry(1500, 32, 16), sceneMat({
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
          '  vec2 p = d.xz / max(d.y + 0.15, 0.05);',
          '  float cl = ev_loopFbm(p * vec2(0.5, 1.2) + 3.0, vec2(0.02, 0.0), uTime);',
          '  c = mix(c, c * 1.06 + uSun * 0.06, smoothstep(0.5, 0.8, cl) * smoothstep(0.05, 0.3, d.y));',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- hills and garden trees
      [
        [-420, 520, 70, '#b9a99a', 8.0, 0.006, 0.004],
        [-260, 340, 42, '#8f8a7e', 9.0, 0.01, 0.004],
      ].forEach(function (R, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uTop: { value: R[2] }, uCol: { value: ctx.color(R[3]) }, uSeed: { value: R[4] }, uFreq: { value: R[5] }, uDens: { value: R[6] },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: S.RIDGE + '\n' + [
            'uniform float uTop; uniform vec3 uCol; uniform float uSeed; uniform float uFreq; uniform float uDens;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float h = uTop * (0.3 + 0.7 * ev_ridge(vLocal.x, uSeed, uFreq * 0.7));',
            '  float aa = fwidth(vLocal.y) * 1.2;',
            '  float cov = smoothstep(-aa, aa, h - vLocal.y);',
            '  if (cov < 0.01) discard;',
            // forested hills: a soft texture of tree crowns
            '  float tex = ev_fbm3(vLocal.xy * vec2(0.15, 0.25));',
            '  vec3 c = uCol * (0.9 + 0.2 * tex);',
            '  c = applyFog(c, vWorld, uDens);',
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.02, vWorld.z))), exp(-max(vLocal.y, 0.0) / (uTop * 0.3)) * 0.6);',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), R[0], R[1], R[2] + 2, -2);
        m.material.alphaToCoverage = true;
        m.renderOrder = -8 + idx;
        scene.add(m);
      });

      // a bamboo grove behind the hedge, in the morning haze (two depths)
      [
        [-78, 0.55, [11, 16], 51, 0.02, '#7d8a80'],
        [-46, 0.7, [9, 14], 57, 0.018, '#56665a'],
      ].forEach(function (row, idx) {
        var m = S.rowQuad(sceneMat({
          uniforms: {
            uSpacing: { value: row[1] }, uHeight: { value: new THREE.Vector2(row[2][0], row[2][1]) }, uSeed: { value: row[3] },
            uDens: { value: row[4] }, uCol: { value: ctx.color(row[5]) },
          },
          vertexShader: S.ROW_VERTEX,
          fragmentShader: BAMBOO_GLSL + '\n' + [
            'uniform float uDens; uniform vec3 uCol;',
            'varying vec3 vWorld; varying vec2 vLocal;',
            'void main() {',
            '  float aa = fwidth(vLocal.x) * 1.2;',
            '  float d = bamboo(vLocal.x, vLocal.y, aa);',
            '  float cov = smoothstep(-aa, aa, d);',
            '  if (cov < 0.01) discard;',
            '  float leaf = ev_noise(vLocal.xy * vec2(3.0, 6.0));',
            '  vec3 c = uCol * (0.8 + 0.35 * leaf);',
            '  c = applyFog(c, vWorld, uDens);',
            // the haze is thicker near the ground
            '  c = mix(c, skyBase(normalize(vec3(vWorld.x, 0.03, vWorld.z))), exp(-max(vLocal.y, 0.0) / 2.5) * 0.45);',
            '  gl_FragColor = vec4(ev_dither(c), cov);',
            '}',
          ].join('\n'),
        }), row[0], 110, 18, -1);
        m.material.alphaToCoverage = true;
        m.renderOrder = -6 + idx;
        scene.add(m);
      });

      // ---------------------------------------------------------------- clipped hedge (karikomi)
      var hedgeParts = [];
      for (var h = 0; h < 26; h++) {
        var hx = -16 + h * 1.3 + (r() - 0.5) * 0.5;
        var s = new THREE.SphereGeometry(1, 16, 10);
        s.scale(1.1 + r() * 0.6, 0.75 + r() * 0.35, 0.9 + r() * 0.3);
        s.translate(hx, 0.25, -29 + (r() - 0.5) * 1.2);
        s.deleteAttribute('uv');
        hedgeParts.push(s);
      }
      var hedge = new THREE.Mesh(THREE.mergeGeometries(hedgeParts), sceneMat({
        vertexShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz; vNormal = normalize(mat3(modelMatrix) * normal);',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  vec3 n = normalize(vNormal);',
          '  float leaf = ev_fbm3(vWorld.xy * 5.0 + vWorld.z);',
          '  vec3 V = normalize(cameraPosition - vWorld);',
          '  float rim = pow(1.0 - max(dot(n, V), 0.0), 3.0) * max(dot(n, uSunDir) + 0.3, 0.0);',
          '  vec3 c = vec3(0.13, 0.19, 0.11) * lightAt(n, 0.7) * (0.75 + 0.5 * leaf) + uSun * rim * 0.35;',
          '  c = applyFog(c, vWorld, 0.012);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      scene.add(hedge);

      // ---------------------------------------------------------------- raked gravel
      var gravelGeo = new THREE.PlaneGeometry(60, 36, 1, 1);
      gravelGeo.rotateX(-Math.PI / 2);
      gravelGeo.translate(0, 0, -20.3);
      var gravel = new THREE.Mesh(gravelGeo, sceneMat({
        uniforms: {
          uStones: { value: stones },
        },
        vertexShader: [
          'varying vec3 vWorld;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz;',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uStones[3];',
          'varying vec3 vWorld;',
          // rake pattern: rings around each stone, straight furrows elsewhere
          'float rake(vec2 p, out float ring) {',
          '  float best = 1e3; vec2 c = vec2(0.0);',
          '  for (int i = 0; i < 3; i++) {',
          '    float d = length(p - uStones[i].xz) - 1.0;',
          '    if (d < best) { best = d; }',
          '  }',
          '  ring = 1.0 - smoothstep(2.6, 3.4, best);',
          '  float straight = p.y;',
          '  float coord = mix(straight, best, ring);',
          '  return coord;',
          '}',
          'void main() {',
          '  vec2 p = vWorld.xz;',
          '  float ring;',
          '  float coord = rake(p, ring);',
          '  float freq = 6.0;',
          '  float w = sin(coord * freq * EV_TAU / 2.0);',
          // furrows as a height field, lit by the low sun (fake normal from the derivative)
          '  float slope = cos(coord * freq * EV_TAU / 2.0);',
          '  float lit = 0.5 + 0.4 * slope;',
          '  float fw = fwidth(coord) * freq;',
          '  lit = mix(0.5, lit, smoothstep(0.9, 0.25, fw));',
          '  float dist = length(cameraPosition - vWorld);',
          '  float fine = smoothstep(30.0, 6.0, dist);',
          '  float stoneDist = 1e3;',
          '  for (int i = 0; i < 3; i++) stoneDist = min(stoneDist, length(p - uStones[i].xz));',
          // soft contact shadow and the long shadow cast away from the sun
          '  float occ = smoothstep(0.9, 2.2, stoneDist);',
          '  float shadow = 1.0;',
          '  for (int i = 0; i < 3; i++) {',
          '    vec2 q = p - uStones[i].xz;',
          '    vec2 away = -normalize(uSunDir.xz);',
          '    float along = dot(q, away);',
          '    float across = abs(q.x * away.y - q.y * away.x);',
          '    shadow *= 1.0 - 0.55 * smoothstep(1.3, 0.6, across) * smoothstep(0.0, 0.8, along) * smoothstep(6.0, 1.5, along);',
          '  }',
          '  float grain = ev_noise(p * 40.0) * 0.5 + ev_noise(p * 9.0) * 0.5;',
          '  vec3 base = vec3(0.80, 0.77, 0.71) * (0.9 + 0.12 * grain);',
          '  vec3 n = vec3(0.0, 1.0, 0.0);',
          '  vec3 light = lightAt(n, 1.0) * mix(1.0, 0.72 + 0.5 * lit, fine * 0.9) * occ * shadow;',
          '  vec3 c = base * light * 0.95;',
          '  c = applyFog(c, vWorld, 0.01);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      scene.add(gravel);

      // ---------------------------------------------------------------- stones
      function stoneMaterial(mossAmount) { return sceneMat({
        uniforms: { uMoss: { value: mossAmount } },
        vertexShader: [
          'varying vec3 vWorld; varying vec3 vNormal; varying vec3 vLocal;',
          'void main() {',
          '  vec4 w = modelMatrix * vec4(position, 1.0);',
          '  vWorld = w.xyz; vLocal = position; vNormal = normalize(mat3(modelMatrix) * normal);',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform float uMoss; varying vec3 vWorld; varying vec3 vNormal; varying vec3 vLocal;',
          'void main() {',
          '  vec3 n = normalize(vNormal);',
          '  float g = ev_fbm(vLocal.xz * 3.0 + vLocal.y * 2.0);',
          '  vec3 rockCol = mix(vec3(0.26, 0.25, 0.24), vec3(0.42, 0.40, 0.37), g);',
          // moss on the upper faces
          '  float moss = uMoss * smoothstep(0.35, 0.75, n.y + 0.35 * (ev_fbm(vLocal.xz * 5.0) - 0.5));',
          '  vec3 base = mix(rockCol, vec3(0.20, 0.30, 0.12), moss);',
          '  float occ = smoothstep(-0.1, 0.5, vWorld.y);',
          '  vec3 c = base * lightAt(n, 0.6 + 0.4 * occ);',
          '  c = applyFog(c, vWorld, 0.01);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }); }
      var stoneMat = stoneMaterial(1.0);
      [[1.15, 0.95], [1.5, 1.1], [0.9, 1.2]].forEach(function (sz, i) {
        var m = new THREE.Mesh(rock(r, sz[0], sz[1]), stoneMat);
        m.position.copy(stones[i]);
        m.rotation.y = r() * Math.PI;
        scene.add(m);
        // a small companion stone
        var m2 = new THREE.Mesh(rock(r, sz[0] * 0.45, 0.8), stoneMat);
        m2.position.copy(stones[i]).add(new THREE.Vector3(sz[0] * 1.05, 0, sz[0] * 0.5));
        scene.add(m2);
      });

      // ---------------------------------------------------------------- pond (mirror) and its edge
      var pond = ctx.mirror({
        y: -0.1,
        size: [40, 13],
        center: [0, 4.0],
        scale: 0.4,
        uniforms: Object.assign({ uDeep: { value: ctx.color('#06100f') } }, shared),
        fragmentShader: SCENE_GLSL + '\n' + [
          'uniform vec3 uDeep;',
          'varying vec4 vMirror; varying vec3 vWorld;',
          'void main() {',
          '  vec3 toCam = cameraPosition - vWorld;',
          '  float dist = length(toCam);',
          '  vec3 V = toCam / dist;',
          '  vec2 p = vWorld.xz * vec2(1.2, 2.4);',
          '  float e = 0.05;',
          '  float h0 = ev_loopFbm3(p, vec2(0.05, 0.1), uTime);',
          '  float hx = ev_loopFbm3(p + vec2(e, 0.0), vec2(0.05, 0.1), uTime);',
          '  float hz = ev_loopFbm3(p + vec2(0.0, e), vec2(0.05, 0.1), uTime);',
          '  float amp = 0.12 * (1.0 + 2.0 * uRain);',
          '  vec2 fw = fwidth(p);',
          '  amp *= 1.0 - smoothstep(0.025, 0.11, max(fw.x, fw.y));',
          '  vec3 n = normalize(vec3(-(hx - h0) / e * amp, 1.0, -(hz - h0) / e * amp));',
          '  vec2 uv = clamp(vMirror.xy / vMirror.w + n.xz * 0.02, vec2(0.002), vec2(0.998));',
          '  vec3 refl = ev_mirror(uv);',
          '  float fres = 0.04 + 0.96 * pow(1.0 - max(dot(V, n), 0.0), 5.0);',
          '  vec3 c = mix(uDeep, refl * 0.8, clamp(fres * 0.9 + 0.05, 0.0, 0.8));',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      });
      pond.layers.set(1);
      scene.add(pond);
      // stone kerb between the pond and the gravel
      var kerbParts = [];
      for (var k = 0; k < 46; k++) {
        var kg = new THREE.SphereGeometry(1, 12, 8);
        kg.scale(0.3 + r() * 0.2, 0.1 + r() * 0.06, 0.24 + r() * 0.1);
        kg.translate(-12 + k * 0.55 + (r() - 0.5) * 0.15, -0.08, -2.3 + (r() - 0.5) * 0.2);
        kg.deleteAttribute('uv');
        kerbParts.push(kg);
      }
      var kerb = new THREE.Mesh(THREE.mergeGeometries(kerbParts), stoneMaterial(0.0));
      scene.add(kerb);

      // ---------------------------------------------------------------- cherry branch in blossom
      var pts = [
        new THREE.Vector3(-4.5, 6.4, 3.6), new THREE.Vector3(-2.8, 5.7, 3.0), new THREE.Vector3(-1.2, 5.5, 2.4),
        new THREE.Vector3(0.4, 5.75, 1.6), new THREE.Vector3(1.6, 6.3, 1.0),
      ];
      var twigs = [
        [new THREE.Vector3(-2.8, 5.7, 3.0), new THREE.Vector3(-2.2, 5.0, 2.7), new THREE.Vector3(-1.6, 4.7, 2.5)],
        [new THREE.Vector3(-1.2, 5.5, 2.4), new THREE.Vector3(-0.8, 5.0, 2.2), new THREE.Vector3(-0.2, 4.85, 2.0)],
        [new THREE.Vector3(0.4, 5.75, 1.6), new THREE.Vector3(0.9, 5.3, 1.5), new THREE.Vector3(1.5, 5.2, 1.3)],
        [new THREE.Vector3(-2.0, 5.6, 2.8), new THREE.Vector3(-1.6, 6.2, 2.6), new THREE.Vector3(-1.0, 6.5, 2.4)],
      ];
      var branchGeos = [new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 40, 0.05, 6, false)];
      twigs.forEach(function (t) { branchGeos.push(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(t), 16, 0.018, 5, false)); });
      branchGeos.forEach(function (g) { g.deleteAttribute('uv'); });
      var branchMat = sceneMat({
        vertexShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  vec3 p = position;',
          // the branch sways gently (loops twice a period)
          '  float sway = 0.03 * ev_wave(2.0, 0.1, uTime) * smoothstep(-4.5, 1.5, p.x);',
          '  p.y += sway; p.x += sway * 0.4;',
          '  vec4 w = modelMatrix * vec4(p, 1.0);',
          '  vWorld = w.xyz; vNormal = normalize(mat3(modelMatrix) * normal);',
          '  gl_Position = projectionMatrix * viewMatrix * w;',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying vec3 vWorld; varying vec3 vNormal;',
          'void main() {',
          '  vec3 n = normalize(vNormal);',
          '  vec3 V = normalize(cameraPosition - vWorld);',
          '  float rim = pow(1.0 - max(dot(n, V), 0.0), 2.5) * max(dot(n, uSunDir) + 0.2, 0.0);',
          '  vec3 c = vec3(0.12, 0.095, 0.09) + uSun * rim * 0.45;',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      });
      var branch = new THREE.Mesh(THREE.mergeGeometries(branchGeos), branchMat);
      branch.frustumCulled = false;
      scene.add(branch);
      // blossoms: soft discs clustered along the branch and its twigs, glowing against the light
      var bpos = [], ba = [];
      var curves = [new THREE.CatmullRomCurve3(pts)].concat(twigs.map(function (t) { return new THREE.CatmullRomCurve3(t); }));
      for (var b = 0; b < 420; b++) {
        var cv = curves[b % 5 === 0 ? 0 : 1 + (b % 4)];
        var u = 0.25 + r() * 0.75;
        var c0 = cv.getPoint(u);
        var off = new THREE.Vector3(r() - 0.5, r() - 0.35, r() - 0.5).multiplyScalar(0.42);
        bpos.push(c0.x + off.x, c0.y + off.y, c0.z + off.z);
        ba.push(r(), r(), 0.07 + r() * 0.09, r());
      }
      var bg = new THREE.BufferGeometry();
      bg.setAttribute('position', new THREE.Float32BufferAttribute(bpos, 3));
      bg.setAttribute('aA', new THREE.Float32BufferAttribute(ba, 4));
      var blossoms = new THREE.Points(bg, sceneMat({
        transparent: true,
        depthWrite: false,
        vertexShader: [
          'attribute vec4 aA;',
          'varying float vShade; varying float vTone; varying float vBlur;',
          'void main() {',
          '  vec3 p = position;',
          '  float sway = 0.03 * ev_wave(2.0, 0.1, uTime) * smoothstep(-4.5, 1.5, p.x);',
          '  p.y += sway; p.x += sway * 0.4;',
          '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
          '  gl_Position = projectionMatrix * mv;',
          '  vShade = aA.x; vTone = aA.y; vBlur = aA.w;',
          '  gl_PointSize = min(aA.z * uFocal / -mv.z, 80.0 * uPixelRatio);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'varying float vShade; varying float vTone; varying float vBlur;',
          'void main() {',
          '  vec2 d = gl_PointCoord - 0.5;',
          '  float r = length(d) * 2.0;',
          // soft, slightly out-of-focus blossoms glowing against the light
          '  float soft = mix(0.25, 0.7, vBlur);',
          '  float petal = 0.92 + 0.08 * cos(atan(d.y, d.x) * 5.0 + vTone * 6.0) * (1.0 - vBlur);',
          '  float a = 1.0 - smoothstep(petal - soft, petal, r);',
          '  if (a < 0.02) discard;',
          '  vec3 pink = mix(vec3(0.97, 0.80, 0.85), vec3(1.0, 0.93, 0.94), vTone);',
          '  vec3 c = pink * (0.62 + 0.38 * vShade) * mix(vec3(0.8, 0.74, 0.78), uSun, 0.5);',
          '  c = mix(c * 0.85, c * 1.08, smoothstep(0.0, 0.6, r));',
          '  gl_FragColor = vec4(ev_dither(c), a * mix(0.92, 0.55, vBlur));',
          '}',
        ].join('\n'),
      }));
      blossoms.frustumCulled = false;
      blossoms.renderOrder = 5;
      scene.add(blossoms);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var decors = {
        petales: D.petales(ctx, {
          count: 160, box: { min: [-5.5, -0.3, -9], max: [5.5, 6.5, 7.5] }, size: [0.04, 0.065],
          colors: ['#f4c6d2', '#f8dbe3', '#fff0f3'], lightDir: [sunDir.x, sunDir.y, sunDir.z], light: '#ffe2c0', ambient: '#8a8090',
          fog: '#f1d9b8', fogDensity: 0.01,
        }),
        'rayons-soleil': D['rayons-soleil'](ctx, {
          origin: [15, 31, -40], toward: [-4, 0, -12], spread: 0.3, count: 9, length: 52,
          width: [0.9, 3.2], color: '#ffd49c', intensity: 0.6, falloff: 0.7, motes: 150, moteColor: '#fff3da', moteSize: 0.028,
          spreadAxis: [0, 0, 1],
        }),
        brume: D.brume(ctx, {
          color: '#efe0cc',
          layers: [
            { y: 2.5, z: -60, width: 160, height: 12, opacity: 0.55, scale: 0.06, drift: 0.08, rank: 0.0 },
            { y: 0.9, z: -32, width: 80, height: 5, opacity: 0.45, scale: 0.12, drift: -0.05, rank: 0.15 },
            { y: 0.25, z: -1, width: 40, height: 2.2, opacity: 0.35, scale: 0.3, drift: 0.04, rank: 0.35, color: '#d8d2c8' },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
        pluie: D.pluie(ctx, {
          count: 1100, box: { min: [-8, -0.5, -18], max: [8, 9, 8] }, speed: [7, 9.5], color: '#e6e2dc',
          opacity: 0.32, wind: [0.04, 0.0],
          onLevel: null,
        }),
      };
      // rain greys the light a little
      var rainSet = decors.pluie.setLevel;
      decors.pluie.setLevel = function (v) { rainSet(v); shared.uRain.value = v; };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });
      decors.pluie.object.layers.set(1);
      decors['rayons-soleil'].object.traverse(function (o) { o.layers.set(1); });

      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.35 * Math.sin(T), 1.75 + 0.04 * Math.sin(2 * T), 10 + 0.25 * Math.cos(T));
        camera.lookAt(0.5 * Math.sin(T + 0.4), 1.9, -20);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
