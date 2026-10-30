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
| `audio/sons/<id>.ogg` | boucle de son de nature Premium, ambiance d'un paysage Premium (`ambiance-<paysage>`), ou variante d'un son à événements (`tonnerre-coup-01`…, contrat § 11) |
| `audio/musiques/<id>.ogg` | boucle musicale Premium |
| `images/paysages/<id>.jpg` | image fixe d'un paysage filmé Premium : exactement la première image de sa vidéo (veille, vignettes, « réduire les animations », chargement). Les images fixes des paysages imaginaires (3D) sont embarquées dans l'application (`app/assets/landscapes/<id>.jpg`), jamais ici |
| `videos/paysages/<id>.mp4` | vidéo d'un paysage Premium : boucle sans raccord, H.264, sans son, 2,5 Mo au plus ; pour un paysage imaginaire, la boucle de fond d'écran tirée de la scène 3D (`tools/imaginaire/render.js`), 4 Mo au plus pour `aurore` et `ondes` (écart au contrat, `docs/app/architecture.md` § 20.5) |

Les `<id>` sont ceux de `app/assets/catalog.json`. Seuls les éléments
`"gratuit": false` vont sur S3 ; les éléments gratuits sont embarqués dans
l'application (`app/assets/audio/...`, `app/assets/landscapes/<id>.mp4` et
`<id>.jpg`). L'application ne demande une vidéo ou une image de paysage que si
son identifiant figure dans `app/assets/landscapes/remote.json`, réécrit par
`tools/media/process_video.py` d'après ce dossier : ajouter un fichier ici sans
relancer le script ne le rend pas visible dans l'application. Le même fichier liste
aussi les sons et musiques présents ici (`sons`, `musiques`) : l'application ne
demande jamais un son absent (par exemple l'ambiance de test `ambiance-toits-pluie`,
démo seulement). Il est réécrit par chaque outil qui écrit ici (`process_video.py`,
`make_ambiance.py`, `generate_audio.py`).

## Fichiers présents

| Clé | Durée de boucle |
|---|---|
| `audio/sons/ambiance-pluie-ville.ogg` | 67 s (ambiance de `pluie-ville`, tirée de sa vidéo) |
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
| `audio/sons/tonnerre-<partie>-NN.ogg` (17 fichiers : `avant` ×3, `coup` ×4, `proche` ×3, `replique` ×3, `lointain` ×4) | parties du son à événements `tonnerre` (5,8 à 25,4 s chacune, jouées en séquences d'orage, jamais en boucle) : tirées du vrai tonnerre de la bande son de `pluie-ville`, pluie retirée (`tools/media/make_thunder.py`) |

| Clé | Contenu |
|---|---|
| `images/paysages/pluie-ville.jpg` | image fixe (720 × 1280, 69 ko) |
| `videos/paysages/pluie-ville.mp4` | 7,6 s, 24 i/s, 720 × 1280, 1,73 Mo (éclairs effacés) |

Provenance et droits de chaque fichier : [`LICENCES.md`](LICENCES.md). Les
vidéos de tiers de `medias-test/` (tests internes, non diffusables) ne vont
**jamais** ici ni sur S3.

## Format audio

Les fichiers sont en Ogg Opus, 48 kHz stéréo, 64 kbit/s (96 kbit/s pour les
ambiances, enregistrements réels), à environ −23 LUFS, avec une crête vraie ≤ −1 dBTP.
Les variantes d'un son à événements ne sont pas des boucles : un seul coup, du
silence au silence, au même niveau (−23 LUFS intégrés). Ce sont des boucles parfaites : chaque fichier
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
python3 tools/media/generate_audio.py     # sons, musiques et variantes du tonnerre (substituts)
python3 tools/media/process_video.py      # vidéos et images de paysages (depuis medias-bruts/)
python3 tools/media/make_ambiance.py      # ambiances des paysages (bande son des vidéos)
node tools/imaginaire/render.js video     # boucles et images fixes des paysages imaginaires (3D)
```
