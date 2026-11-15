"""Pluggable embedding backends. The default talks to Ollama on loopback."""

from __future__ import annotations

import threading
from typing import Protocol

import httpx

# Stable probe text. The dimension is cached per model name for the process.
PROBE_TEXT = "chunky"


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


class DimensionCache:
    """One probe embedding per model name. Later calls reuse the cached width."""

    def __init__(self) -> None:
        self._sizes: dict[str, int] = {}
        self._lock = threading.Lock()

    def dimension(self, backend: EmbeddingBackend, model: str) -> int:
        with self._lock:
            cached = self._sizes.get(model)
        if cached is not None:
            return cached
        vectors = backend.embed([PROBE_TEXT], model)
        if not vectors or not vectors[0]:
            raise RuntimeError(f"Embedding probe for {model!r} returned no vector")
        size = len(vectors[0])
        with self._lock:
            self._sizes.setdefault(model, size)
            return self._sizes[model]
