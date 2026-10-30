---
name: scene-imaginaire
description: Create or upgrade a live three.js « Imaginaire » scene of Full Relax (app/assets/imaginaire/) at the quality bar validated by the product owner (Forêt aux lucioles v2), fast. Use for any new 3D scene, any art-direction change of a scene, or any decor element of a scene.
---

# Scènes « Imaginaire » (3D) — règles et méthode rapide

Product: Full Relax (repo `eventide`), Android app of living landscapes for relaxation and sleep. The « Imaginaire » category (contract `docs/api/contrat-v1.md` § 12) holds live three.js scenes drawn in an Android WebView, where the user adds or removes decor elements. Read `docs/app/architecture.md` § 20 (runtime, API, budgets, measures) and `tools/imaginaire/README.md` (commands) before coding. Code and comments in English; texts and docs in French. A delegated agent never writes git.

## 1. Quality bar (product owner, binding)

- **Reference**: `app/assets/imaginaire/scenes/foret-lucioles.js` (v2) + `app/assets/imaginaire/post.js`. Validated on 30 Oct 2026: « c'est correct ». Every scene must reach this level: real 3D geometry with depth and parallax, physically based light (one key light with shadow map, sky/ambient, IBL only where it pays), atmosphere (height fog with forward scattering, analytic ground mist), HDR finish through `post.js` (half-float target + MSAA 4×, half-res bloom on highlights only, ONE composite pass: ACES or neutral tone mapping, light rays near the key light, slight chromatic aberration, vignette, deterministic grain).
- **Look**: calm, slow, premium, « vraiment naturel » ; never flashy, cartoonish or busy. It is a sleep app: slow motion, soft light, no strobe, no sudden events.
- **Coherence of decor** (owner's rule): only elements that make sense in that place. Example: no falling broadleaf leaves in a spruce forest (removed from the forest). Ask yourself for every decor id: would you see this here, at this hour, in this weather?
- **Lower third stays dark and quiet** (white app text sits there).
- Not the content of any reference prompt the owner shows: only its level of craft.
- No third-party images, textures or sounds: everything procedural or our own.

## 2. Contract and runtime (do not change without the orchestrator)

- JS API `window.eventide`: `start(id, {decor, moment, quality, fps})`, `setDecor(id, 0..100)` (~1 s eased), `setMoment` (may be ignored), `setPaused(bool)` (stops the loop entirely), `setQuality('low'|'high')`, `dispose()`. Messages to channel `EventideScene`: `ready`, `error`, `stats` every 10 s. Recording mode `index.html?record=1&scene=…&t=…&w=…&h=…&decor=…`.
- Classic scripts only (no ES modules: the WebView blocks them from `file:///android_asset/`); three.js is the vendored tree-shaken build (`tools/imaginaire/three-entry.mjs` + `build-three.mjs` to add a class).
- **Deterministic**: the image is a pure function of `t mod periode_s` (30 s). Camera paths, particles, grain: all periodic. `check.js` verifies the 30 s = 0 s frame.
- Allowed decor ids per scene = catalog `paysages[].decors` (`app/assets/catalog.json`, backend copy identical) = the scene's `decors` list = `tools/imaginaire/check.js` table. Changing a list touches all three (catalog belongs to the orchestrator: report it).

## 3. Phone budget (Galaxy S24, Xclipse 940; the app once crashed the GPU driver)

- ≤ 30 fps, pixel ratio ≤ 1.5, < 150 draw calls (instancing), render targets ≤ ~45 MB in `high`.
- Post chain = HDR MSAA target + ≤ 5 bloom mips at half res + one composite pass. Nothing else full-screen.
- `quality: 'low'` must exist and be much lighter: no MSAA/bloom/rays/CA/grain, lighter fog, fewer instances.
- Report draw calls, triangles, render-target MB, shaded fragments per pixel, SwiftShader ms/frame vs. the forest v2 (1 891 ms high / 966 ms low at 540×1170). Do not exceed the forest without saying why.

## 4. Fast workflow (the slow part is software WebGL on 4 CPU cores: render as little as possible)

1. **Read before writing**: forest v2 and `post.js`; reuse their patterns (instanced LOD meshes, card foliage with alpha-to-coverage, fog/mist shader chunks, shadow-mapped key light, translucency term). Factor shared helpers into a shared file only if two scenes need them, and say so.
2. **Iterate on stills, small**: `node tools/imaginaire/render.js shot --scene <id> --t 0,7.5,15,22.5 --decor default` (then `--decor max`, then each element alone). Look at every image yourself. Fix, re-shoot. Use `render.js sheet --scene <id>` only for the final art-direction review. Never render a video while iterating.
3. **Checks**: `node tools/imaginaire/check.js --scene <id>` must pass; `node tools/imaginaire/render.js stats` for the budget table.
4. **Preview for the owner**: `node tools/imaginaire/build-preview.js`, then hand back. The orchestrator republishes the preview artifact (file list in `tools/imaginaire/README.md`; add any new file) and the owner validates in his browser/phone (real GPU, real motion).
5. **Only after the owner validated**: `node tools/imaginaire/render.js video --scene <id>` (poster + 30 s loop; ≤ 2.5 MB, or ≤ 4 MB for a 3D scene, contract § 8), `render.js seam`, check `app/tool/ci/check_apk_contents.sh` expectations, regenerate `remote.json`.
6. Several scenes at once: one agent per scene, each in its own git worktree based on the current branch; at most 2 rendering at the same time on 4 cores.

## 5. Report (short, factual, French summary for the owner + technical lines)

Files changed; per scene: one-line description, decor list and defaults, budget table vs. forest v2, contact-sheet path (write it to the session scratchpad when given), what only the S24 can confirm, any change needed in the catalog or contract (for the orchestrator).
