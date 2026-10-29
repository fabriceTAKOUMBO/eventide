/*
 * Eventide « Imaginaire »: scenery shared by several scenes (GLSL snippets and builders).
 *   TREELINE: a row of pines drawn by a fragment shader on one wide quad (ragged, drooping
 *             tiers; trees every uSpacing, heights from a hash, a clearing of half-width uGap).
 *   RIDGE:    a mountain or hill profile along x (ridged noise), for silhouettes.
 */
(function () {
  'use strict';
  var THREE = window.THREE;

  var TREELINE = [
    'uniform float uSpacing; uniform vec2 uHeight; uniform float uWidth; uniform float uGap; uniform float uSeed;',
    'uniform float uDetail; uniform float uSway; uniform float uThin;',
    'float ev_pine(float dx, float y, float h, float w, float s) {',
    '  float t = y / h;',
    '  if (t > 1.0 || t < -0.02) return -1.0;',
    '  float trunk = w * 0.05 * (1.15 - t);',
    '  float crown = -1.0;',
    '  float base = 0.06 + 0.14 * s;',
    // boughs droop: tiers slope down away from the trunk
    '  float tt = t + 0.42 * abs(dx) / h;',
    '  if (tt > base) {',
    '    float c = min((tt - base) / (1.0 - base), 1.0);',
    '    float cone = w * pow(1.0 - c, 0.92) * smoothstep(0.0, 0.05, c);',
    '    float tiers = 8.0 + floor(s * 6.0);',
    '    float k = fract(c * tiers + s * 3.0);',
    '    float tier = 1.0 - 0.3 * pow(k, 0.8);',
    '    float side = dx < 0.0 ? 1.7 : 3.1;',
    '    float rag = ev_noise(vec2(c * tiers * 2.2, side + s * 13.0)) - 0.5;',
    '    float fine = ev_noise(vec2(c * tiers * 8.0 * uDetail, side * 2.0 + s * 7.0)) - 0.5;',
    '    float needle = uDetail > 0.85 ? ev_noise(vec2(c * tiers * 34.0 * uDetail, side * 5.0 + s * 3.0)) - 0.5 : 0.0;',
    '    crown = cone * tier * (1.0 + 0.34 * rag + 0.24 * fine + 0.16 * needle * uDetail);',
    '  }',
    '  return max(trunk, crown) - abs(dx);',
    '}',
    // signed distance-like value: > 0 inside a tree
    'float ev_treeDist(float x, float y) {',
    '  float cell = floor(x / uSpacing);',
    '  float best = -1e3;',
    '  for (int i = -2; i <= 2; i++) {',
    '    float c = cell + float(i);',
    '    float hs = ev_hash12(vec2(c, uSeed));',
    '    float cx = (c + 0.15 + 0.7 * ev_hash12(vec2(c + 7.0, uSeed))) * uSpacing;',
    '    if (abs(cx) < uGap * (0.75 + 0.5 * ev_hash12(vec2(c, uSeed + 3.0)))) continue;',
    '    if (ev_hash12(vec2(c, uSeed + 5.0)) < uThin) continue;',
    '    float h = mix(uHeight.x, uHeight.y, hs);',
    '    float sw = uSway * h * ev_wave(1.0, hs, uTime) * (y / h) * (y / h);',
    '    best = max(best, ev_pine(x - cx - sw, y, h, h * uWidth * (0.85 + 0.3 * hs), hs));',
    '  }',
    '  return best;',
    '}',
  ].join('\n');

  var RIDGE = [
    // profile in [0, 1] along x: broad shapes plus sharp ridges
    'float ev_ridge(float x, float seed, float freq) {',
    '  float a = ev_noise(vec2(x * freq, seed));',
    '  float b = 1.0 - abs(ev_noise(vec2(x * freq * 2.1, seed + 5.0)) * 2.0 - 1.0);',
    '  float c = ev_noise(vec2(x * freq * 5.3, seed + 9.0));',
    '  float d = ev_noise(vec2(x * freq * 13.0, seed + 13.0));',
    '  float e = ev_noise(vec2(x * freq * 37.0, seed + 17.0));',
    '  return clamp(0.52 * a + 0.24 * pow(b, 1.6) + 0.14 * c + 0.07 * d + 0.03 * e, 0.0, 1.0);',
    '}',
  ].join('\n');

  // A vertical quad of the given half-width and height, standing on y = 0 at depth z; the
  // fragment shader gets vWorld and vLocal (x along the row, y up).
  var ROW_VERTEX = [
    'varying vec3 vWorld; varying vec2 vLocal;',
    'void main() {',
    '  vec4 w = modelMatrix * vec4(position, 1.0);',
    '  vWorld = w.xyz; vLocal = position.xy;',
    '  gl_Position = projectionMatrix * viewMatrix * w;',
    '}',
  ].join('\n');

  function rowQuad(material, z, halfWidth, top, bottom) {
    bottom = bottom === undefined ? -0.5 : bottom;
    var geo = new THREE.PlaneGeometry(halfWidth * 2, top - bottom, 1, 1);
    geo.translate(0, (top + bottom) / 2, 0);
    var mesh = new THREE.Mesh(geo, material);
    mesh.position.set(0, 0, z);
    return mesh;
  }

  window.EventideScenery = {
    TREELINE: TREELINE,
    RIDGE: RIDGE,
    ROW_VERTEX: ROW_VERTEX,
    rowQuad: rowQuad,
  };
})();
