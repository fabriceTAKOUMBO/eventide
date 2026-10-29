/*
 * Eventide « Imaginaire » runtime: hosts one 3D scene (three.js) in a WebView.
 *
 * API on window.eventide (contract: docs/api/contrat-v1.md § 12, docs/app/architecture.md
 * « Paysages imaginaires (3D) »):
 *   start(sceneId, {decor: {id: 0..100}, moment, quality: 'low'|'high', fps: 30}) -> Promise
 *   setDecor(id, level)   level 0..100, eased over ~1 s; 0 removes; ids the scene lacks are ignored
 *   setMoment(m)          'aube'|'jour'|'soir'|'nuit' (scenes may ignore it)
 *   setPaused(bool)       true stops the render loop entirely
 *   setQuality(q)         'low'|'high' (pixel ratio, particle density)
 *   dispose()
 * Messages to the app: JavaScript channel `EventideScene` ({"type":"ready"} after the first
 * frame, {"type":"error","detail":...}, {"type":"stats","fps":n,"ms":n} every 10 s); console
 * when the channel is absent (desktop browser).
 *
 * Time: the image is a pure function of t modulo PERIOD (30 s), so one period loops without
 * a seam. Recording mode (offline renders, tools/imaginaire/render.js):
 *   index.html?record=1&scene=<id>&t=<s>&w=<px>&h=<px>&decor=<json>
 * renders exactly one frame at time t, then sets window.eventideFrameReady = true;
 * window.eventideRenderAt(t[, decor]) renders another frame of the same scene (same flag).
 */
(function () {
  'use strict';

  var THREE = window.THREE;
  var PERIOD = 30;
  var TAU = Math.PI * 2;
  var DECOR_EASE_S = 1.0;
  var STATS_EVERY_MS = 10000;
  var MAX_PIXEL_RATIO = { low: 1.0, high: 1.5 };
  var DENSITY = { low: 0.6, high: 1.0 };

  if (THREE && THREE.ColorManagement) THREE.ColorManagement.enabled = false;

  // ---------------------------------------------------------------- messages to the app
  function post(message) {
    var text = JSON.stringify(message);
    try {
      if (window.EventideScene && typeof window.EventideScene.postMessage === 'function') {
        window.EventideScene.postMessage(text);
        return;
      }
    } catch (e) { /* fall through to the console */ }
    if (message.type === 'error') console.error('[EventideScene]', text);
    else console.log('[EventideScene]', text);
  }

  function errorDetail(e) {
    if (!e) return 'unknown';
    if (typeof e === 'string') return e;
    return String(e.message || e) + (e.stack ? ' | ' + String(e.stack).split('\n').slice(0, 3).join(' | ') : '');
  }

  window.addEventListener('error', function (event) {
    post({ type: 'error', detail: errorDetail(event.error || event.message) });
  });
  window.addEventListener('unhandledrejection', function (event) {
    post({ type: 'error', detail: errorDetail(event.reason) });
  });

  // ---------------------------------------------------------------- shared GLSL
  // Every shader is written in display (sRGB) values: colour management is off and the
  // renderer outputs what the shaders write.
  var GLSL = {};
  GLSL.common = [
    '#define EV_PERIOD 30.0',
    '#define EV_TAU 6.28318530718',
    'uniform float uTime;',
    'uniform float uFocal;',
    'uniform vec2 uViewport;',
    'uniform float uPixelRatio;',
    'uniform float uDensity;',
    'float ev_hash12(vec2 p) {',
    '  vec3 p3 = fract(vec3(p.xyx) * 0.1031);',
    '  p3 += dot(p3, p3.yzx + 33.33);',
    '  return fract((p3.x + p3.y) * p3.z);',
    '}',
    'float ev_noise(vec2 p) {',
    '  vec2 i = floor(p); vec2 f = fract(p);',
    '  vec2 u = f * f * (3.0 - 2.0 * f);',
    '  float a = ev_hash12(i);',
    '  float b = ev_hash12(i + vec2(1.0, 0.0));',
    '  float c = ev_hash12(i + vec2(0.0, 1.0));',
    '  float d = ev_hash12(i + vec2(1.0, 1.0));',
    '  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);',
    '}',
    // 4 octaves, about [0, 0.94], mean ~0.47.
    'float ev_fbm(vec2 p) {',
    '  float s = 0.0; float a = 0.5;',
    '  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);',
    '  for (int i = 0; i < 4; i++) { s += a * ev_noise(p); p = m * p; a *= 0.5; }',
    '  return s;',
    '}',
    'float ev_fbm3(vec2 p) {',
    '  float s = 0.0; float a = 0.5;',
    '  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);',
    '  for (int i = 0; i < 3; i++) { s += a * ev_noise(p); p = m * p; a *= 0.5; }',
    '  return s / 0.875;',
    '}',
    // Noise drifting at `drift` units per second that loops over EV_PERIOD, smoothly: two copies
    // of the field, half a period apart, each sliding one period's drift and jumping back while
    // its weight (sin^2) and the weight's slope are zero; contrast restored. The value and its
    // rate of change are continuous everywhere, the wrap of the period included.
    'vec2 ev_loopWeights(float t) {',
    '  float s = sin(3.14159265 * t / EV_PERIOD);',
    '  float wa = s * s;',
    '  return vec2(wa, 1.0 - wa);',
    '}',
    'float ev_loopFbm(vec2 p, vec2 drift, float t) {',
    '  float tau = t / EV_PERIOD;',
    '  vec2 w = ev_loopWeights(t);',
    '  float a = ev_fbm(p + drift * EV_PERIOD * (fract(tau) - 0.5));',
    '  float b = ev_fbm(p + drift * EV_PERIOD * (fract(tau + 0.5) - 0.5) + vec2(31.7, 17.3));',
    '  float v = w.x * (a - 0.47) + w.y * (b - 0.47);',
    '  return 0.47 + v / sqrt(w.x * w.x + w.y * w.y);',
    '}',
    'float ev_loopFbm3(vec2 p, vec2 drift, float t) {',
    '  float tau = t / EV_PERIOD;',
    '  vec2 w = ev_loopWeights(t);',
    '  float a = ev_fbm3(p + drift * EV_PERIOD * (fract(tau) - 0.5));',
    '  float b = ev_fbm3(p + drift * EV_PERIOD * (fract(tau + 0.5) - 0.5) + vec2(31.7, 17.3));',
    '  float v = w.x * (a - 0.5) + w.y * (b - 0.5);',
    '  return 0.5 + v / sqrt(w.x * w.x + w.y * w.y);',
    '}',
    // sin() of k whole turns per period (k integer keeps the loop seamless).
    'float ev_wave(float k, float phase, float t) {',
    '  return sin(EV_TAU * (k * t / EV_PERIOD + phase));',
    '}',
  ].join('\n');
  GLSL.fragment = [
    // Static screen-space dither: removes banding in the dark gradients.
    'vec3 ev_dither(vec3 c) {',
    '  return c + (ev_hash12(gl_FragCoord.xy) - 0.5) / 255.0;',
    '}',
  ].join('\n');

  // ---------------------------------------------------------------- helpers for scenes
  function rng(seed) {
    var s = (seed >>> 0) || 1;
    return function () {
      s = (s + 0x6d2b79f5) >>> 0;
      var r = Math.imul(s ^ (s >>> 15), 1 | s);
      r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
      return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
    };
  }

  function hashString(text) {
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return h >>> 0;
  }

  function color(hex) {
    return new THREE.Color(hex);
  }

  // A ShaderMaterial with the common GLSL and the shared uniforms (uTime, uFocal, uViewport,
  // uPixelRatio, uDensity) merged in.
  function material(ctx, params) {
    var uniforms = Object.assign({}, ctx.uniforms, params.uniforms || {});
    var m = new THREE.ShaderMaterial({
      uniforms: uniforms,
      vertexShader: 'precision highp float;\n' + GLSL.common + '\n' + params.vertexShader,
      fragmentShader: 'precision highp float;\n' + GLSL.common + '\n' + GLSL.fragment + '\n' + params.fragmentShader,
      transparent: !!params.transparent,
      depthWrite: params.depthWrite !== undefined ? params.depthWrite : !params.transparent,
      depthTest: params.depthTest !== undefined ? params.depthTest : true,
      blending: params.blending !== undefined ? params.blending : THREE.NormalBlending,
      side: params.side !== undefined ? params.side : THREE.FrontSide,
    });
    if (params.extensions) m.extensions = params.extensions;
    return m;
  }

  // A horizontal mirror (calm water) at height y: the scene seen from the mirrored camera is
  // drawn into a small texture (`scale` of the screen, no MSAA, 8 bits), then the water shader
  // samples it with `vMirror` (projective coordinates). Objects on layer 1 are not reflected.
  // Soft sample of the reflection (4 taps around uv): hides the low resolution of the texture.
  GLSL.mirror = [
    'uniform sampler2D tMirror; uniform vec2 uMirrorTexel;',
    'vec3 ev_mirror(vec2 uv) {',
    '  vec2 o = uMirrorTexel * 0.9;',
    '  uv = clamp(uv, vec2(0.002), vec2(0.998));',
    '  return 0.25 * (texture2D(tMirror, uv + vec2(o.x, o.y)).rgb + texture2D(tMirror, uv + vec2(-o.x, o.y)).rgb',
    '    + texture2D(tMirror, uv + vec2(o.x, -o.y)).rgb + texture2D(tMirror, uv - o).rgb);',
    '}',
  ].join('\n');

  var MIRROR_VERTEX = [
    'uniform mat4 uMirrorMatrix;',
    'varying vec4 vMirror; varying vec3 vWorld;',
    'void main() {',
    '  vMirror = uMirrorMatrix * vec4(position, 1.0);',
    '  vec4 w = modelMatrix * vec4(position, 1.0);',
    '  vWorld = w.xyz;',
    '  gl_Position = projectionMatrix * viewMatrix * w;',
    '}',
  ].join('\n');

  function createMirror(ctx, opts) {
    var rt = new THREE.WebGLRenderTarget(2, 2, { depthBuffer: true, stencilBuffer: false });
    rt.texture.generateMipmaps = false;
    var uniforms = Object.assign({
      tMirror: { value: rt.texture },
      uMirrorMatrix: { value: new THREE.Matrix4() },
      uMirrorTexel: { value: new THREE.Vector2(0.5, 0.5) },
    }, opts.uniforms || {});
    var mat = ctx.material({
      uniforms: uniforms,
      vertexShader: opts.vertexShader || MIRROR_VERTEX,
      fragmentShader: GLSL.mirror + '\n' + opts.fragmentShader,
      transparent: !!opts.transparent,
    });
    var geo = new THREE.PlaneGeometry(opts.size[0], opts.size[1], 1, 1);
    geo.rotateX(-Math.PI / 2);
    var mesh = new THREE.Mesh(geo, mat);
    mesh.position.set(opts.center ? opts.center[0] : 0, opts.y, opts.center ? opts.center[1] : 0);
    mesh.frustumCulled = false;
    if (opts.renderOrder !== undefined) mesh.renderOrder = opts.renderOrder;

    var cam = new THREE.PerspectiveCamera();
    cam.layers.set(0);
    var scale = opts.scale || 0.35;
    var bias = new THREE.Matrix4().set(0.5, 0, 0, 0.5, 0, 0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0, 0, 0, 1);
    var cp = new THREE.Vector3(), fwd = new THREE.Vector3(), up = new THREE.Vector3(), target = new THREE.Vector3();
    var plane = new THREE.Vector4(), q = new THREE.Vector4(), normal = new THREE.Vector3(), point = new THREE.Vector3();
    var saveViewport = new THREE.Vector2();
    var busy = false;

    function resize(bufferW, bufferH) {
      var w = Math.max(2, Math.round(bufferW * scale)), h = Math.max(2, Math.round(bufferH * scale));
      rt.setSize(w, h);
      uniforms.uMirrorTexel.value.set(1 / w, 1 / h);
    }

    mesh.onBeforeRender = function (renderer, scene, camera) {
      if (busy || camera === cam) return;
      busy = true;
      camera.getWorldPosition(cp);
      fwd.set(0, 0, -1).applyQuaternion(camera.getWorldQuaternion(new THREE.Quaternion()));
      up.set(0, 1, 0).applyQuaternion(camera.getWorldQuaternion(new THREE.Quaternion()));
      var y = mesh.position.y;
      cam.position.set(cp.x, 2 * y - cp.y, cp.z);
      target.copy(cp).add(fwd);
      target.y = 2 * y - target.y;
      cam.up.set(up.x, -up.y, up.z);
      cam.lookAt(target);
      cam.updateMatrixWorld();
      cam.projectionMatrix.copy(camera.projectionMatrix);
      cam.projectionMatrixInverse.copy(camera.projectionMatrixInverse);
      uniforms.uMirrorMatrix.value.copy(bias).multiply(cam.projectionMatrix)
        .multiply(cam.matrixWorldInverse).multiply(mesh.matrixWorld);
      // oblique near plane: nothing under the water is drawn into the reflection
      normal.set(0, 1, 0).transformDirection(cam.matrixWorldInverse);
      point.set(0, y, 0).applyMatrix4(cam.matrixWorldInverse);
      plane.set(normal.x, normal.y, normal.z, -normal.dot(point));
      var e = cam.projectionMatrix.elements;
      q.set((Math.sign(plane.x) + e[8]) / e[0], (Math.sign(plane.y) + e[9]) / e[5], -1, (1 + e[10]) / e[14]);
      plane.multiplyScalar(2 / plane.dot(q));
      e[2] = plane.x; e[6] = plane.y; e[10] = plane.z + 1; e[14] = plane.w;

      var focal = ctx.uniforms.uFocal.value;
      saveViewport.copy(ctx.uniforms.uViewport.value);
      ctx.uniforms.uFocal.value = focal * scale;
      ctx.uniforms.uViewport.value.multiplyScalar(scale);
      var previous = renderer.getRenderTarget();
      mesh.visible = false;
      renderer.setRenderTarget(rt);
      renderer.clear();
      renderer.render(scene, cam);
      renderer.setRenderTarget(previous);
      mesh.visible = true;
      ctx.uniforms.uFocal.value = focal;
      ctx.uniforms.uViewport.value.copy(saveViewport);
      busy = false;
    };

    ctx.onResize(resize);
    mesh.getRenderTarget = function () { return rt; };
    return mesh;
  }

  // ---------------------------------------------------------------- state
  var registry = {};
  var state = null;   // the running scene
  var canvas = null;
  var startCount = 0;

  function register(def) {
    registry[def.id] = def;
  }

  function loadScene(id) {
    if (registry[id]) return Promise.resolve(registry[id]);
    if (!/^[a-z0-9-]+$/.test(id)) return Promise.reject(new Error('invalid scene id ' + id));
    return new Promise(function (resolve, reject) {
      var tag = document.createElement('script');
      tag.src = 'scenes/' + id + '.js';
      tag.onload = function () {
        if (registry[id]) resolve(registry[id]);
        else reject(new Error('scene ' + id + ' did not register'));
      };
      tag.onerror = function () { reject(new Error('unknown scene ' + id)); };
      document.head.appendChild(tag);
    });
  }

  function clampLevel(level) {
    var n = Number(level);
    if (!isFinite(n)) return 0;
    return Math.max(0, Math.min(100, n));
  }

  function viewportSize() {
    if (state && state.fixedSize) return state.fixedSize;
    if (state && state.container) {
      return { w: Math.max(1, state.container.clientWidth), h: Math.max(1, state.container.clientHeight) };
    }
    return { w: Math.max(1, window.innerWidth), h: Math.max(1, window.innerHeight) };
  }

  function pixelRatio(quality) {
    if (state && state.fixedSize) return 1;
    return Math.min(window.devicePixelRatio || 1, MAX_PIXEL_RATIO[quality] || 1);
  }

  function applySize() {
    if (!state) return;
    var size = viewportSize();
    var pr = pixelRatio(state.quality);
    state.renderer.setPixelRatio(pr);
    state.renderer.setSize(size.w, size.h, !state.fixedSize);
    state.camera.aspect = size.w / size.h;
    if (state.instance && state.instance.resize) state.instance.resize(state.camera.aspect);
    state.camera.updateProjectionMatrix();
    var buffer = state.renderer.getDrawingBufferSize(new THREE.Vector2());
    state.uniforms.uViewport.value.set(buffer.x, buffer.y);
    state.uniforms.uPixelRatio.value = pr;
    state.uniforms.uFocal.value = buffer.y / (2 * Math.tan(THREE.MathUtils.degToRad(state.camera.fov) / 2));
    state.resizeHooks.forEach(function (fn) { fn(buffer.x, buffer.y); });
  }

  // ---------------------------------------------------------------- decor levels
  function setLevelNow(id, level) {
    var d = state.decorLevels[id];
    d.current = d.target = d.from = level / 100;
    d.progress = 1;
    pushLevel(id);
  }

  function pushLevel(id) {
    var decor = state.instance.decors[id];
    var d = state.decorLevels[id];
    if (!decor) return;
    decor.setLevel(d.current);
    if (decor.object) decor.object.visible = d.current > 0.0005;
  }

  // A change of level runs over DECOR_EASE_S with a smoothstep curve (soft start and end); a new
  // change during a transition starts from the current value.
  function stepDecor(dt) {
    var ids = Object.keys(state.decorLevels);
    for (var i = 0; i < ids.length; i++) {
      var d = state.decorLevels[ids[i]];
      if (d.progress >= 1) continue;
      d.progress = Math.min(1, d.progress + dt / DECOR_EASE_S);
      var e = d.progress * d.progress * (3 - 2 * d.progress);
      d.current = d.progress >= 1 ? d.target : d.from + (d.target - d.from) * e;
      pushLevel(ids[i]);
    }
  }

  // ---------------------------------------------------------------- rendering
  function renderAt(t) {
    var tm = ((t % PERIOD) + PERIOD) % PERIOD;
    state.uniforms.uTime.value = tm;
    if (state.instance.update) state.instance.update(tm);
    var decorIds = Object.keys(state.instance.decors);
    for (var i = 0; i < decorIds.length; i++) {
      var decor = state.instance.decors[decorIds[i]];
      if (decor.update && decor.object && decor.object.visible) decor.update(tm);
    }
    state.renderer.info.reset();
    state.renderer.render(state.scene, state.camera);
  }

  function loop(now) {
    if (!state || state.paused) return;
    state.raf = requestAnimationFrame(loop);
    var minDelta = 1000 / state.fps - 2;
    if (state.lastFrame !== null && now - state.lastFrame < minDelta) return;
    var elapsed = state.lastFrame === null ? 0 : (now - state.lastFrame) / 1000;
    // the scene's clock never jumps more than 0.1 s (after a stall it simply slows down);
    // a decor transition follows the real time, so it lasts about 1 s even on a slow device
    var dt = Math.min(elapsed, 0.1);
    state.lastFrame = now;
    state.time = (state.time + dt) % PERIOD;
    var t0 = performance.now();
    stepDecor(Math.min(elapsed, 1.0));
    renderAt(state.time);
    var spent = performance.now() - t0;
    state.frameCount++;
    state.statFrames++;
    state.statMs += spent;
    if (!state.readySent) {
      state.readySent = true;
      post({ type: 'ready' });
      if (state.resolveReady) state.resolveReady();
    }
    if (now - state.statStart >= STATS_EVERY_MS) {
      var seconds = (now - state.statStart) / 1000;
      post({
        type: 'stats',
        fps: Math.round((state.statFrames / seconds) * 10) / 10,
        ms: Math.round((state.statMs / Math.max(1, state.statFrames)) * 10) / 10,
      });
      state.statStart = now;
      state.statFrames = 0;
      state.statMs = 0;
    }
  }

  function startLoop() {
    if (!state || state.paused || state.record) return;
    cancelAnimationFrame(state.raf);
    state.lastFrame = null;
    state.statStart = performance.now();
    state.statFrames = 0;
    state.statMs = 0;
    state.raf = requestAnimationFrame(loop);
  }

  // ---------------------------------------------------------------- lifecycle
  function disposeState() {
    if (!state) return;
    cancelAnimationFrame(state.raf);
    try {
      if (state.instance && state.instance.dispose) state.instance.dispose();
      state.scene.traverse(function (o) {
        if (o.geometry) o.geometry.dispose();
        if (o.material) {
          var mats = Array.isArray(o.material) ? o.material : [o.material];
          mats.forEach(function (m) { m.dispose(); });
        }
        if (o.getRenderTarget) o.getRenderTarget().dispose();
      });
    } catch (e) { /* best effort */ }
    if (state.resizeObserver) state.resizeObserver.disconnect();
    var renderer = state.renderer;
    if (canvas && canvas.parentNode) canvas.parentNode.removeChild(canvas);
    canvas = null;
    state = null;
    try {
      renderer.dispose();
      renderer.forceContextLoss();
    } catch (e) { /* best effort */ }
  }

  function build(def, options) {
    canvas = document.createElement('canvas');
    canvas.id = 'scene';
    var container = options.container && options.container.appendChild ? options.container : null;
    (container || document.body).appendChild(canvas);
    var quality = options.quality === 'low' ? 'low' : 'high';
    var renderer = new THREE.WebGLRenderer({
      canvas: canvas,
      antialias: quality === 'high',
      alpha: false,
      depth: true,
      stencil: false,
      powerPreference: 'default',
      preserveDrawingBuffer: !!options.record,
    });
    renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
    renderer.setClearColor(0x000000, 1);
    renderer.info.autoReset = false;
    renderer.sortObjects = true;

    // a context lost by the system (not by dispose(), which detaches the canvas first) is
    // reported, and the scene is rebuilt when the context comes back
    var own = canvas;
    canvas.addEventListener('webglcontextlost', function (event) {
      if (!state || canvas !== own) return;
      event.preventDefault();
      post({ type: 'error', detail: 'webglcontextlost' });
      cancelAnimationFrame(state.raf);
    }, false);
    canvas.addEventListener('webglcontextrestored', function () {
      if (!state || canvas !== own) return;
      var restart = state.restartArgs;
      disposeState();
      window.eventide.start(restart.id, restart.options);
    }, false);

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(45, 9 / 16, 0.1, 2000);
    var uniforms = {
      uTime: { value: 0 },
      uFocal: { value: 1000 },
      uViewport: { value: new THREE.Vector2(1080, 1920) },
      uPixelRatio: { value: 1 },
      uDensity: { value: DENSITY[quality] },
    };
    state = {
      id: def.id,
      def: def,
      renderer: renderer,
      scene: scene,
      camera: camera,
      uniforms: uniforms,
      quality: quality,
      moment: options.moment || null,
      fps: Math.max(1, Math.min(30, Number(options.fps) || 30)),
      paused: !!options.paused,
      record: !!options.record,
      fixedSize: options.fixedSize || null,
      container: container,
      time: 0,
      raf: 0,
      lastFrame: null,
      frameCount: 0,
      readySent: false,
      decorLevels: {},
      restartArgs: { id: def.id, options: options },
    };
    var ctx = {
      THREE: THREE,
      GLSL: GLSL,
      PERIOD: PERIOD,
      TAU: TAU,
      scene: scene,
      camera: camera,
      renderer: renderer,
      uniforms: uniforms,
      quality: quality,
      moment: state.moment,
      record: state.record,
      rng: function (salt) { return rng(hashString(def.id + ':' + (salt || ''))); },
      color: color,
      material: function (params) { return material(ctx, params); },
      decors: window.EventideDecors || {},
      onResize: function (fn) { state.resizeHooks.push(fn); },
      mirror: function (opts) { return createMirror(ctx, opts); },
    };
    state.resizeHooks = [];
    camera.layers.enable(1);
    if (container && window.ResizeObserver) {
      // tools only (preview page): the scene fills a box of the page instead of the window
      state.resizeObserver = new ResizeObserver(function () {
        if (!state) return;
        applySize();
        if (state.paused) renderAt(state.time);
      });
      state.resizeObserver.observe(container);
    }
    state.instance = def.build(ctx);
    if (!state.instance.decors) state.instance.decors = {};
    // decor levels: only the ids the scene supports
    var wanted = options.decor || {};
    def.decors.forEach(function (id) {
      state.decorLevels[id] = { current: 0, target: 0, from: 0 };
      var level = Object.prototype.hasOwnProperty.call(wanted, id) ? clampLevel(wanted[id]) : 0;
      setLevelNow(id, level);
    });
    applySize();
  }

  var api = {
    version: 1,
    period: PERIOD,
    scenes: function () { return Object.keys(registry); },

    start: function (sceneId, options) {
      options = options || {};
      disposeState();
      var token = ++startCount;
      return loadScene(String(sceneId)).then(function (def) {
        // a later start() while this scene was loading wins
        if (token !== startCount) return undefined;
        return new Promise(function (resolve) {
          build(def, options);
          state.resolveReady = resolve;
          if (state.record || state.paused) {
            renderAt(state.time);
            if (!state.readySent) {
              state.readySent = true;
              if (!state.record) post({ type: 'ready' });
            }
            resolve();
          } else {
            startLoop();
          }
        });
      }).catch(function (e) {
        post({ type: 'error', detail: errorDetail(e) });
        throw e;
      });
    },

    setDecor: function (id, level) {
      if (!state || !state.decorLevels[id]) return false;
      var d = state.decorLevels[id];
      d.from = d.current;
      d.target = clampLevel(level) / 100;
      d.progress = d.target === d.current ? 1 : 0;
      if (state.record) setLevelNow(id, d.target * 100);
      return true;
    },

    setMoment: function (moment) {
      if (!state) return;
      state.moment = moment;
      if (state.instance.setMoment) state.instance.setMoment(moment);
    },

    setPaused: function (paused) {
      if (!state) return;
      paused = !!paused;
      if (paused === state.paused) return;
      state.paused = paused;
      if (paused) cancelAnimationFrame(state.raf);
      else startLoop();
    },

    setQuality: function (quality) {
      if (!state) return;
      state.quality = quality === 'low' ? 'low' : 'high';
      state.uniforms.uDensity.value = DENSITY[state.quality];
      applySize();
      if (state.instance.setQuality) state.instance.setQuality(state.quality);
    },

    dispose: function () {
      startCount++;
      disposeState();
    },

    // Tools only (render pipeline, preview): the running scene's decor ids and default levels.
    describe: function () {
      if (!state) return null;
      return { id: state.id, decors: state.def.decors.slice(), defaults: Object.assign({}, state.def.defaults || {}), period: PERIOD };
    },

    // Tools only (debugging in a desktop browser): the three.js objects of the running scene.
    debug: function () {
      return state ? { scene: state.scene, camera: state.camera, renderer: state.renderer, THREE: THREE } : null;
    },

    // Tools only (render pipeline, preview): renderer counters of the last frame.
    info: function () {
      if (!state) return null;
      var info = state.renderer.info;
      var buffer = state.renderer.getDrawingBufferSize(new THREE.Vector2());
      return {
        scene: state.id,
        calls: info.render.calls,
        triangles: info.render.triangles,
        points: info.render.points,
        lines: info.render.lines,
        programs: info.programs ? info.programs.length : null,
        geometries: info.memory.geometries,
        textures: info.memory.textures,
        width: buffer.x,
        height: buffer.y,
        pixelRatio: state.renderer.getPixelRatio(),
        frames: state.frameCount,
        decor: Object.keys(state.decorLevels).reduce(function (acc, id) {
          acc[id] = Math.round(state.decorLevels[id].current * 100);
          return acc;
        }, {}),
      };
    },
  };

  window.addEventListener('resize', function () {
    if (!state || state.fixedSize) return;
    applySize();
    if (state.paused) renderAt(state.time);
  });

  window.EventideImaginaire = {
    THREE: THREE,
    GLSL: GLSL,
    PERIOD: PERIOD,
    register: register,
    rng: rng,
  };
  window.eventide = api;

  // ---------------------------------------------------------------- recording mode
  function recordMode() {
    var q = new URLSearchParams(window.location.search);
    if (q.get('record') !== '1') return;
    window.eventideFrameReady = false;
    var decor;
    try {
      decor = q.get('decor') ? JSON.parse(q.get('decor')) : null;
    } catch (e) {
      post({ type: 'error', detail: 'invalid decor json' });
      decor = null;
    }
    var w = parseInt(q.get('w') || '1080', 10);
    var h = parseInt(q.get('h') || '1920', 10);
    var t = parseFloat(q.get('t') || '0');
    var id = q.get('scene') || 'foret-lucioles';
    loadScene(id).then(function (def) {
      if (!decor) decor = def.defaults || {};
      return api.start(id, {
        decor: decor,
        moment: q.get('moment') || null,
        quality: 'high',
        fps: 30,
        record: true,
        fixedSize: { w: w, h: h },
      });
    }).then(function () {
      renderAt(t);
      return afterPaint();
    }).then(function () {
      window.eventideFrameReady = true;
    });

    window.eventideRenderAt = function (time, levels) {
      window.eventideFrameReady = false;
      if (levels) {
        Object.keys(state.decorLevels).forEach(function (decorId) {
          setLevelNow(decorId, clampLevel(levels[decorId] || 0));
        });
      }
      renderAt(Number(time) || 0);
      return afterPaint().then(function () {
        window.eventideFrameReady = true;
        return api.info();
      });
    };
  }

  function afterPaint() {
    return new Promise(function (resolve) {
      requestAnimationFrame(function () { requestAnimationFrame(function () { resolve(); }); });
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', recordMode);
  else recordMode();
})();
