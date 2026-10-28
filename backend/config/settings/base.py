"""Settings shared by every environment.

Configuration comes only from environment variables (django-environ); the template is
``backend/.env.example``. The environment-specific modules (dev, test, prod) import this one
and override what they need. Nothing here opens a network connection at import time.
"""

from __future__ import annotations

import json
import os
from decimal import Decimal, InvalidOperation
from pathlib import Path

import environ
from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent.parent  # backend/

env = environ.Env()

# A local ``.env`` file is read in development only (test settings disable it and the
# production image contains none). Real environment variables always win.
_dot_env = BASE_DIR / ".env"
if os.environ.get("DJANGO_READ_DOT_ENV", "true").lower() != "false" and _dot_env.is_file():
    environ.Env.read_env(str(_dot_env), overwrite=False)


def _decimal(name: str, default: str) -> Decimal:
    raw = env.str(name, default=default)
    try:
        value = Decimal(raw)
    except InvalidOperation as exc:
        raise ImproperlyConfigured(f"{name} must be a decimal number (got {raw!r}).") from exc
    if value < 0:
        raise ImproperlyConfigured(f"{name} must not be negative.")
    return value


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
    "django.contrib.staticfiles",
    "rest_framework",
    "apps.core",
    "apps.accounts",
    "apps.installations",
    "apps.entitlements",
    "apps.voice",
    "apps.shares",
    "apps.content",
    "apps.web",
]

MIDDLEWARE = [
    # First: answers /v1/health and /v1/health/ready before host validation and the HTTPS
    # redirect (load balancer probes use plain HTTP and the task IP as Host).
    "apps.core.middleware.HealthCheckMiddleware",
    "apps.core.middleware.RequestIdMiddleware",
    "apps.core.middleware.RequestSizeLimitMiddleware",
    "django.middleware.security.SecurityMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
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
# docs/infra/hebergement-mutualise.md). No Redis: rate limits and quota counters live here.
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
# The largest body is POST /voice (phrase + state): 64 KiB is plenty.
DATA_UPLOAD_MAX_MEMORY_SIZE = 64 * 1024
DATA_UPLOAD_MAX_NUMBER_FIELDS = 200
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "no-referrer"
SECURE_CROSS_ORIGIN_OPENER_POLICY = "same-origin"
X_FRAME_OPTIONS = "DENY"
CSRF_COOKIE_HTTPONLY = True

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
# Android package (Play Console) and SHA-256 fingerprints of the signing certificate(s).
PLAY_PACKAGE_NAME = env.str("PLAY_PACKAGE_NAME", default="")
ANDROID_CERT_FINGERPRINTS = env.list("ANDROID_CERT_FINGERPRINTS", default=[])
# Privacy policy (/confidentialite): publisher and contact, given by the product owner.
LEGAL_PUBLISHER_NAME = env.str("LEGAL_PUBLISHER_NAME", default="")
LEGAL_CONTACT_EMAIL = env.str("LEGAL_CONTACT_EMAIL", default="")
LEGAL_PRIVACY_UPDATED_ON = env.str("LEGAL_PRIVACY_UPDATED_ON", default="28 octobre 2026")

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

# Google Play products (contract § 6) and credits granted by each consumable.
PLAY_SUBSCRIPTION_PRODUCT_ID = "eventide_premium"
PLAY_LIFETIME_PRODUCT_ID = "eventide_lifetime"
PLAY_CREDIT_PRODUCTS = {"eventide_credits_50": 50}
PLAY_SUBSCRIPTION_BASE_PLANS = ("monthly", "annual")

# ---------------------------------------------------------------------------
# Voice assistant (contract § 7)
# ---------------------------------------------------------------------------
VOICE_ENABLED = env.bool("VOICE_ENABLED", default=True)
# rules-only | gemini | jev (jev: reserved, answers 503 model_unavailable until it is built).
VOICE_ROUTER = env.str("VOICE_ROUTER", default="gemini")
if VOICE_ROUTER not in {"rules-only", "gemini", "jev"}:
    raise ImproperlyConfigured("VOICE_ROUTER must be rules-only, gemini or jev.")
GEMINI_API_KEY = env.str("GEMINI_API_KEY", default="")
GEMINI_MODEL = env.str("GEMINI_MODEL", default="gemini-2.5-flash-lite")
GEMINI_API_BASE = env.str(
    "GEMINI_API_BASE", default="https://generativelanguage.googleapis.com/v1beta"
).rstrip("/")
GEMINI_TIMEOUT_SECONDS = env.float("GEMINI_TIMEOUT_SECONDS", default=8.0)
GEMINI_MAX_OUTPUT_TOKENS = env.int("GEMINI_MAX_OUTPUT_TOKENS", default=512)
# Thinking budget sent to the model (0 = no thinking; empty = field not sent).
GEMINI_THINKING_BUDGET = env.str("GEMINI_THINKING_BUDGET", default="0")

# Price table, USD per million tokens (https://ai.google.dev/gemini-api/docs/pricing, read on
# 2026-10-28 by the product dossier, § 3). Overridable as JSON:
# {"<model>": {"input": "<usd>", "output": "<usd>"}}.
_DEFAULT_PRICES = {"gemini-2.5-flash-lite": {"input": "0.10", "output": "0.40"}}
try:
    _raw_prices = json.loads(env.str("VOICE_PRICE_TABLE", default="") or "null") or _DEFAULT_PRICES
    VOICE_PRICE_TABLE = {
        model: {"input": Decimal(str(p["input"])), "output": Decimal(str(p["output"]))}
        for model, p in _raw_prices.items()
    }
except (ValueError, KeyError, TypeError, InvalidOperation) as exc:
    raise ImproperlyConfigured("VOICE_PRICE_TABLE must be a JSON object of prices.") from exc
VOICE_MONTHLY_CAP_EUR = _decimal("VOICE_MONTHLY_CAP_EUR", "2.00")
USD_EUR_RATE = _decimal("USD_EUR_RATE", "0.93")
# Amount reserved before each model call (well above the real cost of one request).
VOICE_RESERVATION_EUR = _decimal("VOICE_RESERVATION_EUR", "0.005")
# Global safety net, all users together: model calls refused beyond this amount per UTC day.
VOICE_GLOBAL_DAILY_CAP_EUR = _decimal("VOICE_GLOBAL_DAILY_CAP_EUR", "20.00")
VOICE_TRIAL_REQUESTS = env.int("VOICE_TRIAL_REQUESTS", default=3)
VOICE_RATE_PER_MINUTE = env.int("VOICE_RATE_PER_MINUTE", default=20)
VOICE_RATE_PER_DAY = env.int("VOICE_RATE_PER_DAY", default=300)
VOICE_STALE_RESERVATION_MINUTES = env.int("VOICE_STALE_RESERVATION_MINUTES", default=10)
VOICE_REQUEST_RETENTION_DAYS = env.int("VOICE_REQUEST_RETENTION_DAYS", default=90)

# ---------------------------------------------------------------------------
# Other rate limits (contract, « Limites de débit »)
# ---------------------------------------------------------------------------
RATE_INSTALLATIONS_PER_IP_HOUR = env.int("RATE_INSTALLATIONS_PER_IP_HOUR", default=20)
RATE_INSTALLATIONS_PER_DEVICE_DAY = env.int("RATE_INSTALLATIONS_PER_DEVICE_DAY", default=10)
RATE_ACCOUNT_LINK_PER_HOUR = env.int("RATE_ACCOUNT_LINK_PER_HOUR", default=10)
RATE_PURCHASES_PER_HOUR = env.int("RATE_PURCHASES_PER_HOUR", default=30)
RATE_SHARES_PER_DAY = env.int("RATE_SHARES_PER_DAY", default=20)
RATE_CONTENT_PER_HOUR = env.int("RATE_CONTENT_PER_HOUR", default=120)
RATE_EXPORT_PER_HOUR = env.int("RATE_EXPORT_PER_HOUR", default=10)

# ---------------------------------------------------------------------------
# Content delivery: CloudFront signed URLs (contract § 8)
# ---------------------------------------------------------------------------
CONTENT_BASE_URL = env.str("CONTENT_BASE_URL", default="").rstrip("/")
CLOUDFRONT_KEY_PAIR_ID = env.str("CLOUDFRONT_KEY_PAIR_ID", default="")
# PEM of the private key (Secrets Manager eventide/<env>/cloudfront-private-key).
CLOUDFRONT_PRIVATE_KEY = env.str("CLOUDFRONT_PRIVATE_KEY", default="", multiline=True)
CONTENT_URL_TTL_SECONDS = env.int("CONTENT_URL_TTL_SECONDS", default=3600)

# ---------------------------------------------------------------------------
# Logging: JSON lines on stdout, never the phrase, the transcript or a token.
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
        # urllib3 logs full URLs at DEBUG (the Gemini key travels in a header, never in a URL).
        "urllib3": {"level": "WARNING"},
    },
}
