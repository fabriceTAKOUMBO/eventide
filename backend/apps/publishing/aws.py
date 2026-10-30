"""AWS calls of the publishing flow (boto3), created lazily, one client per service and process.

- the API signs the browser's POST form to ``uploads/<uuid>/source`` (S3 presigned POST: a
  local signature with the task role's credentials, no AWS call) and starts the media task
  (``ecs:RunTask`` on the media family, ``iam:PassRole`` for it);
- the media task reads the source (``s3:GetObject`` on ``uploads/*``) and writes the processed
  files (``s3:PutObject`` on their prefixes). Nothing lists or deletes: the bucket lifecycle
  removes the sources after 7 days.

Tests replace every client by a stubbed one (botocore ``Stubber``): no AWS call is ever made.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from django.conf import settings

logger = logging.getLogger(__name__)

_lock = threading.Lock()
_clients: dict[str, Any] = {}

UPLOAD_FORM_MAX_TTL_SECONDS = 900


class NotConfigured(Exception):
    """The setting needed by this feature is empty (development, tests)."""


class TaskNotStarted(Exception):
    pass


def _make(service: str) -> Any:
    import boto3
    from botocore.config import Config

    if service == "s3":
        region = settings.CONTENT_BUCKET_REGION
        # Regional virtual-hosted endpoint: the browser posts to
        # https://<bucket>.s3.<region>.amazonaws.com (the dashboard's CSP names it).
        return boto3.client(
            "s3",
            region_name=region,
            endpoint_url=f"https://s3.{region}.amazonaws.com",
            config=Config(
                signature_version="s3v4",
                s3={"addressing_style": "virtual"},
                retries={"max_attempts": 4, "mode": "standard"},
                connect_timeout=5,
                read_timeout=60,
            ),
        )
    return boto3.client(
        service,
        region_name=settings.AWS_REGION_NAME,
        config=Config(
            retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=5, read_timeout=20
        ),
    )


def client(service: str) -> Any:
    with _lock:
        existing = _clients.get(service)
        if existing is None:
            existing = _clients[service] = _make(service)
    return existing


def reset_clients() -> None:
    with _lock:
        _clients.clear()


def upload_origin() -> str:
    """Origin the browser posts sources to (CSP ``connect-src`` / ``form-action``)."""
    bucket = settings.CONTENT_BUCKET
    if not bucket:
        return ""
    return f"https://{bucket}.s3.{settings.CONTENT_BUCKET_REGION}.amazonaws.com"


def source_key(upload_id: str) -> str:
    return f"uploads/{upload_id}/source"


def presigned_post(upload_id: str, content_type: str) -> dict[str, Any]:
    """Signed form for one source: this key, this content type, 1 byte to UPLOAD_MAX_BYTES, no
    ``acl`` field (the bucket enforces its owner), valid 15 minutes at most (the task role's
    credentials are temporary)."""
    from botocore.exceptions import BotoCoreError

    if not settings.CONTENT_BUCKET:
        raise NotConfigured("CONTENT_BUCKET is empty")
    try:
        return client("s3").generate_presigned_post(
            Bucket=settings.CONTENT_BUCKET,
            Key=source_key(upload_id),
            Fields={"Content-Type": content_type},
            Conditions=[
                {"Content-Type": content_type},
                ["content-length-range", 1, settings.UPLOAD_MAX_BYTES],
            ],
            ExpiresIn=min(settings.UPLOAD_FORM_TTL_SECONDS, UPLOAD_FORM_MAX_TTL_SECONDS),
        )
    except BotoCoreError as exc:  # no credentials (task role missing, local run)
        logger.warning("Upload form not signed", extra={"event": "upload_form_unsigned"})
        raise NotConfigured("cannot sign the upload form") from exc


def media_task_configured() -> bool:
    return bool(
        settings.MEDIA_TASK_CLUSTER
        and settings.MEDIA_TASK_DEFINITION
        and settings.MEDIA_TASK_SUBNETS
        and settings.MEDIA_TASK_SECURITY_GROUPS
    )


def run_media_task(element_id: str) -> str:
    """Start ``python manage.py process_media <element_id>`` on Fargate; the task ARN."""
    if not media_task_configured():
        raise NotConfigured("MEDIA_TASK_* settings are empty")
    # ADR § 12.5: one task, the cluster's default capacity provider (no launch type), tags of
    # the task definition, and no override but the container's command.
    response = client("ecs").run_task(
        cluster=settings.MEDIA_TASK_CLUSTER,
        # The family name: its latest ACTIVE revision.
        taskDefinition=settings.MEDIA_TASK_DEFINITION,
        count=1,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": list(settings.MEDIA_TASK_SUBNETS),
                "securityGroups": list(settings.MEDIA_TASK_SECURITY_GROUPS),
                "assignPublicIp": "DISABLED",
            }
        },
        overrides={
            "containerOverrides": [
                {
                    "name": settings.MEDIA_TASK_CONTAINER,
                    "command": ["python", "manage.py", "process_media", str(element_id)],
                }
            ]
        },
        propagateTags="TASK_DEFINITION",
        startedBy="ev-tableau",
    )
    tasks = response.get("tasks") or []
    if response.get("failures") or not tasks:
        reasons = [f.get("reason", "") for f in response.get("failures") or []]
        logger.warning(
            "Media task not started", extra={"event": "media_task_failed", "reasons": reasons}
        )
        raise TaskNotStarted(", ".join(reasons))
    arn = tasks[0].get("taskArn", "")
    logger.info("Media task started", extra={"event": "media_task_started", "task": arn})
    return arn
