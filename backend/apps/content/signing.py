"""CloudFront signed URLs, canned policy (contract § 8).

The private key (PEM, Secrets Manager ``eventide/<env>/cloudfront-private-key``) signs locally:
no AWS call. Its public key belongs to the distribution's trusted key group (Terraform,
module content_cdn); ``CLOUDFRONT_KEY_PAIR_ID`` is the id of that public key.
"""

from __future__ import annotations

import base64
import json
from functools import cache

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from django.conf import settings


class SigningNotConfigured(Exception):
    pass


@cache
def _private_key(pem: str) -> rsa.RSAPrivateKey:
    key = serialization.load_pem_private_key(pem.encode("ascii"), password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise SigningNotConfigured("CloudFront keys are RSA")
    return key


def _cloudfront_b64(raw: bytes) -> str:
    return (
        base64.b64encode(raw).decode("ascii").replace("+", "-").replace("=", "_").replace("/", "~")
    )


def canned_policy(url: str, expires: int) -> str:
    """Exact form expected by CloudFront: compact JSON, no whitespace."""
    statement = {"Resource": url, "Condition": {"DateLessThan": {"AWS:EpochTime": expires}}}
    return json.dumps({"Statement": [statement]}, separators=(",", ":"))


def sign(url: str, expires: int) -> str:
    pem = settings.CLOUDFRONT_PRIVATE_KEY
    if not (pem and settings.CLOUDFRONT_KEY_PAIR_ID and settings.CONTENT_BASE_URL):
        raise SigningNotConfigured()
    # CloudFront canned policies are signed with RSA-SHA1 (CloudFront developer guide,
    # « Creating a signature for a signed URL that uses a canned policy »): protocol constraint.
    signature = _private_key(pem).sign(
        canned_policy(url, expires).encode("utf-8"),
        padding.PKCS1v15(),
        hashes.SHA1(),  # noqa: S303  # nosec B303
    )
    return (
        f"{url}?Expires={expires}&Signature={_cloudfront_b64(signature)}"
        f"&Key-Pair-Id={settings.CLOUDFRONT_KEY_PAIR_ID}"
    )
