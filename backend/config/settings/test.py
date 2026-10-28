"""Settings for pytest. Deterministic: the local ``.env`` file is ignored.

Only the database URL may come from the environment (CI provides its own PostgreSQL 16).
No real Google or AWS endpoint is ever reached: tests mock HTTP with ``responses``.
"""

import os
import secrets

_TEST_ENV = {
    "DJANGO_READ_DOT_ENV": "false",
    "DJANGO_SECRET_KEY": secrets.token_urlsafe(50),
    "PUBLIC_WEB_BASE_URL": "https://eventide.test",
    "PLAY_PACKAGE_NAME": "app.eventide.test",
    "ANDROID_CERT_FINGERPRINTS": "AA:BB:CC",
    "PLAY_INTEGRITY_ENFORCED": "true",
    "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": "",
    "GOOGLE_OAUTH_CLIENT_IDS": "client-1.apps.googleusercontent.com",
    "RTDN_AUDIENCE": "https://api.eventide.test/v1/play/rtdn",
    "RTDN_SERVICE_ACCOUNT_EMAIL": "rtdn-push@eventide-test.iam.gserviceaccount.com",
    "VOICE_ENABLED": "true",
    "VOICE_ROUTER": "gemini",
    "GEMINI_API_KEY": "test-only-gemini-key",
    "GEMINI_MODEL": "gemini-2.5-flash-lite",
    "GEMINI_API_BASE": "https://gemini.test/v1beta",
    "VOICE_PRICE_TABLE": "",
    "VOICE_MONTHLY_CAP_EUR": "2.00",
    "USD_EUR_RATE": "0.93",
    "VOICE_RESERVATION_EUR": "0.005",
    "VOICE_GLOBAL_DAILY_CAP_EUR": "20.00",
    "CONTENT_BASE_URL": "https://cdn.eventide.test",
    "CLOUDFRONT_KEY_PAIR_ID": "K2TESTKEYID",
    "CLOUDFRONT_PRIVATE_KEY": "",
    "DB_POOL_MAX_SIZE": "0",
    "NUM_PROXIES": "1",
    "LOG_LEVEL": "WARNING",
}
os.environ.update(_TEST_ENV)
os.environ.setdefault(
    "DATABASE_URL", "postgres://ev_app:ev_local_dev_only@127.0.0.1:55433/eventide"
)

from .base import *  # noqa: E402

DEBUG = False
ALLOWED_HOSTS = ["testserver", "localhost", "127.0.0.1"]
STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}
# Static files served from the apps by WhiteNoise (no collectstatic outside the image).
STATIC_ROOT = None
WHITENOISE_USE_FINDERS = True
WHITENOISE_AUTOREFRESH = True
