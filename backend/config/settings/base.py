"""Settings shared by every environment.

Configuration comes only from environment variables (django-environ); the template is
``backend/.env.example``. The environment-specific modules (dev, test, prod) import this one
and override what they need. Nothing here opens a network connection at import time.
"""

from __future__ import annotations

import os
from pathlib import Path

import environ

BASE_DIR = Path(__file__).resolve().parent.parent.parent  # backend/

env = environ.Env()

# A local ``.env`` file is read in development only (test settings disable it and the
# production image contains none). Real environment variables always win.
_dot_env = BASE_DIR / ".env"
if os.environ.get("DJANGO_READ_DOT_ENV", "true").lower() != "false" and _dot_env.is_file():
    environ.Env.read_env(str(_dot_env), overwrite=False)

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------
DEBUG = env.bool("DEBUG", default=False)
SECRET_KEY = env.str("DJANGO_SECRET_KEY")
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=[])
CSRF_TRUSTED_ORIGINS = env.list("CSRF_TRUSTED_ORIGINS", default=[])

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
APPEND_SLASH = False

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    # Database sessions: the administration dashboard only (/tableau/, contract § 14).
    "django.contrib.sessions",
    "django.contrib.staticfiles",
    "rest_framework",
    "apps.core",
    "apps.accounts",
    "apps.installations",
    "apps.entitlements",
    "apps.shares",
    "apps.content",
    "apps.web",
    "apps.publishing",
]

MIDDLEWARE = [
    # First: answers /v1/health and /v1/health/ready before host validation and the HTTPS
    # redirect (load balancer probes use plain HTTP and the task IP as Host).
    "apps.core.middleware.HealthCheckMiddleware",
    "apps.core.middleware.RequestIdMiddleware",
    "apps.core.middleware.RequestSizeLimitMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    # Lazy: the session table is only read when a view touches ``request.session`` (dashboard
    # pages under /tableau/); the v1 API never does, so it gets no cookie and no query.
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {"context_processors": ["django.template.context_processors.request"]},
    },
]

# ---------------------------------------------------------------------------
# Database (PostgreSQL 16; the production instance is shared, see
# docs/infra/hebergement-mutualise.md). No Redis: rate limits live here.
# ---------------------------------------------------------------------------
DATABASES = {"default": env.db("DATABASE_URL")}
_db_options = DATABASES["default"].setdefault("OPTIONS", {})
# No JIT on short OLTP queries (same choice as Candidature Express).
_db_options["options"] = " ".join(filter(None, (_db_options.get("options", ""), "-c jit=off")))
# Connection pool per gunicorn worker (psycopg_pool, Django 5.1+). Its maximum size bounds the
# connections of a task whatever the number of threads: Terraform checks
# workers x DB_POOL_MAX_SIZE x tasks against the role's CONNECTION LIMIT (ev_app: 10).
DB_POOL_MAX_SIZE = env.int("DB_POOL_MAX_SIZE", default=0)
if DB_POOL_MAX_SIZE > 0:
    _db_options["pool"] = {
        "min_size": 1,
        "max_size": DB_POOL_MAX_SIZE,
        "timeout": env.float("DB_POOL_TIMEOUT_SECONDS", default=10.0),
    }
    DATABASES["default"]["CONN_MAX_AGE"] = 0
    # Pooled connections are checked before use: the shared instance closes our idle sessions
    # (idle_session_timeout set on our roles by the bootstrap), and a closed one is replaced
    # instead of failing a request.
    DATABASES["default"]["CONN_HEALTH_CHECKS"] = True
else:
    DATABASES["default"]["CONN_MAX_AGE"] = env.int("DB_CONN_MAX_AGE", default=60)
    DATABASES["default"]["CONN_HEALTH_CHECKS"] = True

# ---------------------------------------------------------------------------
# Internationalisation
# ---------------------------------------------------------------------------
LANGUAGE_CODE = "fr"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

# ---------------------------------------------------------------------------
# Static files (web pages of contract § 9 only)
# ---------------------------------------------------------------------------
STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage"},
}

# ---------------------------------------------------------------------------
# Request hardening
# ---------------------------------------------------------------------------
# The largest bodies are a scene (POST /shares) and 30 content keys: 64 KiB is plenty.
DATA_UPLOAD_MAX_MEMORY_SIZE = 64 * 1024
DATA_UPLOAD_MAX_NUMBER_FIELDS = 200
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "no-referrer"
SECURE_CROSS_ORIGIN_OPENER_POLICY = "same-origin"
X_FRAME_OPTIONS = "DENY"
CSRF_COOKIE_HTTPONLY = True

# ---------------------------------------------------------------------------
# Administration dashboard (/tableau/, contract § 14): session and CSRF cookies are scoped to
# its path, Strict same-site, Secure outside DEBUG. Sessions last 8 hours from sign-in (the
# session row is not rewritten at each request); expired rows are purged daily.
# ---------------------------------------------------------------------------
SESSION_ENGINE = "django.contrib.sessions.backends.db"
SESSION_COOKIE_NAME = "ev_tableau"
SESSION_COOKIE_PATH = "/tableau/"
SESSION_COOKIE_AGE = 8 * 3600
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = "Strict"
SESSION_COOKIE_SECURE = not DEBUG
SESSION_SAVE_EVERY_REQUEST = False
CSRF_COOKIE_NAME = "ev_csrf"
CSRF_COOKIE_PATH = "/tableau/"
CSRF_COOKIE_SAMESITE = "Strict"
CSRF_COOKIE_SECURE = not DEBUG
CSRF_FAILURE_VIEW = "apps.publishing.views.csrf_failure"
# Administrators: Google addresses (secret, comma-separated), compared case-insensitively.
# Empty: every dashboard sign-in is refused. Never stored, never logged.
ADMIN_EMAILS = [e.strip().lower() for e in env.list("ADMIN_EMAILS", default=[]) if e.strip()]
# OAuth web client of the « Se connecter avec Google » button (one of GOOGLE_OAUTH_CLIENT_IDS).
GOOGLE_WEB_CLIENT_ID = env.str("GOOGLE_WEB_CLIENT_ID", default="")
RATE_ADMIN_LOGIN_PER_15_MIN = env.int("RATE_ADMIN_LOGIN_PER_15_MIN", default=10)

# Reverse proxies appending to X-Forwarded-For (0 locally, 1 behind the shared ALB).
NUM_PROXIES = env.int("NUM_PROXIES", default=0)

# ---------------------------------------------------------------------------
# Django REST Framework
# ---------------------------------------------------------------------------
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "apps.installations.authentication.InstallationTokenAuthentication"
    ],
    "DEFAULT_PERMISSION_CLASSES": ["rest_framework.permissions.IsAuthenticated"],
    "DEFAULT_RENDERER_CLASSES": ["rest_framework.renderers.JSONRenderer"],
    "DEFAULT_PARSER_CLASSES": ["rest_framework.parsers.JSONParser"],
    "DEFAULT_THROTTLE_CLASSES": [],
    "EXCEPTION_HANDLER": "apps.core.errors.exception_handler",
    "UNAUTHENTICATED_USER": None,
}

# ---------------------------------------------------------------------------
# Public web pages and Android App Links (contract § 8 and § 9)
# ---------------------------------------------------------------------------
# Origin of the share links (https://<domaine>), without a trailing slash.
PUBLIC_WEB_BASE_URL = env.str("PUBLIC_WEB_BASE_URL", default="http://127.0.0.1:8000").rstrip("/")
# The dashboard forms post to this origin (contract § 14).
if PUBLIC_WEB_BASE_URL not in CSRF_TRUSTED_ORIGINS:
    CSRF_TRUSTED_ORIGINS = [*CSRF_TRUSTED_ORIGINS, PUBLIC_WEB_BASE_URL]
# Android package (Play Console) and SHA-256 fingerprints of the signing certificate(s).
PLAY_PACKAGE_NAME = env.str("PLAY_PACKAGE_NAME", default="")
ANDROID_CERT_FINGERPRINTS = env.list("ANDROID_CERT_FINGERPRINTS", default=[])
# Privacy policy (/confidentialite): publisher and contact, given by the product owner.
LEGAL_PUBLISHER_NAME = env.str("LEGAL_PUBLISHER_NAME", default="")
LEGAL_CONTACT_EMAIL = env.str("LEGAL_CONTACT_EMAIL", default="")
LEGAL_PRIVACY_UPDATED_ON = env.str("LEGAL_PRIVACY_UPDATED_ON", default="30 octobre 2026")

# ---------------------------------------------------------------------------
# Google: Play Integrity, Play Developer API, Sign-In, RTDN
# ---------------------------------------------------------------------------
PLAY_INTEGRITY_ENFORCED = env.bool("PLAY_INTEGRITY_ENFORCED", default=True)
PLAY_INTEGRITY_REQUIRED_DEVICE_VERDICT = env.str(
    "PLAY_INTEGRITY_REQUIRED_DEVICE_VERDICT", default="MEETS_DEVICE_INTEGRITY"
)
PLAY_INTEGRITY_MAX_AGE_SECONDS = env.int("PLAY_INTEGRITY_MAX_AGE_SECONDS", default=300)
# Service account JSON (Secrets Manager eventide/<env>/google-play-service-account).
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = env.str("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON", default="")
GOOGLE_API_TIMEOUT_SECONDS = env.float("GOOGLE_API_TIMEOUT_SECONDS", default=10.0)
# OAuth client IDs accepted as ``aud`` of a Google ID token (POST /account/google).
GOOGLE_OAUTH_CLIENT_IDS = env.list("GOOGLE_OAUTH_CLIENT_IDS", default=[])
# Pub/Sub push subscription of the real-time developer notifications.
RTDN_AUDIENCE = env.str("RTDN_AUDIENCE", default="")
RTDN_SERVICE_ACCOUNT_EMAIL = env.str("RTDN_SERVICE_ACCOUNT_EMAIL", default="")

# Google Play products (contract § 6).
PLAY_SUBSCRIPTION_PRODUCT_ID = "eventide_premium"
PLAY_LIFETIME_PRODUCT_ID = "eventide_lifetime"
PLAY_SUBSCRIPTION_BASE_PLANS = ("monthly", "annual")

# ---------------------------------------------------------------------------
# Rate limits (contract, « Limites de débit »)
# ---------------------------------------------------------------------------
RATE_INSTALLATIONS_PER_IP_HOUR = env.int("RATE_INSTALLATIONS_PER_IP_HOUR", default=20)
RATE_INSTALLATIONS_PER_DEVICE_DAY = env.int("RATE_INSTALLATIONS_PER_DEVICE_DAY", default=10)
RATE_ACCOUNT_LINK_PER_HOUR = env.int("RATE_ACCOUNT_LINK_PER_HOUR", default=10)
RATE_PURCHASES_PER_HOUR = env.int("RATE_PURCHASES_PER_HOUR", default=30)
RATE_SHARES_PER_DAY = env.int("RATE_SHARES_PER_DAY", default=20)
RATE_CONTENT_PER_HOUR = env.int("RATE_CONTENT_PER_HOUR", default=120)
RATE_EXPORT_PER_HOUR = env.int("RATE_EXPORT_PER_HOUR", default=10)
RATE_CATALOG_PER_HOUR = env.int("RATE_CATALOG_PER_HOUR", default=60)

# ---------------------------------------------------------------------------
# Content delivery: CloudFront signed URLs (contract § 8)
# ---------------------------------------------------------------------------
CONTENT_BASE_URL = env.str("CONTENT_BASE_URL", default="").rstrip("/")
CLOUDFRONT_KEY_PAIR_ID = env.str("CLOUDFRONT_KEY_PAIR_ID", default="")
# PEM of the private key (Secrets Manager eventide/<env>/cloudfront-private-key).
CLOUDFRONT_PRIVATE_KEY = env.str("CLOUDFRONT_PRIVATE_KEY", default="", multiline=True)
CONTENT_URL_TTL_SECONDS = env.int("CONTENT_URL_TTL_SECONDS", default=3600)

# ---------------------------------------------------------------------------
# Publishing from the dashboard (contract § 13-14): content bucket, media task.
# ---------------------------------------------------------------------------
# Content bucket (Eventide's own): the browser posts sources to uploads/<uuid>/source (signed
# POST form); the media task writes the processed files under their versioned keys.
CONTENT_BUCKET = env.str("CONTENT_BUCKET", default="")
CONTENT_BUCKET_REGION = env.str("CONTENT_BUCKET_REGION", default="us-east-1")
# Region of the ECS cluster (Fargate sets AWS_REGION in every container).
AWS_REGION_NAME = env.str("AWS_REGION", default=CONTENT_BUCKET_REGION)
# Largest source accepted (contract § 14: 300 Mo), and lifetime of the signed POST form.
UPLOAD_MAX_BYTES = env.int("UPLOAD_MAX_BYTES", default=300_000_000)
UPLOAD_FORM_TTL_SECONDS = env.int("UPLOAD_FORM_TTL_SECONDS", default=900)  # 900 s at most
# Media task (ECS RunTask, the cluster's default capacity provider, no public IP, one at a
# time): family ev-<env>-media, latest ACTIVE revision; same image, command
# ``python manage.py process_media <element-uuid>`` (ADR hebergement-mutualise § 12.5).
MEDIA_TASK_CLUSTER = env.str("MEDIA_TASK_CLUSTER", default="")
MEDIA_TASK_DEFINITION = env.str("MEDIA_TASK_DEFINITION", default="")
MEDIA_TASK_CONTAINER = env.str("MEDIA_TASK_CONTAINER", default="media")
MEDIA_TASK_SUBNETS = env.list("MEDIA_TASK_SUBNETS", default=[])
MEDIA_TASK_SECURITY_GROUPS = env.list("MEDIA_TASK_SECURITY_GROUPS", default=[])
# Where the media task reads sources and writes outputs: ``s3`` (the content bucket) or
# ``local:<dir>`` (development and tests).
MEDIA_STORAGE = env.str("MEDIA_STORAGE", default="s3" if CONTENT_BUCKET else "")
# A processing still running after this long is shown as failed (task killed, out of memory).
MEDIA_PROCESSING_TIMEOUT_SECONDS = env.int("MEDIA_PROCESSING_TIMEOUT_SECONDS", default=45 * 60)

# ---------------------------------------------------------------------------
# Logging: JSON lines on stdout, never a token.
# ---------------------------------------------------------------------------
LOG_LEVEL = env.str("LOG_LEVEL", default="INFO")
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "filters": {
        "request_id": {"()": "apps.core.logging.RequestIdFilter"},
        "scrub": {"()": "apps.core.logging.ScrubFilter"},
    },
    "formatters": {
        "json": {
            "()": "pythonjsonlogger.json.JsonFormatter",
            "fmt": "%(asctime)s %(levelname)s %(name)s %(message)s %(request_id)s",
            "rename_fields": {"asctime": "timestamp", "levelname": "level", "name": "logger"},
        },
    },
    "handlers": {
        "stdout": {
            "class": "logging.StreamHandler",
            "stream": "ext://sys.stdout",
            "formatter": "json",
            "filters": ["request_id", "scrub"],
        },
    },
    "root": {"handlers": ["stdout"], "level": LOG_LEVEL},
    "loggers": {
        "django": {"handlers": ["stdout"], "level": LOG_LEVEL, "propagate": False},
        "django.db.backends": {"level": "WARNING"},
        "apps": {"handlers": ["stdout"], "level": LOG_LEVEL, "propagate": False},
        # urllib3 logs full URLs at DEBUG: Play Developer API URLs carry purchase tokens.
        "urllib3": {"level": "WARNING"},
    },
}
