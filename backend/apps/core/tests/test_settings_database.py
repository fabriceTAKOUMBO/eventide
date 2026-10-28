"""Database settings on the shared PostgreSQL instance (docs/infra/hebergement-mutualise.md).

The bootstrap sets idle_session_timeout on our roles, so the server closes idle sessions: a
pooled connection must be health-checked before use (CONN_HEALTH_CHECKS) and replaced, never
handed to a request. The settings are evaluated in a fresh interpreter (the test settings
disable the pool).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[3]

PROBE = (
    "import json, django; django.setup(); from django.conf import settings; "
    "db = settings.DATABASES['default']; "
    "print(json.dumps({'checks': db.get('CONN_HEALTH_CHECKS'), 'max_age': db.get('CONN_MAX_AGE'), "
    "'pool': db['OPTIONS'].get('pool'), 'name': db['NAME']}))"
)


def _database_settings(pool_max_size: str) -> dict:
    env = {
        "PATH": os.environ.get("PATH", ""),
        "DJANGO_SETTINGS_MODULE": "config.settings.dev",
        "DJANGO_READ_DOT_ENV": "false",
        "DJANGO_SECRET_KEY": "settings-probe-only",
        "DATABASE_URL": "postgres://ev_app:probe@127.0.0.1:5432/eventide",
        "DB_POOL_MAX_SIZE": pool_max_size,
    }
    out = subprocess.run(  # noqa: S603 - fixed interpreter and arguments
        [sys.executable, "-c", PROBE],
        cwd=BACKEND_DIR,
        env=env,
        capture_output=True,
        text=True,
        check=True,
        timeout=60,
    )
    return json.loads(out.stdout.strip().splitlines()[-1])


def test_pooled_connections_are_health_checked_before_use():
    db = _database_settings("2")
    assert db["pool"] == {"min_size": 1, "max_size": 2, "timeout": 10.0}
    assert db["max_age"] == 0
    assert db["checks"] is True
    assert db["name"] == "eventide"


def test_unpooled_connections_are_health_checked_too():
    db = _database_settings("0")
    assert db["pool"] is None
    assert db["checks"] is True
