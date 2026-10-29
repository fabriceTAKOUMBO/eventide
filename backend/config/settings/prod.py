"""Production (and pre-production) settings: ECS Fargate behind the shared ALB."""

from django.core.exceptions import ImproperlyConfigured

from .base import *
from .base import (
    ALLOWED_HOSTS,
    CLOUDFRONT_PRIVATE_KEY,
    PUBLIC_WEB_BASE_URL,
    env,
)

DEBUG = False

if not ALLOWED_HOSTS:
    raise ImproperlyConfigured("ALLOWED_HOSTS must be set in production.")
if not PUBLIC_WEB_BASE_URL.startswith("https://"):
    raise ImproperlyConfigured("PUBLIC_WEB_BASE_URL must be an https:// origin in production.")
if CLOUDFRONT_PRIVATE_KEY and "PRIVATE KEY" not in CLOUDFRONT_PRIVATE_KEY:
    raise ImproperlyConfigured("CLOUDFRONT_PRIVATE_KEY must be a PEM private key.")

# One ALB in front of the containers (it appends the client address to X-Forwarded-For).
NUM_PROXIES = env.int("NUM_PROXIES", default=1)

# HTTPS: the ALB terminates TLS and forwards X-Forwarded-Proto; /v1/health* never redirects.
SECURE_SSL_REDIRECT = env.bool("SECURE_SSL_REDIRECT", default=True)
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_HSTS_SECONDS = 31_536_000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = False  # hard to undo; decided later with the final domain
SILENCED_SYSTEM_CHECKS = ["security.W021"]
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True
