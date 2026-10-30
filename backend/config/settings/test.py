"""Settings for pytest. Deterministic: the local ``.env`` file is ignored.

Only the database URL may come from the environment (CI provides its own PostgreSQL 16).
No real Google or AWS endpoint is ever reached: tests mock HTTP with ``responses`` and AWS with
botocore's ``Stubber`` (clients built with fake credentials, see ``apps/publishing/tests``).
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
    "CONTENT_BASE_URL": "https://cdn.eventide.test",
    "CLOUDFRONT_KEY_PAIR_ID": "K2TESTKEYID",
    "CLOUDFRONT_PRIVATE_KEY": "",
    "ADMIN_EMAILS": "Admin@Eventide.test, second@eventide.test",
    "GOOGLE_WEB_CLIENT_ID": "client-1.apps.googleusercontent.com",
    "CONTENT_BUCKET": "ev-test-content",
    "CONTENT_BUCKET_REGION": "us-east-1",
    "AWS_REGION": "us-east-1",
    "MEDIA_TASK_CLUSTER": "ev-test",
    "MEDIA_TASK_DEFINITION": "ev-test-media",
    "MEDIA_TASK_CONTAINER": "media",
    "MEDIA_TASK_SUBNETS": "subnet-aaa,subnet-bbb",
    "MEDIA_TASK_SECURITY_GROUPS": "sg-media",
    "MEDIA_STORAGE": "s3",
    # Never a real AWS identity in tests (defence in depth: AWS clients are stubbed, and an
    # unstubbed client fails, see conftest.py). Fake keys sign presigned forms locally only.
    "AWS_ACCESS_KEY_ID": "testing",
    "AWS_SECRET_ACCESS_KEY": "testing",  # nosec B105 - fake test value, never a secret
    "AWS_SESSION_TOKEN": "testing",  # nosec B105 - fake test value, never a secret
    "AWS_EC2_METADATA_DISABLED": "true",
    "AWS_CONFIG_FILE": os.devnull,
    "AWS_SHARED_CREDENTIALS_FILE": os.devnull,
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
