"""Pluggable embedding backends. The default talks to Ollama on loopback."""

from __future__ import annotations

from typing import Protocol

import httpx


class EmbeddingBackend(Protocol):
    def health(self) -> tuple[bool, str | None]:
        """Return (reachable, error_message)."""

    def list_models(self) -> tuple[list[str], str | None]:
        """Return (model names, error_message)."""

    def embed(self, texts: list[str], model: str) -> list[list[float]]:
        """Return one vector per input text."""


class OllamaEmbeddingBackend:
    def __init__(self, base_url: str = "http://127.0.0.1:11434", timeout: float = 5.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def health(self) -> tuple[bool, str | None]:
        try:
            response = httpx.get(f"{self.base_url}/api/tags", timeout=self.timeout)
            if response.status_code == 200:
                return True, None
            return False, f"HTTP {response.status_code}"
        except httpx.HTTPError as exc:
            return False, str(exc)

    def list_models(self) -> tuple[list[str], str | None]:
        try:
            response = httpx.get(f"{self.base_url}/api/tags", timeout=self.timeout)
            response.raise_for_status()
            payload = response.json()
            names = [item.get("name") or item.get("model") for item in payload.get("models", [])]
            return [name for name in names if name], None
        except httpx.HTTPError as exc:
            return [], str(exc)

    def embed(self, texts: list[str], model: str) -> list[list[float]]:
        if not texts:
            return []
        response = httpx.post(
            f"{self.base_url}/api/embed",
            json={"model": model, "input": texts},
            timeout=max(self.timeout, 30.0),
        )
        response.raise_for_status()
        payload = response.json()
        embeddings = payload.get("embeddings")
        if embeddings is None and payload.get("embedding") is not None:
            embeddings = [payload["embedding"]]
        if not isinstance(embeddings, list):
            raise RuntimeError("Ollama /api/embed response missing embeddings")
        return embeddings
