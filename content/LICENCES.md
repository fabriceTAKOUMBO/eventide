# Provenance et droits des contenus

Registre de chaque média distribué ou testé par Eventide : d'où il vient, qui en détient les droits, ce qu'on a le droit d'en faire. À tenir à jour à chaque ajout, avant tout téléversement sur S3 ou toute version publiée.

## Vidéos et images de paysages (générées par le product owner)

| Fichier | Paysage | Source | Statut |
|---|---|---|---|
| `medias-bruts/videos/cascade-foret.mp4` (original) → `app/assets/landscapes/cascade-foret.mp4` et `cascade-foret.jpg` (embarqués, gratuit) | `cascade-foret` | Généré par le product owner avec Google Gemini (Veo), 28 octobre 2026 | Usage commercial à confirmer selon les conditions de Google |
| `medias-bruts/videos/pluie-ville.mp4` (original) → `content/videos/paysages/pluie-ville.mp4` et `content/images/paysages/pluie-ville.jpg` (S3, Premium) | `pluie-ville` | Généré par le product owner avec Google Gemini (Veo), 28 octobre 2026 | Usage commercial à confirmer selon les conditions de Google |

Remarques :

- **SynthID** : les vidéos produites par Veo portent un filigrane numérique invisible (SynthID) inscrit dans l'image. Notre traitement (boucle, compression) ne cherche ni à le retirer ni à le masquer ; il peut en subsister des traces. Aucun filigrane visible n'apparaît dans les fichiers reçus.
- **À confirmer avant la production** : les conditions de Google applicables au compte utilisé (Gemini grand public, Google One AI, Workspace…) pour un usage commercial dans une application payante, et l'éventuelle obligation de signaler un contenu généré par IA (Google Play, AI Act). Garder la preuve de génération (date, compte, invite) comme le demande le dossier (section 9).
- Les fichiers de l'application et de S3 sont dérivés des originaux de `medias-bruts/` par `tools/media/process_video.py` (boucle sans raccord, son retiré, éclairs adoucis pour `pluie-ville`, image fixe = première image de la boucle).

## Sons et musiques

| Fichiers | Source | Statut |
|---|---|---|
| `app/assets/audio/**/*.ogg`, `content/audio/**/*.ogg` | Générés par nous à partir de rien (`tools/media/generate_audio.py`, synthèse numpy) | Généré par nous, aucun droit tiers. Substituts provisoires, à remplacer par les contenus sous licence en gardant les mêmes clés |

## Matériel de test NON DIFFUSABLE (`medias-test/`)

| Fichier | Paysage | Source | Statut |
|---|---|---|---|
| `medias-test/originaux/toits-pluie.mp4` → `medias-test/videos/paysages/toits-pluie.mp4` et `medias-test/images/paysages/toits-pluie.jpg` | `toits-pluie` | Vidéo YouTube de tiers (« Supere as Noites Sem Sono com Chuva Forte, Trovões Retumbantes no Telhado de Zinco »), fournie par le product owner | **Contenu de tiers, non diffusable.** Tests internes sur le téléphone du product owner uniquement |
| `medias-test/originaux/ciel-etoile.mp4` → `medias-test/videos/paysages/ciel-etoile.mp4` et `medias-test/images/paysages/ciel-etoile.jpg` | `ciel-etoile` | Vidéo YouTube de tiers (« Mystery of the Universe », court métrage de musique relaxante), fournie par le product owner | **Contenu de tiers, non diffusable.** Tests internes sur le téléphone du product owner uniquement |

Ces fichiers ne vont **jamais** sur S3 ni dans la version de production : seule la version démo les copie dans ses ressources au moment de la construction, et la CI échoue si l'un d'eux apparaît sous `content/` ou `app/assets/`, ou dans l'APK de production. **À retirer avant toute bêta, même fermée, et toute publication** (voir `medias-test/LISEZMOI.md`).
