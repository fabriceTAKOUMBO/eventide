# Paysages imaginaires (3D) : outils

Les six scènes 3D de la catégorie « Imaginaire » (contrat d'API § 12) sont dessinées en direct par
l'application dans une WebView, avec three.js, depuis `app/assets/imaginaire/` (hors ligne). Ce
dossier contient les outils autour de ces scènes :

| Fichier | Rôle |
|---|---|
| `package.json`, `package-lock.json` | versions exactes : `three` 0.186.1 (npm), `esbuild` 0.28.2 |
| `three-entry.mjs`, `build-three.mjs` | fabrique `app/assets/imaginaire/vendor/three.min.js` (script classique, global `THREE`) |
| `render.js` | rendus hors ligne : planches de contrôle, mesures, image fixe et boucle de fond d'écran de chaque scène |
| `check.js` | vérifications du runtime (API, décors permis, transitions, pause, boucle exacte) |
| `serve.js` | petit serveur local (127.0.0.1) pour les rendus et l'aperçu |
| `preview/index.html`, `build-preview.js` | page d'aperçu autonome (toutes les scènes, curseurs du décor), publiable telle quelle |

Prérequis : Node.js 22, Playwright avec Chromium (`require('playwright')`, déjà installé ; ne pas
installer de navigateur), ffmpeg avec libx264, Python 3 (pour `remote.json`).

## three.js

```sh
cd tools/imaginaire && npm ci && node build-three.mjs
```

three.js n'est plus publié en script classique (seulement en modules ES). Or la WebView Android
refuse les imports de modules depuis `file:///android_asset/` (origine opaque, CORS) et
`webview_flutter` n'expose pas « file access from file URLs ». `build-three.mjs` regroupe donc,
avec esbuild, la version module du paquet npm épinglé en **un seul script classique**, réduit aux
classes utilisées (`three-entry.mjs`, 567 Ko, 142 Ko compressé par gzip). La licence MIT est recopiée à côté
(`vendor/LICENSE-three.txt`), la version dans `vendor/VERSION`. Pour utiliser une autre classe de
three.js : l'ajouter à `three-entry.mjs`, puis relancer le script.

## Aperçu (pour le product owner)

```sh
node tools/imaginaire/build-preview.js   # recopie runtime, scènes, three.js et la police dans preview/
node tools/imaginaire/serve.js           # puis ouvrir http://127.0.0.1:8765/preview/
```

`preview/` est autonome : il ne charge que des fichiers relatifs (aucun réseau). On choisit la scène,
on règle chaque élément du décor (0 à 100, transition d'environ 1 s), on met en pause, on passe en
plein écran ; une case superpose le texte blanc de l'app pour juger de sa lisibilité. Au téléphone
(390 px), la scène occupe l'écran et les réglages forment un panneau en bas, repliable. Relancer
`build-preview.js` après toute modification de `app/assets/imaginaire/` (les copies doivent rester
identiques aux fichiers de l'app).

Fichiers publiés de `preview/` : `index.html`, `runtime.js`, `decors.js`, `scenery.js`, `post.js`,
`vendor/three.min.js`, `vendor/LICENSE-three.txt`, `fonts/Manrope-Variable.ttf`,
`fonts/OFL-Manrope.txt`, `scenes/{aurore,foret-lucioles,jardin-zen,lac-lune,mer-nuages,ondes}.js`.

## Vérifications du runtime

```sh
node tools/imaginaire/check.js [--scene id,...]
```

Pour chaque scène, dans Chromium sans écran : `start()` envoie `ready`, ne garde que les décors
permis par la scène (un identifiant inconnu est ignoré), sans message d'erreur ; `setDecor()`
refuse un décor que la scène n'a pas et fait la transition en environ 1 s ; au plus 30 images par
seconde ; `setPaused(true)` n'en dessine plus aucune, `setPaused(false)` reprend ; `dispose()`
retire tout ; en mode enregistrement, l'image à 30 s est exactement celle à 0 s. Sortie non nulle
au moindre échec. La fin de la transition est attendue jusqu'à 12 s : le WebGL logiciel met des
images en file, puis se fige plusieurs secondes le temps de les dessiner.

## Rendus hors ligne

```sh
node tools/imaginaire/render.js sheet [--scene id,...]   # planches de contrôle (out/<id>-sheet.jpg)
node tools/imaginaire/render.js shot --scene lac-lune --t 0,12 --decor max
node tools/imaginaire/render.js stats                    # appels de dessin, triangles, cibles HDR, images/s
node tools/imaginaire/render.js video [--scene id,...]   # image fixe + boucle de 30 s, remote.json
node tools/imaginaire/render.js seam                     # raccord de la boucle publiée
node tools/imaginaire/render.js all                      # tout, et out/report.json
```

Tout passe par le **mode enregistrement** du runtime
(`index.html?record=1&scene=<id>&t=<s>&w=<px>&h=<px>&decor=<json>`, puis
`window.eventideRenderAt(t, decor)` pour les images suivantes) : l'image est une fonction pure du
temps modulo 30 s, donc l'image à 30 s est celle à 0 s et la boucle n'a pas de raccord.

- **Planche** : pour chaque scène, le décor par défaut, sans décor et au maximum, à 0, 7,5, 15 et
  22,5 s, puis chaque élément seul à 100. C'est l'outil de relecture de la direction artistique.
- **Boucle** : 720 images (24 i/s × 30 s) rendues en 720 × 1280 par Chromium sans écran (WebGL
  logiciel, SwiftShader, anticrénelage 4×), gardées sans perte (`out/<id>-master.mkv`), puis
  agrandies en 1080 × 1920 (Lanczos) et encodées en H.264 High, yuv420p, image clé toutes les 2 s,
  sans images B, sans son, au plus petit CRF (au plus 30) qui tient dans 2,5 Mo (contrat § 8), sinon
  au plus petit qui tient dans 4 Mo (`aurore` et `ondes`, trop dégradées à 2,5 Mo). Le rendu en
  720 × 1280 divise le temps de calcul par 2,3 ; à 2,5 Mo pour 30 s, l'encodeur ne garde de toute
  façon pas de détail plus fin. `--reuse-master` réencode sans refaire les images ; `--strict`
  impose 2,5 Mo quelle que soit la qualité (`aurore` passerait en CRF 33, `ondes` en CRF 36 : les
  points lointains et faibles s'effacent).
- **Image fixe** : la première image décodée de la vidéo publiée (contrat § 8), en JPEG de la
  meilleure qualité qui tient dans 300 Ko.
- **Sorties** : toutes les images fixes dans `app/assets/landscapes/<id>.jpg` (embarquées : les
  vignettes des scènes Premium s'affichent aussi pour un utilisateur gratuit) ; la boucle de la
  scène gratuite dans `app/assets/landscapes/foret-lucioles.mp4`, les boucles Premium dans
  `content/videos/paysages/<id>.mp4` (S3), puis `app/assets/landscapes/remote.json` est réécrit
  (`tools/media/remote_manifest.py`). Une image fixe Premium n'est jamais dans `content/images/` :
  le contrôle de l'APK de production l'interdirait.
- **Raccord** : `seam` décode la boucle (et le master) en gris 270 × 480 et compare l'écart moyen
  entre la dernière et la première image (`seam_mad`) à l'écart médian entre deux images
  consécutives (`step_median_mad`) : un rapport proche de 1 signifie un raccord invisible.

Temps de calcul sur 4 cœurs sans GPU : 1 à 4 s par image selon la scène, soit environ 1 h 30 pour
les six boucles.
