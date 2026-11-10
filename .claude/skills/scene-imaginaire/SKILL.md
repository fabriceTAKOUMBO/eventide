---
name: scene-imaginaire
description: Create or upgrade a three.js « Imaginaire » scene of Full Relax (tools/imaginaire/runtime/), rendered offline into a looping landscape video, at the quality bar validated by the product owner (Forêt aux lucioles v2), fast. Use for any new Imaginaire landscape, any art-direction change of one, or a re-render of its video.
---

# Scènes « Imaginaire » (3D) — règles et méthode rapide

Product: Full Relax (repo `eventide`), Android app of living landscapes for relaxation and sleep. The « Imaginaire » category (contract `docs/api/contrat-v1.md` § 12) holds landscapes authored as three.js scenes and **shipped as videos**: since 10 Nov 2026 the app no longer draws 3D live (it heated the phone, product owner's decision); `tools/imaginaire/render.js video` turns each scene into its poster and 30 s seamless loop, played like a filmed landscape. The user cannot add decor elements any more: the decor of a scene is chosen by us and baked into its video (its `defaults`). Read `docs/app/architecture.md` § 20 and § 22 and `tools/imaginaire/README.md` (commands) before coding. Code and comments in English; texts and docs in French. A delegated agent never writes git.

## 1. Quality bar (product owner, binding)

- **Reference**: `tools/imaginaire/runtime/scenes/foret-lucioles.js` (v2) + `tools/imaginaire/runtime/post.js`. Validated on 30 Oct 2026: « c'est correct ». Every scene must reach this level: real 3D geometry with depth and parallax, physically based light (one key light with shadow map, sky/ambient, IBL only where it pays), atmosphere (height fog with forward scattering, analytic ground mist), HDR finish through `post.js` (half-float target + MSAA 4×, half-res bloom on highlights only, ONE composite pass: ACES or neutral tone mapping, light rays near the key light, slight chromatic aberration, vignette, deterministic grain).
- **Look**: calm, slow, premium, « vraiment naturel » ; never flashy, cartoonish or busy. It is a sleep app: slow motion, soft light, no strobe, no sudden events.
- **Coherence of decor** (owner's rule, applies to the decor baked into the video): only elements that make sense in that place. Example: no falling broadleaf leaves in a spruce forest (removed from the forest). Ask yourself for every decor id: would you see this here, at this hour, in this weather?
- **Lower third stays dark and quiet** (white app text sits there).
- Not the content of any reference prompt the owner shows: only its level of craft.
- No third-party images, textures or sounds: everything procedural or our own.

## 2. Contract and runtime (do not change without the orchestrator)

- JS API `window.eventide` (used by the offline tools only): `start(id, {decor, moment, quality, fps})`, `setDecor(id, 0..100)` (~1 s eased), `setMoment` (may be ignored), `setPaused(bool)` (stops the loop entirely), `setQuality('low'|'high')`, `dispose()`. Messages to channel `EventideScene`: `ready`, `error`, `stats` every 10 s. Recording mode `index.html?record=1&scene=…&t=…&w=…&h=…&decor=…`.
- Classic scripts only (kept from the WebView era; the tools serve them as is); three.js is the vendored tree-shaken build (`tools/imaginaire/three-entry.mjs` + `build-three.mjs` to add a class).
- **Deterministic**: the image is a pure function of `t mod periode_s` (30 s). Camera paths, particles, grain: all periodic. `check.js` verifies the 30 s = 0 s frame.
- The scene's `decors` list and `defaults` live in the scene file and `tools/imaginaire/check.js`; the catalog no longer lists decors for landscapes (they are videos: `rendu: video`). The video is rendered with the scene's `defaults`. A variant with another decor (e.g. snow) is a separate landscape with its own id and video: report it to the orchestrator (catalog and contract belong to it).

## 3. Render and video budget (the phone only plays the video now)

- Render time: software WebGL on 4 CPU cores, 720 frames per loop; aim at ≤ 4 s per frame at 720 × 1280 (about 50 min per loop), report the measured ms/frame (`render.js stats`).
- Video: H.264 1080 × 1920, 30 s loop, ≤ 2.5 MB, or ≤ 4 MB for an Imaginaire landscape (contract § 8). Fine detail that moves everywhere (grain, dense particles, small leaves) costs bits: prefer slow, large-scale motion; the grain stays live-only and is never in the video.
- Seam: `render.js seam` must show the master's last → first step below the largest ordinary step (the mer-nuages jump of 30 Oct 2026 came from a texture drifting linearly with time: everything that moves must loop over the 30 s period).

## 4. Fast workflow (the slow part is software WebGL on 4 CPU cores: render as little as possible)

1. **Read before writing**: forest v2 and `post.js`; reuse their patterns (instanced LOD meshes, card foliage with alpha-to-coverage, fog/mist shader chunks, shadow-mapped key light, translucency term). Factor shared helpers into a shared file only if two scenes need them, and say so.
2. **Iterate on stills, small**: `node tools/imaginaire/render.js shot --scene <id> --t 0,7.5,15,22.5 --decor default` (then `--decor max`, then each element alone). Look at every image yourself. Fix, re-shoot. Use `render.js sheet --scene <id>` only for the final art-direction review. Never render a video while iterating.
3. **Checks**: `node tools/imaginaire/check.js --scene <id>` must pass; `node tools/imaginaire/render.js stats` for the render cost.
4. **Preview for the owner**: `node tools/imaginaire/build-preview.js`, then hand back. The orchestrator republishes the preview artifact (file list in `tools/imaginaire/README.md`; add any new file) and the owner validates the look in his browser (the preview still draws live; the app will show the video).
5. **Only after the owner validated**: `node tools/imaginaire/render.js video --scene <id>` (poster + 30 s loop; ≤ 2.5 MB, or ≤ 4 MB for an Imaginaire landscape, contract § 8), `render.js seam`, check `app/tool/ci/check_apk_contents.sh` expectations (posters and the free loop bundled, Premium loops in the demo only), regenerate `remote.json`. A new landscape also needs its catalog entry (`rendu: video`, theme `imaginaire`): report it to the orchestrator.
6. Several scenes at once: one agent per scene, each in its own git worktree based on the current branch; at most 2 rendering at the same time on 4 cores.

## 5. Report (short, factual, French summary for the owner + technical lines)

Files changed; per scene: one-line description, baked decor, render cost and video size/CRF/seam, contact-sheet path (write it to the session scratchpad when given), what only the owner's eye can confirm, any change needed in the catalog or contract (for the orchestrator).
