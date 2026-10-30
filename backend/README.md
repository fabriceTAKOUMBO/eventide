# Eventide — API (Django)

API de l'application Android Eventide (« Full Relax ») : installations, compte Google facultatif, droits et achats Google Play, partage de mix, adresses signées du contenu, catalogue publié, tableau de bord d'administration et pages web du domaine. Le contrat fait foi : [`docs/api/contrat-v1.md`](../docs/api/contrat-v1.md).

| | |
|---|---|
| Pile | Python 3.12, Django 5.2 + Django REST Framework, gunicorn, `uv`, `pytest`, `ruff`, `boto3`, ffmpeg (traitement des médias) |
| Base | PostgreSQL 16 (instance partagée de CINAF en production, base `eventide`) ; **pas de Redis** : limites de débit et compteurs en base, par écriture conditionnelle atomique |
| Hébergement | ECS Fargate ARM64 derrière l'ALB partagé ([ADR](../docs/infra/hebergement-mutualise.md)) ; tâche ponctuelle `ev-<env>-media` (même image) pour le traitement des fichiers publiés |
| Catalogue | [`eventide/catalog.json`](eventide/catalog.json), copie exacte de `app/assets/catalog.json`, et [`eventide/remote.json`](eventide/remote.json), copie exacte de `app/assets/landscapes/remote.json` (un test échoue s'ils diffèrent) ; le catalogue publié y ajoute les éléments publiés depuis le tableau de bord (contrat § 13) |

## Démarrer en local

Prérequis : `uv`, un PostgreSQL 16 (encodage UTF-8), `ffmpeg` (avec libx264, libopus et zscale : paquet `ffmpeg` de Debian ou d'Ubuntu).

```bash
cd backend
uv sync
cp .env.example .env          # puis renseigner DJANGO_SECRET_KEY
# Base locale (exemple) : rôle ev_app (CREATEDB pour les tests) et base eventide
#   CREATE ROLE ev_app LOGIN CREATEDB PASSWORD 'ev_local_dev_only';
#   CREATE DATABASE eventide OWNER ev_app;
uv run python manage.py migrate
uv run python manage.py runserver 127.0.0.1:8000
```

En développement, `PLAY_INTEGRITY_ENFORCED=false` (aucun jeton Play Integrity sans version Play Store) est la valeur par défaut de `config.settings.dev`.

Tableau de bord en local (`http://127.0.0.1:8000/tableau/`) : renseigner `ADMIN_EMAILS`, `GOOGLE_WEB_CLIENT_ID` (client OAuth web dont l'origine autorisée est `http://127.0.0.1:8000`) et `GOOGLE_OAUTH_CLIENT_IDS`. Sans tâche ECS configurée, le traitement tourne dans un fil de l'API seulement si `DEBUG=true` ; l'envoi direct vers S3 demande un bucket. Pour essayer le traitement seul : `MEDIA_STORAGE=local:/tmp/ev-media`, déposer la source dans `/tmp/ev-media/uploads/<uuid>/source`, puis `uv run python manage.py process_media <uuid-de-l'élément>`.

## Contrôles (définition de « terminé »)

```bash
uv run ruff check .
uv run ruff format --check .
uv run bandit -c pyproject.toml -r apps config
uv run python manage.py makemigrations --check --dry-run
uv run pytest --cov
```

Les tests utilisent PostgreSQL (`DATABASE_URL`, par défaut `127.0.0.1:55433/eventide`) et ffmpeg, et ne joignent jamais Google ni AWS : les appels HTTP sont simulés (`responses`), chaque client AWS est enveloppé dans un `Stubber` de botocore (un appel non prévu échoue au lieu de partir vers AWS) et les identifiants AWS des tests sont factices. Lancer sans identifiants : `env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN uv run pytest`.

## Organisation

| Dossier | Rôle |
|---|---|
| `config/settings/` | `base`, `dev`, `test`, `prod` (comme Candidature Express) |
| `apps/core` | enveloppe d'erreur, santé (`/v1/health`, `/v1/health/ready`), journaux JSON, catalogue de base, limites de débit en base, purge planifiée |
| `apps/installations` | `POST /v1/installations`, jeton porteur haché (SHA-256), vérification Play Integrity |
| `apps/accounts` | liaison Google (jeton d'identité vérifié côté serveur), export et suppression (RGPD) |
| `apps/entitlements` | droits, achats (API Google Play Developer, acquittement), notifications temps réel (RTDN) |
| `apps/shares` | partage d'un mix sous un code court |
| `apps/content` | adresses CloudFront signées (clés versionnées `.v<media_rev>` des éléments publiés) |
| `apps/publishing` | catalogue publié (`GET /v1/catalog`, contrat § 13), tableau de bord `/tableau/` (contrat § 14), envoi direct vers S3, tâche `process_media` (ffmpeg) |
| `apps/web` | pages `/m/<code>`, `/s`, `/.well-known/assetlinks.json`, `/confidentialite` |

## Tableau de bord et publication (contrat § 13 et § 14)

- **Connexion** : bouton Google (GIS), jeton vérifié côté serveur (signature, audience `GOOGLE_OAUTH_CLIENT_IDS`, `email_verified`), adresse dans `ADMIN_EMAILS`. L'adresse n'est jamais enregistrée : la session (table `django_session`, 8 h, cookie `ev_tableau` limité à `/tableau/`) ne garde que son empreinte SHA-256, revérifiée à chaque requête. 10 essais par 15 minutes par adresse IP.
- **Publication** : création de l'élément → formulaire signé S3 (`uploads/<uuid>/source`, 300 Mo au plus, valable 15 minutes, sans `acl`) → envoi direct du navigateur → `ecs:RunTask` de la tâche `ev-<env>-media` → `pret` → publier (`revision` + 1). Chaque envoi prend une révision de fichiers jamais utilisée par l'élément : une clé S3 n'est écrite qu'une fois (pas de cache CloudFront périmé).
- **Une seule tâche média à la fois** ([ADR § 12.5](../docs/infra/hebergement-mutualise.md)) : pendant un traitement, un nouvel envoi est refusé avec un message clair ; un fichier arrivé entre-temps attend en `envoi` (sa source reste sur S3) et la page relance le traitement toutes les 15 s, ou par le bouton « Lancer le traitement ». `RunTask` : `count` 1, capacité par défaut du cluster (ni `launchType` ni `capacityProviderStrategy`), `propagateTags=TASK_DEFINITION`, seule la commande du conteneur `media` est remplacée.
- **Traitement** (`apps/publishing/media.py`, paramètres des outils de `tools/media/`) : boucle vidéo 1080 × 1920 de 10 s au plus, fondu enchaîné de 1,5 s, H.264 sans son, CRF le plus bas (18 à 36) sous 2,5 Mo, image fixe = première image (JPEG ≤ 300 Ko) ; boucle audio sans raccord d'au moins 60 s, −23 LUFS, crête vraie ≤ −1 dBTP, Opus 96 kbit/s sans trou à la reprise.
- **Base partagée** : une seule lecture de la révision (clé primaire) par requête qui valide contre le catalogue ; la tâche média ferme sa connexion pendant le travail d'ffmpeg (deux courtes transactions). Pour cette tâche, `DB_POOL_MAX_SIZE=0` est recommandé (aucune connexion gardée ouverte).

| Réglage | Rôle |
|---|---|
| `ADMIN_EMAILS` | adresses des administrateurs (secret) ; vide ou `A_REMPLACER` : toute connexion est refusée |
| `GOOGLE_WEB_CLIENT_ID` | client OAuth web du bouton (aussi dans `GOOGLE_OAUTH_CLIENT_IDS`) |
| `CONTENT_BUCKET`, `CONTENT_BUCKET_REGION` | bucket de contenu (envoi : `https://<bucket>.s3.<région>.amazonaws.com`) |
| `MEDIA_TASK_CLUSTER`, `MEDIA_TASK_DEFINITION`, `MEDIA_TASK_CONTAINER`, `MEDIA_TASK_SUBNETS`, `MEDIA_TASK_SECURITY_GROUPS` | tâche `ev-<env>-media` (Fargate, sans IP publique) |
| `MEDIA_STORAGE` | `s3` (défaut avec un bucket) ou `local:<dossier>` |

## Règles à ne pas casser

- **Aucun jeton n'est journalisé** (installation, Google, Play Integrity, achat) ni l'adresse d'un administrateur : filtre de journaux en seconde ligne (`apps/core/logging.py`).
- Une forme d'API qui change s'écrit d'abord dans le contrat.
- Les connexions PostgreSQL d'une tâche sont bornées par le pool (`DB_POOL_MAX_SIZE`) : Terraform refuse un dimensionnement qui dépasserait la limite du rôle `ev_app`.
- Les sources envoyées sont des fichiers non fiables : ffmpeg ne les lit qu'en fichier local et avec les seuls formats attendus (`-protocol_whitelist file`, `-format_whitelist`).

## Tâches planifiées et ponctuelles

| Commande | Fréquence | Rôle |
|---|---|---|
| `manage.py purge_expired` | quotidienne | compteurs de débit expirés, journal du tableau de bord de plus d'un an, sessions expirées |
| `manage.py finalize_purchases` | toutes les heures | acquitte les achats pas encore finalisés (Google rembourse après 3 jours) |
| `manage.py process_media <uuid>` | à la demande (lancée par l'API, tâche `ev-<env>-media`) | traite le fichier envoyé d'un élément ; idempotente ; code de sortie 0 pour un échec prévu (fichier illisible, absent, trop court : état `echec`), non nul seulement pour une erreur inattendue (le propriétaire est alerté) |

## Déploiement

Image construite par le workflow **Deploy** (ARM64), migrations en tâche ponctuelle (rôle `ev_migrator`), service ECS mis à jour : [premier déploiement](../docs/runbooks/premier-deploiement.md).
