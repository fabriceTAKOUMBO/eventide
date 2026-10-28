"""Opaque installation tokens: 43 URL-safe characters, stored as SHA-256 only."""

import hashlib
import secrets


def new_token() -> str:
    return secrets.token_urlsafe(32)  # 32 random bytes -> 43 characters


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
