# Contenus de tiers (YouTube) — tests internes uniquement, NON DIFFUSABLES

**Contenus de tiers (YouTube) — tests internes uniquement, NON DIFFUSABLES, à retirer avant toute bêta (même fermée) et toute publication.**

Ces vidéos ont été fournies par le product owner pour essayer les paysages animés sur son propre téléphone, avant d'avoir des vidéos dont nous détenons les droits. Nous n'avons **aucun droit** de les distribuer.

| Dossier | Contenu |
|---|---|
| `originaux/` | Fichiers reçus, inchangés (`toits-pluie.mp4`, `ciel-etoile.mp4`) |
| `videos/paysages/<id>.mp4` | Boucles traitées par `tools/media/process_video.py` (sans son, boucle sans raccord) |
| `images/paysages/<id>.jpg` | Image fixe de chaque boucle (sa première image) |
| `audio/sons/<id>.ogg` | Ambiance tirée de la bande son (`ambiance-toits-pluie`, tonnerre retiré, `tools/media/make_ambiance.py`) |

Règles :

- **Uniquement la version démo** (« Eventide Démo ») : la CI les copie dans `app/assets/landscapes/` juste avant de la construire (`app/tool/ci/bundle_demo_media.sh`). Jamais dans la version de production, jamais sur S3.
- **Ne jamais les copier** sous `content/` ni sous `app/assets/` dans git : la CI échoue si un de ces fichiers (ou un fichier identique) s'y trouve (`app/tool/ci/check_test_media.sh`), et vérifie que l'APK de production n'en contient aucun (`app/tool/ci/check_apk_contents.sh`).
- **Avant toute bêta, même fermée, et toute publication** : supprimer ce dossier, retirer les lignes `toits-pluie` et `ciel-etoile` de `ITEMS` dans `tools/media/process_video.py`, la ligne `ambiance-toits-pluie` de `ITEMS` dans `tools/media/make_ambiance.py` et de `app/assets/catalog.json` (et de sa copie `backend/eventide/catalog.json`), et de `content/LICENCES.md`, et les remplacer par des vidéos dont nous avons les droits.
