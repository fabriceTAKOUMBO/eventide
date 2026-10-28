# Contenus Premium (S3) — fichiers provisoires

Ce dossier contient les contenus Premium destinés au bucket S3 (distribués par
CloudFront via `POST /content/urls`, voir `docs/api/contrat-v1.md`).

**Les fichiers actuels sont des substituts synthétiques**, générés à partir de
rien par `tools/media/generate_audio.py` : aucun enregistrement, aucun
échantillon, aucun droit tiers. Ils servent à tester l'application de bout en
bout (téléchargement, cache, boucles, mixage). Ils devront être **remplacés par
les contenus sous licence** avant la mise en production, en gardant les mêmes
clés.

## Disposition des clés S3

Le chemin d'un fichier sous `content/` est sa clé S3 :

| Clé S3 | Contenu |
|---|---|
| `audio/sons/<id>.ogg` | boucle de son de nature Premium |
| `audio/musiques/<id>.ogg` | boucle musicale Premium |
| `images/paysages/<id>.jpg` | image fixe d'un paysage Premium : exactement la première image de sa vidéo (veille, vignettes, « réduire les animations », chargement) |
| `videos/paysages/<id>.mp4` | vidéo d'un paysage Premium : boucle sans raccord, H.264, sans son, 2,5 Mo au plus |

Les `<id>` sont ceux de `app/assets/catalog.json`. Seuls les éléments
`"gratuit": false` vont sur S3 ; les éléments gratuits sont embarqués dans
l'application (`app/assets/audio/...`, `app/assets/landscapes/<id>.mp4` et
`<id>.jpg`). L'application ne demande une vidéo ou une image de paysage que si
son identifiant figure dans `app/assets/landscapes/remote.json`, réécrit par
`tools/media/process_video.py` d'après ce dossier : ajouter un fichier ici sans
relancer le script ne le rend pas visible dans l'application.

## Fichiers présents

| Clé | Durée de boucle |
|---|---|
| `audio/sons/tonnerre.ogg` | 47 s |
| `audio/sons/vagues.ogg` | 43 s |
| `audio/sons/feu-de-camp.ogg` | 26 s |
| `audio/sons/grillons.ogg` | 23 s |
| `audio/sons/chouette.ogg` | 39 s |
| `audio/musiques/harpe.ogg` | 40,32 s |
| `audio/musiques/flute.ogg` | 36,8 s |
| `audio/musiques/guitare-douce.ogg` | 28,8 s |
| `audio/musiques/cordes-lentes.ogg` | 44,8 s |
| `audio/musiques/boite-a-musique.ogg` | 26,4 s |
| `audio/musiques/bols-tibetains.ogg` | 45,5 s |

| Clé | Contenu |
|---|---|
| `images/paysages/pluie-ville.jpg` | image fixe (720 × 1280, 69 ko) |
| `videos/paysages/pluie-ville.mp4` | 7,6 s, 24 i/s, 720 × 1280, 2,28 Mo |

Provenance et droits de chaque fichier : [`LICENCES.md`](LICENCES.md). Les
vidéos de tiers de `medias-test/` (tests internes, non diffusables) ne vont
**jamais** ici ni sur S3.

## Format audio

Les fichiers sont en Ogg Opus, 48 kHz stéréo, 64 kbit/s, à environ −23 LUFS,
avec une crête vraie ≤ −1 dBTP. Ce sont des boucles parfaites : chaque fichier
se décode en exactement le nombre d'échantillons de la boucle (pre-skip de
15 360 échantillons, sans coupe de fin). Les fichiers sous licence devront
respecter les mêmes contraintes pour boucler sans couture. La méthode est
décrite dans `tools/media/README.md`.

## Téléversement (exemple)

```sh
aws s3 cp content/audio s3://<bucket>/audio --recursive --content-type audio/ogg
aws s3 cp content/images s3://<bucket>/images --recursive --content-type image/jpeg
aws s3 cp content/videos s3://<bucket>/videos --recursive --content-type video/mp4
```

(Exemple seulement : aucun agent ne fait d'appel AWS ; le téléversement est fait
par le product owner. Les clés `videos/paysages/<id>.mp4` doivent aussi être
acceptées par `POST /content/urls`, contrat § 8.)

## Régénération

```sh
python3 tools/media/generate_audio.py     # sons et musiques
python3 tools/media/process_video.py      # vidéos et images de paysages (depuis medias-bruts/)
```
