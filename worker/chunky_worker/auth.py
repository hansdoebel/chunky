"""Bearer-token authentication for the worker HTTP API.

The token is compared with ``secrets.compare_digest`` and is never logged.
Callers send ``Authorization: Bearer <token>``. A token in the query string is
ignored so it cannot land in access logs.
"""

from __future__ import annotations

import secrets
from pathlib import Path

from fastapi import HTTPException, Request

from chunky_worker.settings import Settings


def generate_token() -> str:
    """Return a new URL-safe token (256 bits)."""
    return secrets.token_urlsafe(32)


def write_token_file(path: Path, token: str | None = None) -> str:
    """Write ``token`` (or a new one) to ``path`` with mode 0600. Returns the token."""
    value = token if token else generate_token()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value + "\n", encoding="utf-8")
    path.chmod(0o600)
    return value


def require_bearer(request: Request) -> None:
    """Reject the request unless the Authorization bearer token matches settings."""
    settings: Settings = request.app.state.settings
    expected = settings.token or ""
    if not expected:
        raise HTTPException(
            status_code=401,
            detail="Worker token is not configured",
            headers={"WWW-Authenticate": "Bearer"},
        )

    header = request.headers.get("authorization", "")
    scheme, _, presented = header.partition(" ")
    if scheme.lower() != "bearer" or not presented or not secrets.compare_digest(presented, expected):
        raise HTTPException(
            status_code=401,
            detail="Invalid or missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
