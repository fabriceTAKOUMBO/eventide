"""Where the media task reads sources and writes processed files (``MEDIA_STORAGE``).

- ``s3``: the content bucket. ``GetObject`` on ``uploads/<uuid>/source``, ``PutObject`` on the
  versioned keys (immutable: a key is written by one upload only, so it is cached for a year);
- ``local:<dir>``: the same layout under a directory (development, tests).
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Protocol

from django.conf import settings

from . import aws

CONTENT_TYPES = {".mp4": "video/mp4", ".jpg": "image/jpeg", ".ogg": "audio/ogg"}
CACHE_CONTROL = "public, max-age=31536000, immutable"
CHUNK = 1024 * 1024


class SourceMissing(Exception):
    pass


class SourceTooLarge(Exception):
    pass


class StorageNotConfigured(Exception):
    pass


class MediaStorage(Protocol):
    def fetch_source(self, upload_id: str, dest: Path, max_bytes: int) -> int: ...

    def put(self, key: str, path: Path) -> None: ...


def content_type_of(key: str) -> str:
    return CONTENT_TYPES[Path(key).suffix]


class S3Storage:
    def __init__(self, bucket: str):
        self.bucket = bucket

    def fetch_source(self, upload_id: str, dest: Path, max_bytes: int) -> int:
        from botocore.exceptions import ClientError

        try:
            response = aws.client("s3").get_object(
                Bucket=self.bucket, Key=aws.source_key(upload_id)
            )
        except ClientError as exc:
            # Without s3:ListBucket (media role), a missing key answers 403 AccessDenied.
            code = exc.response.get("Error", {}).get("Code", "")
            if code in ("NoSuchKey", "404", "AccessDenied", "403", "Forbidden"):
                raise SourceMissing() from exc
            raise
        if int(response.get("ContentLength") or 0) > max_bytes:
            raise SourceTooLarge()
        written = 0
        body = response["Body"]
        with dest.open("wb") as out:
            for chunk in body.iter_chunks(CHUNK):
                written += len(chunk)
                if written > max_bytes:
                    raise SourceTooLarge()
                out.write(chunk)
        return written

    def put(self, key: str, path: Path) -> None:
        with path.open("rb") as body:
            aws.client("s3").put_object(
                Bucket=self.bucket,
                Key=key,
                Body=body,
                ContentType=content_type_of(key),
                CacheControl=CACHE_CONTROL,
            )


class LocalStorage:
    def __init__(self, root: Path):
        self.root = root

    def fetch_source(self, upload_id: str, dest: Path, max_bytes: int) -> int:
        src = self.root / aws.source_key(upload_id)
        if not src.is_file():
            raise SourceMissing()
        if src.stat().st_size > max_bytes:
            raise SourceTooLarge()
        shutil.copyfile(src, dest)
        return dest.stat().st_size

    def put(self, key: str, path: Path) -> None:
        target = self.root / key
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)


def get_storage() -> MediaStorage:
    value = settings.MEDIA_STORAGE
    if value == "s3":
        if not settings.CONTENT_BUCKET:
            raise StorageNotConfigured()
        return S3Storage(settings.CONTENT_BUCKET)
    if value.startswith("local:") and len(value) > len("local:"):
        return LocalStorage(Path(value.removeprefix("local:")))
    raise StorageNotConfigured()
