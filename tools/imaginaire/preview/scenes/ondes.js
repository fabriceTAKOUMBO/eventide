/*
 * « Ondes lumineuses » (abstract, hypnotic): a dark infinite plane made of points of light,
 * crossed by slow concentric waves from three drifting sources; a pulse of light leaves the
 * centre three times a period; a soft glow on the horizon. With the rain decor, every drop
 * opens a ring on the field.
 */
(function () {
  'use strict';
  var E = window.EventideImaginaire;
  var THREE = E.THREE;

  E.register({
    id: 'ondes',
    decors: ['etoiles', 'brume', 'pluie'],
    defaults: { etoiles: 40 },

    build: function (ctx) {
      var scene = ctx.scene, camera = ctx.camera;
      camera.fov = 55;
      camera.near = 0.1;
      camera.far = 2000;

      var shared = {
        uMist: { value: 0 },
        uRain: { value: 0 },
        uTeal: { value: ctx.color('#3fd6d2') },
        uViolet: { value: ctx.color('#8b6dff') },
        uRose: { value: ctx.color('#ff8fc8') },
      };
      function mat(params) {
        params.uniforms = Object.assign({}, shared, params.uniforms || {});
        return ctx.material(params);
      }

      // ---------------------------------------------------------------- the void and its horizon glow
      var sky = new THREE.Mesh(new THREE.SphereGeometry(1500, 32, 16), mat({
        side: THREE.BackSide,
        depthWrite: false,
        uniforms: { uTop: { value: ctx.color('#03040d') }, uLow: { value: ctx.color('#0d1030') } },
        vertexShader: [
          'varying vec3 vDir;',
          'void main() { vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uTop; uniform vec3 uLow; uniform vec3 uTeal; uniform vec3 uViolet; uniform float uMist;',
          'varying vec3 vDir;',
          'void main() {',
          '  vec3 d = normalize(vDir);',
          '  vec3 c = mix(uLow, uTop, smoothstep(-0.05, 0.5, d.y));',
          '  float band = exp(-abs(d.y - 0.01) * 24.0);',
          '  float breathe = 0.85 + 0.15 * ev_wave(1.0, 0.0, uTime);',
          '  c += mix(uViolet, uTeal, 0.5 + 0.5 * d.x) * band * 0.22 * breathe * (1.0 + 0.6 * uMist);',
          '  gl_FragColor = vec4(ev_dither(c), 1.0);',
          '}',
        ].join('\n'),
      }));
      sky.renderOrder = -10;
      sky.frustumCulled = false;
      scene.add(sky);

      // ---------------------------------------------------------------- the field of light
      var NX = ctx.quality === 'low' ? 150 : 210, NZ = ctx.quality === 'low' ? 110 : 150;
      var pos = [];
      var jr = ctx.rng('field');
      for (var iz = 0; iz < NZ; iz++) {
        // rows closer together near the viewer, spreading with distance (even on screen)
        var v = iz / (NZ - 1);
        var z = 9 - 4 * Math.pow(160, v) + 4;
        for (var ix = 0; ix < NX; ix++) {
          var u = ix / (NX - 1);
          var half = 6 + (9 - z) * 0.75;
          var dz = 4 * Math.pow(160, v) * Math.log(160) / (NZ - 1);
          pos.push((u * 2 - 1) * half + (jr() - 0.5) * (2 * half / NX) * 0.9, 0, z + (jr() - 0.5) * dz * 0.9);
        }
      }
      var g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      var field = new THREE.Points(g, mat({
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
        vertexShader: [
          'uniform float uRain;',
          'varying float vGlow; varying float vHue; varying float vNear;',
          // three sources drifting on closed paths; whole turns per period keep the loop exact
          'float waves(vec2 p, float t) {',
          '  float T = EV_TAU * t / EV_PERIOD;',
          '  vec2 s1 = vec2(-6.0 + 2.0 * sin(T), -26.0 + 3.0 * cos(T));',
          '  vec2 s2 = vec2(8.0 + 2.5 * cos(T + 1.0), -40.0 + 4.0 * sin(T));',
          '  vec2 s3 = vec2(-2.0 + 3.0 * sin(2.0 * T + 2.0), -70.0);',
          '  float h = 0.0;',
          '  h += 0.42 * sin(length(p - s1) * 0.55 - 4.0 * T);',
          '  h += 0.36 * sin(length(p - s2) * 0.42 - 3.0 * T + 1.3);',
          '  h += 0.30 * sin(length(p - s3) * 0.33 - 2.0 * T + 2.1);',
          '  h += 0.25 * sin(p.x * 0.12 + p.y * 0.05 + T);',
          '  return h;',
          '}',
          // the pulse: a ring of light leaving the centre three times a period
          'float pulse(vec2 p, float t) {',
          '  float ph = fract(3.0 * t / EV_PERIOD);',
          '  float r = ph * 70.0;',
          '  float d = length((p - vec2(0.0, -30.0)) * vec2(1.0, 1.0)) - r;',
          '  return exp(-d * d * 0.12) * (1.0 - ph);',
          '}',
          // rain: drops at fixed times and places open small rings
          'float drops(vec2 p, float t) {',
          '  float s = 0.0;',
          '  for (int j = 0; j < 14; j++) {',
          '    float fj = float(j);',
          '    float t0 = fj * EV_PERIOD / 14.0 + 1.3 * ev_hash12(vec2(fj, 1.0));',
          '    float age = mod(t - t0, EV_PERIOD);',
          '    if (age > 3.5) continue;',
          '    vec2 c = vec2((ev_hash12(vec2(fj, 2.0)) - 0.5) * 18.0, -4.0 - ev_hash12(vec2(fj, 3.0)) * 34.0);',
          '    float d = length(p - c) - age * 2.2;',
          '    s += exp(-d * d * 3.0) * (1.0 - age / 3.5);',
          '  }',
          '  return s;',
          '}',
          'void main() {',
          '  vec3 p = position;',
          '  float h = waves(p.xz, uTime);',
          '  float pu = pulse(p.xz, uTime);',
          '  float dr = uRain > 0.001 ? drops(p.xz, uTime) * uRain : 0.0;',
          '  p.y = h * 0.85 + pu * 0.7 + dr * 0.3 - 1.8;',
          '  vec4 mv = modelViewMatrix * vec4(p, 1.0);',
          '  gl_Position = projectionMatrix * mv;',
          '  float dist = -mv.z;',
          '  float crest = smoothstep(-0.2, 1.1, h);',
          '  vGlow = (0.14 + 1.5 * crest * crest + 1.8 * pu + 1.2 * dr) * smoothstep(2.0, 16.0, dist) * exp(-dist * 0.009);',
          '  vHue = clamp(0.5 - 0.42 * h + p.x / 70.0 + 0.6 * pu, 0.0, 1.0);',
          '  vNear = smoothstep(16.0, 4.0, dist);',
          '  gl_PointSize = clamp((0.075 + 0.085 * crest + 0.06 * pu) * uFocal / dist, 1.2, 34.0 * uPixelRatio);',
          '}',
        ].join('\n'),
        fragmentShader: [
          'uniform vec3 uTeal; uniform vec3 uViolet; uniform vec3 uRose;',
          'varying float vGlow; varying float vHue; varying float vNear;',
          'void main() {',
          '  vec2 d = gl_PointCoord - 0.5;',
          '  float r2 = dot(d, d) * 4.0;',
          '  float a = exp(-r2 * 4.0) + 0.25 * exp(-r2 * 1.2);',
          '  vec3 c = mix(uTeal, uViolet, vHue);',
          '  c = mix(c, uRose, smoothstep(0.75, 1.0, vHue) * 0.6);',
          '  c = mix(c, vec3(1.0), smoothstep(0.7, 1.4, vGlow) * 0.5);',
          '  gl_FragColor = vec4(c * a * vGlow * 1.25 * (1.0 - 0.5 * vNear), 1.0);',
          '}',
        ].join('\n'),
      }));
      field.frustumCulled = false;
      field.renderOrder = 2;
      scene.add(field);

      // ---------------------------------------------------------------- decor
      var D = ctx.decors;
      var decors = {
        etoiles: D.etoiles(ctx, {
          count: 1200, radius: 1200, azimuth: [0, 46], elevation: [4, 85], size: 0.95,
          tint: ['#bcd8ff', '#e9d6ff'], band: { normal: [0.4, 0.5, 0.75], width: 0.12, count: 900 },
        }),
        brume: D.brume(ctx, {
          color: '#4a4a8a',
          layers: [
            { y: -1.0, z: -90, width: 300, height: 14, opacity: 0.4, scale: 0.04, drift: 0.2, rank: 0.0, top: 0.6 },
            { y: -1.4, z: -40, width: 140, height: 6, opacity: 0.32, scale: 0.08, drift: -0.1, rank: 0.2, top: 0.5, color: '#3c5a8a' },
          ],
          onLevel: function (v) { shared.uMist.value = v; },
        }),
        pluie: D.pluie(ctx, {
          count: 900, box: { min: [-9, -1.8, -40], max: [9, 9, 6] }, speed: [7, 9.5], color: '#9fb6ff',
          opacity: 0.4, wind: [0.0, 0.0],
        }),
      };
      var rainSet = decors.pluie.setLevel;
      decors.pluie.setLevel = function (v) { rainSet(v); shared.uRain.value = v; };
      Object.keys(decors).forEach(function (id) { scene.add(decors[id].object); });

      function update(t) {
        var T = (t / ctx.PERIOD) * ctx.TAU;
        camera.position.set(0.8 * Math.sin(T), 1.2 + 0.08 * Math.sin(2 * T), 8 + 0.4 * Math.cos(T));
        camera.lookAt(0.6 * Math.sin(T + 0.6), 0.4, -40);
      }
      update(0);
      return { decors: decors, update: update };
    },
  });
})();
