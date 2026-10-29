# Eventide — API (Django)

API de l'application Android Eventide : installations, compte Google facultatif, droits et achats Google Play, partage de mix, adresses signées du contenu et pages web du domaine. Le contrat fait foi : [`docs/api/contrat-v1.md`](../docs/api/contrat-v1.md).

| | |
|---|---|
| Pile | Python 3.12, Django 5.2 + Django REST Framework, gunicorn, `uv`, `pytest`, `ruff` |
| Base | PostgreSQL 16 (instance partagée de CINAF en production, base `eventide`) ; **pas de Redis** : limites de débit et compteurs en base, par écriture conditionnelle atomique |
| Hébergement | ECS Fargate ARM64 derrière l'ALB partagé ([ADR](../docs/infra/hebergement-mutualise.md)) |
| Catalogue | [`eventide/catalog.json`](eventide/catalog.json), copie exacte de `app/assets/catalog.json` (un test échoue s'ils diffèrent) |

## Démarrer en local

Prérequis : `uv`, un PostgreSQL 16.

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

## Contrôles (définition de « terminé »)

```bash
uv run ruff check .
uv run ruff format --check .
uv run bandit -c pyproject.toml -r apps config
uv run python manage.py makemigrations --check --dry-run
uv run pytest --cov
```

Les tests utilisent PostgreSQL (`DATABASE_URL`, par défaut `127.0.0.1:55433/eventide`) et ne joignent jamais Google ni AWS : les appels HTTP sont simulés (`responses`).

## Organisation

| Dossier | Rôle |
|---|---|
| `config/settings/` | `base`, `dev`, `test`, `prod` (comme Candidature Express) |
| `apps/core` | enveloppe d'erreur, santé (`/v1/health`, `/v1/health/ready`), journaux JSON, catalogue, limites de débit en base, purge planifiée |
| `apps/installations` | `POST /v1/installations`, jeton porteur haché (SHA-256), vérification Play Integrity |
| `apps/accounts` | liaison Google (jeton d'identité vérifié côté serveur), export et suppression (RGPD) |
| `apps/entitlements` | droits, achats (API Google Play Developer, acquittement), notifications temps réel (RTDN) |
| `apps/shares` | partage d'un mix sous un code court |
| `apps/content` | adresses CloudFront signées |
| `apps/web` | pages `/m/<code>`, `/s`, `/.well-known/assetlinks.json`, `/confidentialite` |

## Règles à ne pas casser

- **Aucun jeton n'est journalisé** (installation, Google, Play Integrity, achat) : filtre de journaux en seconde ligne (`apps/core/logging.py`).
- Une forme d'API qui change s'écrit d'abord dans le contrat.
- Les connexions PostgreSQL d'une tâche sont bornées par le pool (`DB_POOL_MAX_SIZE`) : Terraform refuse un dimensionnement qui dépasserait la limite du rôle `ev_app`.

## Tâches planifiées

| Commande | Fréquence | Rôle |
|---|---|---|
| `manage.py purge_expired` | quotidienne | compteurs de débit expirés |
| `manage.py finalize_purchases` | toutes les heures | acquitte les achats pas encore finalisés (Google rembourse après 3 jours) |

## Déploiement

Image construite par le workflow **Deploy** (ARM64), migrations en tâche ponctuelle (rôle `ev_migrator`), service ECS mis à jour : [premier déploiement](../docs/runbooks/premier-deploiement.md).
