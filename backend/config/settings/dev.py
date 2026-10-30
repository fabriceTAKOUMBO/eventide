"""Local development settings (``manage.py`` default)."""

from .base import *
from .base import env

DEBUG = env.bool("DEBUG", default=True)
ALLOWED_HOSTS = env.list("ALLOWED_HOSTS", default=["localhost", "127.0.0.1", "[::1]"])
NUM_PROXIES = env.int("NUM_PROXIES", default=0)
# Dashboard cookies over plain HTTP on the local server.
SESSION_COOKIE_SECURE = not DEBUG
CSRF_COOKIE_SECURE = not DEBUG
# Without a Play Store build, no integrity token can be obtained locally.
PLAY_INTEGRITY_ENFORCED = env.bool("PLAY_INTEGRITY_ENFORCED", default=False)

STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}
# Static files served from the apps by WhiteNoise (no collectstatic outside the image).
STATIC_ROOT = None
WHITENOISE_USE_FINDERS = True
WHITENOISE_AUTOREFRESH = True
