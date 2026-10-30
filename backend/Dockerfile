# Eventide — image de l'API Django (gunicorn, WSGI), construite pour ECS Fargate ARM64
# (Graviton) et utilisable en x86_64 : images de base multi-architecture.
#
# Construction : docker build -t eventide-api backend/
# Exécution : système de fichiers racine en lecture seule possible ; seul /tmp doit être
# inscriptible (tmpfs en local, volume éphémère sur ECS Fargate).
#
# Images de base épinglées par version ET par empreinte (index multi-architecture), comme
# Candidature Express, écrites en clair dans chaque FROM pour que Dependabot les mette à jour.

# --- uv (binaire officiel, version épinglée) ------------------------------------------
FROM ghcr.io/astral-sh/uv:0.12.24@sha256:3af4716e991d6956a41e573eab705d0ee08500cd829ed30293eb8472f372c65a AS uv

# --- Étape de construction : dépendances + fichiers statiques ---------------------------
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258 AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON=/usr/local/bin/python3.12 \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PYTHONDONTWRITEBYTECODE=1

COPY --from=uv /uv /usr/local/bin/uv

WORKDIR /app

# Dépendances seules d'abord (couche mise en cache tant que uv.lock ne change pas).
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project

COPY . /app

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

# collectstatic avec des valeurs jetables, valables uniquement pendant la construction (variables
# d'une seule commande RUN, jamais écrites dans l'image). Aucune connexion réseau à l'import.
RUN DJANGO_SETTINGS_MODULE=config.settings.prod \
    DJANGO_READ_DOT_ENV=false \
    DJANGO_SECRET_KEY="build-only-$(python -c 'import secrets; print(secrets.token_urlsafe(64))')" \
    DATABASE_URL="postgres://build:build@127.0.0.1:5432/build" \
    ALLOWED_HOSTS="localhost" \
    PUBLIC_WEB_BASE_URL="https://build.invalid" \
    /app/.venv/bin/python manage.py collectstatic --noinput

# Autorités de certification RDS (PostgreSQL en sslmode=verify-full), vérifiées par empreinte
# (même fichier et même empreinte que Candidature Express, contrôlés le 28 octobre 2026).
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b --chmod=0444 \
    https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/certs/rds-global-bundle.pem
# ADD --chmod s'applique aussi au dossier qu'il crée : le rendre traversable.
RUN chmod 0755 /app/certs

# --- Image finale : pas de compilateur, pas de uv, utilisateur non-root ----------------
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258 AS runtime

LABEL org.opencontainers.image.title="eventide-api" \
      org.opencontainers.image.source="https://github.com/fabriceTAKOUMBO/eventide" \
      org.opencontainers.image.description="API Django d'Eventide"

# Journal d'accès de gunicorn : chemin sans la chaîne de requête (%(U)s, jamais %(r)s).
# WEB_CONCURRENCY et GUNICORN_CMD_ARGS sont remplacés par la définition de tâche ECS
# (Terraform), liés au budget de connexions PostgreSQL.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:${PATH}" \
    DJANGO_SETTINGS_MODULE=config.settings.prod \
    DJANGO_READ_DOT_ENV=false \
    TMPDIR=/tmp \
    WEB_CONCURRENCY=1 \
    GUNICORN_CMD_ARGS="--worker-class gthread --threads 8 --timeout 30 --graceful-timeout 25 --keep-alive 75 --max-requests 2000 --max-requests-jitter 200 --worker-tmp-dir /tmp --no-control-socket --access-logfile - --access-logformat '%(h)s %(t)s \"%(m)s %(U)s %(H)s\" %(s)s %(b)s %(L)s' --error-logfile - --log-level info"

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin app

# ffmpeg et ffprobe : traitement des fichiers publiés depuis le tableau de bord (contrat § 14).
# La tâche ev-<env>-media lance cette même image (python manage.py process_media <uuid>).
# Paquet Debian signé (mises à jour de sécurité à chaque reconstruction), sans recommandés.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && ffmpeg -hide_banner -encoders | grep -q libx264 \
 && ffmpeg -hide_banner -encoders | grep -q libopus \
 && ffmpeg -hide_banner -filters | grep -q zscale

WORKDIR /app

# Code, environnement virtuel et fichiers statiques appartiennent à root : lisibles, non modifiables.
COPY --from=builder /app /app

RUN chmod 1777 /tmp
VOLUME ["/tmp"]

USER 10001:10001

# Le bundle RDS doit être lisible par l'utilisateur applicatif (sinon aucune connexion TLS).
RUN test -r /app/certs/rds-global-bundle.pem

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/v1/health', timeout=4).status == 200 else 1)"]

CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000"]
