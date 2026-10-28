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
| `images/paysages/<id>.jpg` | image de paysage Premium (pas encore fournie) |

Les `<id>` sont ceux de `app/assets/catalog.json`. Seuls les éléments
`"gratuit": false` vont sur S3 ; les éléments gratuits sont embarqués dans
l'application (`app/assets/audio/...`).

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

Aucune image `images/paysages/<id>.jpg` n'est encore fournie.

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
```

## Régénération

```sh
python3 tools/media/generate_audio.py
```
