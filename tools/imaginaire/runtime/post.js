/*
 * Eventide « Imaginaire »: HDR finish shared by the scenes that ask for it (`post: true` in the
 * scene definition; see docs/app/architecture.md § 20).
 *
 *   scene ──> HDR target (half float, MSAA 4× in 'high') ──> bloom (half resolution, 5 levels,
 *   'high' only) ──> ONE composite pass to the screen: exposure, tone mapping (ACES or Khronos
 *   Neutral), bloom, light rays (a short radial blur toward the light's position on screen of the
 *   quarter-resolution bloom level, near the light only: the gaps between the trees cast rays), slight chromatic
 *   aberration, vignette, film grain ('high' only), dither.
 *
 * Safety: a pixel of the HDR target that is not a finite, non-negative number (NaN or Inf made by a
 * shader on some mobile GPU, e.g. pow() of a base rounded below 0) or that exceeds 2^14 is replaced
 * (0, or the cap) before any filtering, in the bloom prefilter and in the composite: one bad pixel
 * can never spread through the bloom levels into blocks (seen on a Galaxy S24, Xclipse 940).
 *
 * The grain is a pure function of the scene time (one pattern per 1/24 s, modulo the period), so
 * the image stays a pure function of t and the 30 s period still loops without a seam.
 *
 *   var post = EventidePost.create(ctx, {exposure, toneMapping: 'aces'|'neutral',
 *     bloom: {strength, threshold, knee, radius}, rays: {strength, length, decay, radius},
 *     aberration, vignette, grain, samples: MSAA samples in 'high' (4)});
 *   post.setLight(x, y)   the light's position on screen (0..1, may lie outside), before render
 *   post.render(scene, camera);   post.setQuality('low'|'high');   post.describe();   post.dispose();
 */
(function () {
  'use strict';

  var THREE = window.THREE;
  var LEVELS = 5;   // bloom: 1/2, 1/4, 1/8, 1/16, 1/32 of the buffer
  var RAY_SAMPLES = 12;

  // NaN, Inf and negatives become 0, the rest is capped (a select, never arithmetic on NaN)
  var SAFE = [
    'float ev_safe1(float x) { return (isnan(x) || isinf(x) || !(x >= 0.0)) ? 0.0 : min(x, 16384.0); }',
    'vec3 ev_safe(vec3 c) { return vec3(ev_safe1(c.r), ev_safe1(c.g), ev_safe1(c.b)); }',
  ].join('\n');

  var VERTEX = [
    'varying vec2 vUv;',
    'void main() {',
    '  vUv = position.xy * 0.5 + 0.5;',
    '  gl_Position = vec4(position.xy, 0.0, 1.0);',
    '}',
  ].join('\n');

  // Threshold with a soft knee, on four bilinear taps covering 4x4 source texels, averaged with
  // Karis weights (1 / (1 + luma)): a lone bright pixel cannot make the bloom flicker.
  var PREFILTER = [
    SAFE,
    'uniform sampler2D tSrc; uniform vec2 uTexel; uniform vec2 uCurve;',
    'varying vec2 vUv;',
    'vec3 knee(vec3 c) {',
    '  float br = max(c.r, max(c.g, c.b));',
    '  float soft = clamp(br - uCurve.x + uCurve.y, 0.0, 2.0 * uCurve.y);',
    '  soft = soft * soft / (4.0 * uCurve.y + 1e-5);',
    '  return c * (max(soft, br - uCurve.x) / max(br, 1e-5));',
    '}',
    'vec4 tap(vec2 o) {',
    '  vec3 c = knee(ev_safe(texture2D(tSrc, vUv + o * uTexel).rgb));',
    '  return vec4(c, 1.0) / (1.0 + dot(c, vec3(0.2126, 0.7152, 0.0722)));',
    '}',
    'void main() {',
    '  vec4 s = tap(vec2(-1.0, -1.0)) + tap(vec2(1.0, -1.0)) + tap(vec2(-1.0, 1.0)) + tap(vec2(1.0, 1.0));',
    '  gl_FragColor = vec4(s.rgb / s.a, 1.0);',
    '}',
  ].join('\n');

  // Dual-filter downsample (5 taps).
  var DOWN = [
    'uniform sampler2D tSrc; uniform vec2 uTexel;',
    'varying vec2 vUv;',
    'void main() {',
    '  vec3 s = texture2D(tSrc, vUv).rgb * 4.0;',
    '  s += texture2D(tSrc, vUv + vec2(-1.0, -1.0) * uTexel).rgb;',
    '  s += texture2D(tSrc, vUv + vec2(1.0, -1.0) * uTexel).rgb;',
    '  s += texture2D(tSrc, vUv + vec2(-1.0, 1.0) * uTexel).rgb;',
    '  s += texture2D(tSrc, vUv + vec2(1.0, 1.0) * uTexel).rgb;',
    '  gl_FragColor = vec4(s * 0.125, 1.0);',
    '}',
  ].join('\n');

  // 3x3 tent upsample of the smaller level, added to this level.
  var UP = [
    'uniform sampler2D tSrc; uniform sampler2D tAdd; uniform vec2 uTexel; uniform float uRadius;',
    'varying vec2 vUv;',
    'vec3 t(float x, float y) { return texture2D(tSrc, vUv + vec2(x, y) * uTexel * uRadius).rgb; }',
    'void main() {',
    '  vec3 s = t(0.0, 0.0) * 4.0;',
    '  s += (t(-1.0, 0.0) + t(1.0, 0.0) + t(0.0, -1.0) + t(0.0, 1.0)) * 2.0;',
    '  s += t(-1.0, -1.0) + t(1.0, -1.0) + t(-1.0, 1.0) + t(1.0, 1.0);',
    '  gl_FragColor = vec4(texture2D(tAdd, vUv).rgb + s * 0.0625, 1.0);',
    '}',
  ].join('\n');

  var COMPOSITE = [
    SAFE,
    'uniform sampler2D tScene; uniform sampler2D tBloom; uniform sampler2D tRays;',
    'uniform float uExposure; uniform float uBloom; uniform float uAberration; uniform float uVignette;',
    'uniform float uGrain; uniform float uFrame; uniform vec2 uAspect;',
    'uniform vec2 uLightPos; uniform vec4 uRays;',   // strength, length (fraction of the way), decay, source radius
    'varying vec2 vUv;',
    'float hash(vec2 p) {',
    '  vec3 p3 = fract(vec3(p.xyx) * 0.1031);',
    '  p3 += dot(p3, p3.yzx + 33.33);',
    '  return fract((p3.x + p3.y) * p3.z);',
    '}',
    // ACES filmic (fit by S. Hill, as three.js), and the Khronos PBR Neutral curve.
    'vec3 acesFit(vec3 c) {',
    '  const mat3 inM = mat3(vec3(0.59719, 0.07600, 0.02840), vec3(0.35458, 0.90834, 0.13383), vec3(0.04823, 0.01566, 0.83777));',
    '  const mat3 outM = mat3(vec3(1.60475, -0.10208, -0.00327), vec3(-0.53108, 1.10813, -0.07276), vec3(-0.07367, -0.00605, 1.07602));',
    '  c = inM * (c / 0.6);',
    '  vec3 a = c * (c + 0.0245786) - 0.000090537;',
    '  vec3 b = c * (0.983729 * c + 0.4329510) + 0.238081;',
    '  return clamp(outM * (a / b), 0.0, 1.0);',
    '}',
    'vec3 neutral(vec3 c) {',
    '  float x = min(c.r, min(c.g, c.b));',
    '  float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;',
    '  c -= offset;',
    '  float peak = max(c.r, max(c.g, c.b));',
    '  if (peak < 0.76) return c;',
    '  float d = 0.24;',
    '  float np = 1.0 - d * d / (peak + d - 0.76);',
    '  c *= np / peak;',
    '  float g = 1.0 - 1.0 / (0.15 * (peak - np) + 1.0);',
    '  return mix(c, vec3(np), g);',
    '}',
    'vec3 toSRGB(vec3 c) {',
    '  c = clamp(c, 0.0, 1.0);',
    '  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));',
    '}',
    'void main() {',
    '  vec2 d = vUv - 0.5;',
    '#ifdef EV_ABERRATION',
    // lateral colour fringe growing with the square of the distance to the centre
    '  vec2 off = d * dot(d * uAspect, d * uAspect) * uAberration;',
    '  vec3 col = vec3(texture2D(tScene, vUv - off).r, texture2D(tScene, vUv).g, texture2D(tScene, vUv + off).b);',
    '#else',
    '  vec3 col = texture2D(tScene, vUv).rgb;',
    '#endif',
    '  col = ev_safe(col);',
    '#ifdef EV_BLOOM',
    '  col += texture2D(tBloom, vUv).rgb * uBloom;',
    '#endif',
    '#ifdef EV_RAYS',
    // march toward the light over the bright parts (quarter resolution): rays through the gaps;
    // a static per-pixel offset of the first tap hides the steps
    '  vec2 rayStep = (uLightPos - vUv) * uRays.y / float(EV_RAYS);',
    '  vec2 rp = vUv + rayStep * hash(gl_FragCoord.xy * 0.73);',
    '  vec3 rays = vec3(0.0); float rw = 1.0;',
    '  for (int i = 0; i < EV_RAYS; i++) {',
    // only what shines near the light casts rays (not the fireflies elsewhere on screen)
    '    vec2 dl = (rp - uLightPos) * uAspect;',
    '    rays += texture2D(tRays, rp).rgb * rw * (1.0 - smoothstep(0.0, uRays.w, length(dl)));',
    '    rw *= uRays.z; rp += rayStep;',
    '  }',
    '  col += rays * uRays.x / float(EV_RAYS);',
    '#endif',
    '  col = ev_safe(col) * uExposure;',
    '#ifdef EV_NEUTRAL',
    '  col = neutral(col);',
    '#else',
    '  col = acesFit(col);',
    '#endif',
    '  float r = length(d * 2.0) * 0.7071;',
    '  col *= 1.0 - uVignette * smoothstep(0.35, 1.05, r);',
    '  vec3 o = toSRGB(col);',
    '#ifdef EV_GRAIN',
    // film grain: one pattern per 1/24 s of scene time, strongest in the mid-tones
    '  vec2 seed = gl_FragCoord.xy + vec2(mod(uFrame * 37.0, 911.0), mod(uFrame * 71.0, 643.0));',
    '  float g = hash(seed) + hash(seed + 113.7) - 1.0;',
    '  float l = dot(o, vec3(0.299, 0.587, 0.114));',
    '  o += g * uGrain * (0.3 + 2.8 * l * (1.0 - l));',
    '#endif',
    '  o += (hash(gl_FragCoord.xy * 1.37 + 0.5) - 0.5) / 255.0;',
    '  gl_FragColor = vec4(o, 1.0);',
    '}',
  ].join('\n');

  function create(ctx, opts) {
    opts = opts || {};
    var bloomOpts = Object.assign({ strength: 0.08, threshold: 1.0, knee: 0.6, radius: 1.0 }, opts.bloom || {});
    var rayOpts = opts.rays ? Object.assign({ strength: 0.5, length: 0.6, decay: 0.95, radius: 0.35 }, opts.rays) : null;
    var renderer = ctx.renderer;
    var floatOk = renderer.extensions.has('EXT_color_buffer_float') || renderer.extensions.has('EXT_color_buffer_half_float');
    var type = floatOk ? THREE.HalfFloatType : THREE.UnsignedByteType;
    var maxSamples = renderer.capabilities.maxSamples || 0;
    var quality = ctx.quality;
    var size = { w: 2, h: 2 };

    function target(samples, depth) {
      var rt = new THREE.WebGLRenderTarget(2, 2, {
        type: type, format: THREE.RGBAFormat, depthBuffer: !!depth, stencilBuffer: false, samples: samples,
        minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter, generateMipmaps: false,
        wrapS: THREE.ClampToEdgeWrapping, wrapT: THREE.ClampToEdgeWrapping,
      });
      rt.texture.generateMipmaps = false;
      return rt;
    }

    var hdr = null;
    var down = [], up = [];
    function samplesFor(q) { return q === 'high' ? Math.min(opts.samples || 4, maxSamples) : 0; }
    function bloomOn() { return quality === 'high' && bloomOpts.strength > 0; }

    function makeTargets() {
      if (hdr) hdr.dispose();
      hdr = target(samplesFor(quality), true);
      down.forEach(function (t) { t.dispose(); });
      up.forEach(function (t) { t.dispose(); });
      down = []; up = [];
      if (bloomOn()) {
        for (var i = 0; i < LEVELS; i++) down.push(target(0, false));
        for (var j = 0; j < LEVELS - 1; j++) up.push(target(0, false));
      }
    }

    function levelSize(i) {
      var f = Math.pow(2, i + 1);
      return { w: Math.max(1, Math.round(size.w / f)), h: Math.max(1, Math.round(size.h / f)) };
    }

    function resize(w, h) {
      size.w = w; size.h = h;
      hdr.setSize(w, h);
      for (var i = 0; i < down.length; i++) {
        var s = levelSize(i);
        down[i].setSize(s.w, s.h);
        if (i < up.length) up[i].setSize(s.w, s.h);
      }
      composite.uniforms.uAspect.value.set(w / Math.max(w, h), h / Math.max(w, h));
    }

    function mat(fragment, uniforms, defines) {
      return new THREE.ShaderMaterial({
        uniforms: uniforms, defines: defines || {}, vertexShader: VERTEX, fragmentShader: fragment,
        depthTest: false, depthWrite: false, transparent: false,
      });
    }

    var prefilter = mat(PREFILTER, {
      tSrc: { value: null }, uTexel: { value: new THREE.Vector2() },
      uCurve: { value: new THREE.Vector2(bloomOpts.threshold, bloomOpts.knee) },
    });
    var downMat = mat(DOWN, { tSrc: { value: null }, uTexel: { value: new THREE.Vector2() } });
    var upMat = mat(UP, {
      tSrc: { value: null }, tAdd: { value: null }, uTexel: { value: new THREE.Vector2() }, uRadius: { value: bloomOpts.radius },
    });
    var compositeUniforms = {
      tScene: { value: null }, tBloom: { value: null },
      uExposure: { value: opts.exposure !== undefined ? opts.exposure : 1.0 },
      uBloom: { value: bloomOpts.strength / LEVELS },
      uAberration: { value: opts.aberration !== undefined ? opts.aberration : 0.004 },
      uVignette: { value: opts.vignette !== undefined ? opts.vignette : 0.35 },
      uGrain: { value: opts.grain !== undefined ? opts.grain : 0.02 },
      uFrame: { value: 0 },
      uAspect: { value: new THREE.Vector2(1, 1) },
      tRays: { value: null },
      uLightPos: { value: new THREE.Vector2(0.5, 0.8) },
      uRays: { value: rayOpts ? new THREE.Vector4(rayOpts.strength, rayOpts.length, rayOpts.decay, rayOpts.radius) : new THREE.Vector4() },
    };
    var composite = null;
    function makeComposite() {
      if (composite) composite.dispose();
      var defines = {};
      if (opts.toneMapping === 'neutral') defines.EV_NEUTRAL = 1;
      if (quality === 'high') {
        if (bloomOn()) defines.EV_BLOOM = 1;
        if (bloomOn() && rayOpts) defines.EV_RAYS = RAY_SAMPLES;
        if (compositeUniforms.uAberration.value > 0) defines.EV_ABERRATION = 1;
        if (compositeUniforms.uGrain.value > 0) defines.EV_GRAIN = 1;
      }
      composite = mat(COMPOSITE, compositeUniforms, defines);
    }

    var quadScene = new THREE.Scene();
    var quadCamera = new THREE.PerspectiveCamera();
    var triangle = new THREE.BufferGeometry();
    triangle.setAttribute('position', new THREE.Float32BufferAttribute([-1, -1, 0, 3, -1, 0, -1, 3, 0], 3));
    var quad = new THREE.Mesh(triangle, prefilter);
    quad.frustumCulled = false;
    quadScene.add(quad);

    function pass(material, rt) {
      quad.material = material;
      renderer.setRenderTarget(rt);
      renderer.render(quadScene, quadCamera);
    }

    function texel(rt) {
      return new THREE.Vector2(1 / rt.width, 1 / rt.height);
    }

    makeTargets();
    makeComposite();
    ctx.onResize(resize);

    var api = {
      floatTargets: floatOk,

      render: function (scene, camera) {
        var autoClear = renderer.autoClear;
        renderer.autoClear = true;
        renderer.setRenderTarget(hdr);
        renderer.render(scene, camera);
        renderer.autoClear = false;
        if (bloomOn()) {
          prefilter.uniforms.tSrc.value = hdr.texture;
          prefilter.uniforms.uTexel.value.copy(texel(hdr));
          pass(prefilter, down[0]);
          for (var i = 1; i < LEVELS; i++) {
            downMat.uniforms.tSrc.value = down[i - 1].texture;
            downMat.uniforms.uTexel.value.copy(texel(down[i - 1]));
            pass(downMat, down[i]);
          }
          for (var j = LEVELS - 2; j >= 0; j--) {
            var src = j === LEVELS - 2 ? down[LEVELS - 1] : up[j + 1];
            upMat.uniforms.tSrc.value = src.texture;
            upMat.uniforms.tAdd.value = down[j].texture;
            upMat.uniforms.uTexel.value.copy(texel(src));
            pass(upMat, up[j]);
          }
          compositeUniforms.tBloom.value = up[0].texture;
          compositeUniforms.tRays.value = up[1].texture;
        }
        compositeUniforms.tScene.value = hdr.texture;
        compositeUniforms.uFrame.value = Math.floor(ctx.uniforms.uTime.value * 24 + 1e-4) % 720;
        pass(composite, null);
        renderer.autoClear = autoClear;
      },

      setLight: function (x, y) {
        compositeUniforms.uLightPos.value.set(x, y);
      },

      setQuality: function (q) {
        q = q === 'low' ? 'low' : 'high';
        if (q === quality) return;
        quality = q;
        makeTargets();
        makeComposite();
        resize(size.w, size.h);
      },

      // Tools only: the render targets and their memory.
      describe: function () {
        var bpp = floatOk ? 8 : 4;
        var list = [{ name: 'hdr', w: hdr.width, h: hdr.height, samples: hdr.samples, bytes: hdr.width * hdr.height * (bpp + 4) * Math.max(1, hdr.samples) + (hdr.samples ? hdr.width * hdr.height * bpp : 0) }];
        down.forEach(function (t, i) { list.push({ name: 'bloom-down-' + i, w: t.width, h: t.height, samples: 0, bytes: t.width * t.height * bpp }); });
        up.forEach(function (t, i) { list.push({ name: 'bloom-up-' + i, w: t.width, h: t.height, samples: 0, bytes: t.width * t.height * bpp }); });
        return {
          type: floatOk ? 'half-float' : 'rgba8', quality: quality, bloom: bloomOn(),
          passes: 1 + (bloomOn() ? 1 + (LEVELS - 1) * 2 : 0),
          rays: bloomOn() && rayOpts ? RAY_SAMPLES : 0,
          targets: list,
          bytes: list.reduce(function (s, t) { return s + t.bytes; }, 0),
        };
      },

      uniforms: compositeUniforms,

      // Tools only (tools/imaginaire/check.js scans it for NaN, Inf and overflow): the HDR target.
      hdrTarget: function () { return hdr; },

      dispose: function () {
        hdr.dispose();
        down.concat(up).forEach(function (t) { t.dispose(); });
        [prefilter, downMat, upMat, composite].forEach(function (m) { m.dispose(); });
        triangle.dispose();
      },
    };
    // tools only: the finish of the running scene
    window.EventidePost.last = api;
    return api;
  }

  window.EventidePost = { create: create, LEVELS: LEVELS, last: null };
})();
