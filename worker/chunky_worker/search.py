"""Embed a query and search a Qdrant collection. Credentials stay in memory."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Any, Callable, Protocol
from urllib.parse import urlparse

from pydantic import BaseModel, Field, ValidationError, field_validator

from chunky_worker.embeddings import EmbeddingBackend, make_embedding_backend
from chunky_worker.qdrant_ingest import _collection_vector_size, dense_vector_name, redact
from chunky_worker.settings import Settings

log = logging.getLogger(__name__)

MAX_LIMIT = 100
_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
_BACKENDS = {"ollama", "openai"}


class SearchError(Exception):
    def __init__(self, message: str, *, status_code: int = 400, error_type: str | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_type = error_type


class PayloadFilter(BaseModel):
    key: str
    match: str | int | bool | None = None
    gt: float | None = None
    gte: float | None = None
    lt: float | None = None
    lte: float | None = None

    @field_validator("key")
    @classmethod
    def key_is_a_payload_field(cls, value: str) -> str:
        key = value.strip()
        if not _KEY_PATTERN.fullmatch(key):
            raise ValueError(f"Invalid filter key: {value!r}")
        return key

    @field_validator("match")
    @classmethod
    def match_is_a_scalar(cls, value: Any) -> str | int | bool | None:
        if value is None:
            return None
        if isinstance(value, bool) or isinstance(value, int) or isinstance(value, str):
            if isinstance(value, str) and value == "":
                raise ValueError("match must not be empty")
            return value
        raise ValueError("match must be a string, integer, or boolean")

    def has_range(self) -> bool:
        return any(bound is not None for bound in (self.gt, self.gte, self.lt, self.lte))

    def check_complete(self) -> None:
        if self.match is None and not self.has_range():
            raise ValueError(f"Filter {self.key!r} needs a match or a range")


class SearchRequest(BaseModel):
    query: str
    collection: str
    qdrant_url: str | None = None
    qdrant_api_key: str | None = Field(default=None, repr=False)
    embedding_model: str | None = None
    embedding_backend: str | None = None
    embedding_url: str | None = None
    limit: int = Field(default=10, ge=1, le=MAX_LIMIT)
    offset: int = Field(default=0, ge=0)
    score_threshold: float | None = None
    filters: list[PayloadFilter] = Field(default_factory=list)

    @field_validator("query", "collection")
    @classmethod
    def required_text(cls, value: str) -> str:
        text = value.strip()
        if not text:
            raise ValueError("must not be empty")
        return text

    @field_validator("embedding_backend")
    @classmethod
    def known_backend(cls, value: str | None) -> str | None:
        if value is None:
            return None
        kind = value.strip().lower()
        if not kind:
            return None
        if kind not in _BACKENDS:
            raise ValueError("embedding_backend must be ollama or openai")
        return kind


@dataclass
class CollectionLayout:
    vector_size: int | None
    using: str | None


@dataclass
class ScoredHit:
    id: str
    score: float
    payload: dict[str, Any]


class QdrantSearcher(Protocol):
    def describe(self, *, url: str, api_key: str, collection: str) -> CollectionLayout | None:
        ...

    def query_dense(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        vector: list[float],
        limit: int,
        offset: int,
        filters: list[PayloadFilter],
        score_threshold: float | None,
        using: str | None,
    ) -> list[ScoredHit]:
        ...


def build_query_filter(filters: list[PayloadFilter]):
    if not filters:
        return None
    from qdrant_client.models import FieldCondition, Filter, MatchValue, Range

    must = []
    for item in filters:
        item.check_complete()
        kwargs: dict[str, Any] = {"key": item.key}
        if item.match is not None:
            kwargs["match"] = MatchValue(value=item.match)
        if item.has_range():
            kwargs["range"] = Range(gt=item.gt, gte=item.gte, lt=item.lt, lte=item.lte)
        must.append(FieldCondition(**kwargs))
    return Filter(must=must)


def _http_url(value: str, label: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SearchError(f"{label} must be an http(s) URL")
    return value


def _destination_key(url: str) -> str:
    parsed = urlparse(url.strip())
    host = (parsed.hostname or "").lower()
    port = f":{parsed.port}" if parsed.port is not None else ""
    path = parsed.path.rstrip("/")
    return f"{parsed.scheme.lower()}://{host}{port}{path}"


def resolve_target(request: SearchRequest, settings: Settings) -> tuple[str, str]:
    configured_url = (settings.qdrant_url or "").strip()
    if request.qdrant_url is not None:
        url = request.qdrant_url.strip()
    else:
        url = configured_url
    if not url:
        raise SearchError("qdrant_url is required")
    url = _http_url(url, "qdrant_url")
    if request.qdrant_api_key is not None:
        api_key = request.qdrant_api_key.strip()
    elif configured_url and _destination_key(url) == _destination_key(configured_url):
        api_key = (settings.qdrant_api_key or "").strip()
    else:
        api_key = ""
    return url, api_key


def resolve_backend(
    request: SearchRequest,
    settings: Settings,
    default: EmbeddingBackend,
) -> tuple[EmbeddingBackend, str, str]:
    model = (request.embedding_model or settings.embedding_model or "").strip()
    if not model:
        raise SearchError("embedding_model is required")
    kind = request.embedding_backend
    url = (request.embedding_url or "").strip()
    if kind is None and not url:
        resolved = (settings.embedding_backend or "ollama").strip().lower() or "ollama"
        return default, resolved, model
    resolved = kind or (settings.embedding_backend or "ollama").strip().lower() or "ollama"
    if resolved not in _BACKENDS:
        raise SearchError("embedding_backend must be ollama or openai")
    if not url:
        url = (settings.embedding_url or settings.ollama_url).strip()
    url = _http_url(url, "embedding_url")
    return make_embedding_backend(resolved, url), resolved, model


def parse_search_request(payload: Any) -> SearchRequest:
    if not isinstance(payload, dict):
        raise SearchError("Search body must be a JSON object")
    try:
        request = SearchRequest.model_validate(payload)
    except ValidationError as exc:
        secret = payload.get("qdrant_api_key")
        message = redact(f"Invalid search request: {exc}", secret if isinstance(secret, str) else None)
        raise SearchError(message) from None
    for item in request.filters:
        try:
            item.check_complete()
        except ValueError as exc:
            raise SearchError(str(exc)) from None
    return request


def run_search(
    request: SearchRequest,
    *,
    settings: Settings,
    embeddings: EmbeddingBackend,
    searcher: QdrantSearcher,
) -> dict[str, Any]:
    url, api_key = resolve_target(request, settings)
    collection = request.collection
    try:
        layout = searcher.describe(url=url, api_key=api_key, collection=collection)
    except SearchError:
        raise
    except Exception as exc:
        raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None
    if layout is None:
        raise SearchError(
            f"Collection {collection!r} was not found",
            status_code=404,
            error_type="not_found",
        )

    backend, kind, model = resolve_backend(request, settings, embeddings)
    try:
        vectors = backend.embed([request.query], model)
    except SearchError:
        raise
    except Exception as exc:
        raise SearchError(
            redact(f"Embedding request failed: {exc}", api_key),
            status_code=502,
            error_type="embedding_error",
        ) from None
    if len(vectors) != 1 or not isinstance(vectors[0], list) or not vectors[0]:
        raise SearchError(
            "Embedding backend returned no vector",
            status_code=502,
            error_type="embedding_error",
        )
    try:
        vector = [float(value) for value in vectors[0]]
    except (TypeError, ValueError):
        raise SearchError(
            "Embedding backend returned a non-numeric vector",
            status_code=502,
            error_type="embedding_error",
        ) from None
    if layout.vector_size is not None and layout.vector_size != len(vector):
        raise SearchError(
            f"Collection {collection!r} has vector size {layout.vector_size}, "
            f"but {model} produces vectors of size {len(vector)}. Refusing to search.",
            status_code=409,
            error_type="dimension_mismatch",
        )

    try:
        hits = searcher.query_dense(
            url=url,
            api_key=api_key,
            collection=collection,
            vector=vector,
            limit=request.limit,
            offset=request.offset,
            filters=request.filters,
            score_threshold=request.score_threshold,
            using=layout.using,
        )
    except SearchError:
        raise
    except Exception as exc:
        raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None

    log.info(
        "search collection=%s limit=%s offset=%s model=%s backend=%s hits=%s",
        collection,
        request.limit,
        request.offset,
        model,
        kind,
        len(hits),
    )
    next_offset = request.offset + request.limit if len(hits) == request.limit else None
    return {
        "results": [
            {"id": hit.id, "score": hit.score, "payload": hit.payload}
            for hit in hits
        ],
        "limit": request.limit,
        "offset": request.offset,
        "next_offset": next_offset,
        "embedding_model": model,
        "embedding_backend": kind,
        "embedding_dim": len(vector),
        "collection": collection,
    }


def _default_client(url: str, api_key: str):
    try:
        from qdrant_client import QdrantClient
    except ImportError as exc:
        raise SearchError("qdrant-client is not installed", status_code=502, error_type="qdrant_error") from exc
    if api_key:
        return QdrantClient(url=url, api_key=api_key, timeout=30)
    return QdrantClient(url=url, timeout=30)


def _payload_dict(payload: Any) -> dict[str, Any]:
    if payload is None:
        return {}
    if isinstance(payload, dict):
        return payload
    dumped = getattr(payload, "model_dump", None)
    if callable(dumped):
        data = dumped()
        if isinstance(data, dict):
            return data
    return dict(payload)


class QdrantPointSearcher:
    def __init__(self, client_factory: Callable[[str, str], Any] | None = None) -> None:
        self._client_factory = client_factory or _default_client

    def _open(self, url: str, api_key: str):
        if not url:
            raise SearchError("qdrant_url is required")
        try:
            return self._client_factory(url, api_key)
        except SearchError:
            raise
        except Exception as exc:
            raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None

    def describe(self, *, url: str, api_key: str, collection: str) -> CollectionLayout | None:
        client = self._open(url, api_key)
        try:
            if not client.collection_exists(collection_name=collection):
                return None
            info = client.get_collection(collection_name=collection)
            return CollectionLayout(
                vector_size=_collection_vector_size(info),
                using=dense_vector_name(info),
            )
        except SearchError:
            raise
        except Exception as exc:
            raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    def query_dense(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        vector: list[float],
        limit: int,
        offset: int,
        filters: list[PayloadFilter],
        score_threshold: float | None,
        using: str | None,
    ) -> list[ScoredHit]:
        client = self._open(url, api_key)
        try:
            response = client.query_points(
                collection_name=collection,
                query=vector,
                using=using,
                query_filter=build_query_filter(filters),
                limit=limit,
                offset=offset,
                with_payload=True,
                with_vectors=False,
                score_threshold=score_threshold,
            )
            points = getattr(response, "points", response)
            hits: list[ScoredHit] = []
            for point in points:
                hits.append(
                    ScoredHit(
                        id=str(point.id),
                        score=float(point.score),
                        payload=_payload_dict(point.payload),
                    )
                )
            return hits
        except SearchError:
            raise
        except Exception as exc:
            message = redact(str(exc), api_key)
            lowered = message.lower()
            if "dimension" in lowered or "vector dimension" in lowered:
                raise SearchError(message, status_code=409, error_type="dimension_mismatch") from None
            raise SearchError(message, status_code=502, error_type="qdrant_error") from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()
