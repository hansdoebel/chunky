"""Shared vector-store contract. Qdrant remains the default implementation."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Protocol, Sequence
from urllib.parse import urlparse, urlsplit

from chunky_worker.qdrant_ingest import IngestError, PreparedPoint, QdrantCloudIngestor, redact

_FACTORIES: dict[str, Callable[..., "VectorStore"]] = {}
_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,54}$")
_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
_STORE_NAME = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
SCALAR_KEYS = (
    "source",
    "page",
    "page_end",
    "year",
    "doi",
    "content_type",
    "record_type",
    "library_id",
    "doc_title",
    "language",
    "chunk_index",
)
STORE_LABELS = {
    "qdrant": "Worker Qdrant",
    "pgvector": "Postgres pgvector",
    "weaviate": "Weaviate",
    "milvus": "Milvus",
    "chroma": "Chroma",
}


class StoreError(IngestError):
    def __init__(self, message: str, error_type: str = "store_error", status_code: int = 502) -> None:
        super().__init__(message, error_type)
        self.status_code = status_code


@dataclass(frozen=True)
class StoreEndpoint:
    url: str
    api_key: str
    collection: str
    distance: str = "cosine"


@dataclass(frozen=True)
class StorePoint:
    id: str
    vector: list[float]
    payload: dict[str, Any]


@dataclass(frozen=True)
class StoreHit:
    id: str
    score: float
    payload: dict[str, Any]


@dataclass(frozen=True)
class CollectionStats:
    vector_size: int
    distance: str
    count: int | None = None


@dataclass(frozen=True)
class HTTPResult:
    status_code: int
    body: Any


class HTTPTransport(Protocol):
    def send(self, method: str, url: str, *, headers: dict[str, str], json_body: Any | None = None) -> HTTPResult: ...


class SQLTransport(Protocol):
    def execute(self, statement: str, parameters: Sequence[Any] = ()) -> list[dict[str, Any]]: ...


class VectorStore(Protocol):
    kind: str
    supports_hybrid: bool

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None: ...

    def upsert(
        self,
        endpoint: StoreEndpoint,
        points: list[StorePoint],
        *,
        vector_size: int,
        distance: str,
        batch_size: int,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int: ...

    def query(
        self,
        endpoint: StoreEndpoint,
        *,
        vector: list[float],
        text: str,
        mode: str,
        limit: int,
        offset: int,
        filters: list[Any],
        score_threshold: float | None,
        weights: list[float] | None = None,
    ) -> list[StoreHit]: ...

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]: ...

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]: ...


@dataclass(frozen=True)
class FilterAtom:
    key: str
    op: str
    value: Any = None
    gt: float | None = None
    gte: float | None = None
    lt: float | None = None
    lte: float | None = None


@dataclass(frozen=True)
class CompiledFilters:
    must: tuple[FilterAtom, ...] = ()
    must_not: tuple[FilterAtom, ...] = ()
    should: tuple[FilterAtom, ...] = ()


def register_vector_store(kind: str, factory: Callable[..., VectorStore]) -> None:
    key = kind.strip().lower()
    if not _STORE_NAME.fullmatch(key):
        raise StoreError(f"Invalid vector store name: {kind}", "unsupported_vector_store", 400)
    _FACTORIES[key] = factory


def unregister_vector_store(kind: str) -> None:
    _FACTORIES.pop(kind.strip().lower(), None)


def require_store(kind: str) -> str:
    key = (kind or "").strip().lower()
    if not key or key not in _FACTORIES:
        raise StoreError(f"Unsupported vector store: {kind}", "unsupported_vector_store", 400)
    return key


def configured_store(value: str | None) -> str:
    key = (value or "").strip().lower()
    if not key:
        return "qdrant"
    return require_store(key)


def store_label(kind: str) -> str:
    return STORE_LABELS.get(kind, kind)


def open_vector_store(kind: str, **kwargs: Any) -> VectorStore:
    factory = _FACTORIES.get(require_store(kind))
    if factory is None:
        raise StoreError(f"Unsupported vector store: {kind}", "unsupported_vector_store", 400)
    return factory(**kwargs)


def collection_name(name: str) -> str:
    if not _NAME.fullmatch(name or ""):
        raise StoreError(
            "Collection names use letters, digits, and underscores, and start with a letter.",
            "invalid_collection",
            400,
        )
    return name


def quote_identifier(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,62}", name or ""):
        raise StoreError(f"Invalid SQL identifier: {name}", "invalid_collection", 400)
    return '"' + name + '"'


def table_name(collection: str) -> str:
    return quote_identifier("chunky_" + collection_name(collection))


def redact_text(text: str, *secrets: str | None) -> str:
    cleaned = text
    for secret in secrets:
        cleaned = redact(cleaned, secret)
    return cleaned


def url_password(url: str) -> str | None:
    try:
        return urlparse(url).password
    except ValueError:
        return None


def validate_store_url(kind: str, url: str) -> str:
    value = (url or "").strip()
    try:
        parsed = urlsplit(value)
        parsed.port
    except ValueError as exc:
        raise StoreError("Vector store URL is invalid", "invalid_store_url", 400) from exc
    if kind == "pgvector":
        if parsed.scheme not in {"postgresql", "postgres"} or not parsed.hostname or parsed.fragment:
            raise StoreError(
                "pgvector requires a postgresql:// URL without a fragment",
                "invalid_store_url",
                400,
            )
        return value
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise StoreError(
            "Vector store URL must be an http(s) URL without credentials, query, or fragment",
            "invalid_store_url",
            400,
        )
    return value


def store_url_configured(kind: str, url: str) -> bool:
    try:
        validate_store_url(kind, url)
    except StoreError:
        return False
    return True


def join_url(base: str, path: str) -> str:
    return base.rstrip("/") + "/" + path.lstrip("/")


def http_headers(api_key: str, *, chroma: bool = False) -> dict[str, str]:
    headers = {"content-type": "application/json"}
    if api_key:
        headers["authorization"] = f"Bearer {api_key}"
        if chroma:
            headers["x-chroma-token"] = api_key
    return headers


def http_json(
    transport: HTTPTransport,
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    json_body: Any | None,
    endpoint: StoreEndpoint,
) -> Any:
    try:
        result = transport.send(method, url, headers=headers, json_body=json_body)
    except StoreError:
        raise
    except Exception as exc:
        raise StoreError(
            redact_text(str(exc), endpoint.api_key, url_password(endpoint.url)),
            "store_error",
            502,
        ) from None
    if result.status_code >= 400:
        if isinstance(result.body, str):
            message = result.body
        else:
            message = json.dumps(result.body)[:500] if result.body is not None else ""
        status = 404 if result.status_code == 404 else 502
        error_type = "not_found" if status == 404 else "store_error"
        raise StoreError(
            redact_text(message or f"HTTP {result.status_code}", endpoint.api_key, url_password(endpoint.url)),
            error_type,
            status,
        )
    return result.body


class HttpxTransport:
    def __init__(self, timeout: float = 30.0, client: Any | None = None) -> None:
        self.timeout = timeout
        self.client = client

    def send(self, method: str, url: str, *, headers: dict[str, str], json_body: Any | None = None) -> HTTPResult:
        import httpx

        def perform(client: Any) -> HTTPResult:
            response = client.request(method, url, headers=headers, json=json_body)
            body: Any = None
            if response.content:
                try:
                    body = response.json()
                except ValueError:
                    body = response.text
            return HTTPResult(response.status_code, body)

        if self.client is not None:
            return perform(self.client)
        with httpx.Client(timeout=self.timeout) as client:
            return perform(client)


class PsycopgTransport:
    def __init__(self, url: str) -> None:
        self.url = url

    def execute(self, statement: str, parameters: Sequence[Any] = ()) -> list[dict[str, Any]]:
        try:
            import psycopg
            from psycopg.rows import dict_row
        except ImportError as exc:
            raise StoreError(
                "psycopg is not installed. Install psycopg[binary] to write to pgvector.",
                "missing_driver",
                502,
            ) from exc
        try:
            with psycopg.connect(self.url, row_factory=dict_row) as conn:
                with conn.cursor() as cursor:
                    cursor.execute(statement, tuple(parameters))
                    if cursor.description is None:
                        return []
                    return list(cursor.fetchall())
        except StoreError:
            raise
        except Exception as exc:
            raise StoreError(redact_text(str(exc), url_password(self.url)), "store_error", 502) from None


def vector_text(vector: list[float]) -> str:
    if not vector:
        raise StoreError("Vector is empty", "invalid_vector", 400)
    parts: list[str] = []
    for value in vector:
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise StoreError("Vector must be finite numbers", "invalid_vector", 400)
        parts.append(format(float(value), ".8g"))
    return "[" + ",".join(parts) + "]"


def point_text(payload: dict[str, Any]) -> str:
    for key in ("embedding_text", "text"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def record_fields(point: StorePoint) -> dict[str, Any]:
    payload = dict(point.payload)
    fields: dict[str, Any] = {
        "body": json.dumps(payload, separators=(",", ":"), sort_keys=True, default=str),
        "text": point_text(payload),
        "chunky_id": point.id,
    }
    for key in SCALAR_KEYS:
        value = payload.get(key)
        if isinstance(value, str):
            if value:
                fields[key] = value
        elif isinstance(value, bool) or isinstance(value, int):
            fields[key] = value
    headings = payload.get("headings")
    if isinstance(headings, list) and headings:
        fields["headings"] = " ".join(str(item) for item in headings)
    return fields


def payload_from_record(record: dict[str, Any]) -> dict[str, Any]:
    for key in ("body", "payload"):
        body = record.get(key)
        if isinstance(body, dict):
            return dict(body)
        if isinstance(body, str) and body:
            try:
                loaded = json.loads(body)
            except json.JSONDecodeError:
                loaded = None
            if isinstance(loaded, dict):
                return loaded
    payload: dict[str, Any] = {}
    for key in ("text", *SCALAR_KEYS, "headings"):
        if record.get(key) is not None:
            payload[key] = record[key]
    return payload


def compile_filters(filters: list[Any] | None) -> CompiledFilters | None:
    if not filters:
        return None
    must: list[FilterAtom] = []
    must_not: list[FilterAtom] = []
    should: list[FilterAtom] = []
    for item in filters:
        key = str(getattr(item, "key", "")).strip()
        if not _KEY.fullmatch(key):
            raise StoreError(f"Invalid filter key: {key!r}", "invalid_filter", 400)
        match = getattr(item, "match", None)
        text = getattr(item, "text", None)
        any_values = getattr(item, "any", None) or None
        empty = bool(getattr(item, "empty", False))
        bounds = {bound: getattr(item, bound, None) for bound in ("gt", "gte", "lt", "lte")}
        has_range = any(value is not None for value in bounds.values())
        if match is None and text is None and not any_values and not empty and not has_range:
            raise StoreError(f"Filter {key!r} needs a match, text, any, empty, or a range", "invalid_filter", 400)
        atoms: list[FilterAtom] = []
        if empty:
            atoms.append(FilterAtom(key, "empty"))
        if text is not None:
            atoms.append(FilterAtom(key, "text", str(text)))
        if any_values:
            atoms.append(FilterAtom(key, "any", tuple(any_values)))
        if match is not None:
            atoms.append(FilterAtom(key, "eq", match))
        if has_range:
            atoms.append(FilterAtom(key, "range", **bounds))
        if getattr(item, "should", False):
            should.extend(atoms)
        elif getattr(item, "negate", False):
            must_not.extend(atoms)
        else:
            must.extend(atoms)
    if not must and not must_not and not should:
        return None
    return CompiledFilters(tuple(must), tuple(must_not), tuple(should))


def apply_threshold(hits: list[StoreHit], threshold: float | None) -> list[StoreHit]:
    if threshold is None:
        return hits
    return [hit for hit in hits if hit.score >= threshold]


def fuse_ranks(
    rankings: list[list[StoreHit]],
    *,
    weights: list[float] | None,
    limit: int,
    offset: int,
) -> list[StoreHit]:
    if weights is not None and len(weights) != len(rankings):
        raise StoreError("rrf_weights must match the ranked lists", "invalid_search", 400)
    scores: dict[str, float] = {}
    payloads: dict[str, dict[str, Any]] = {}
    for index, hits in enumerate(rankings):
        weight = 1.0 if weights is None else float(weights[index])
        for rank, hit in enumerate(hits):
            scores[hit.id] = scores.get(hit.id, 0.0) + weight / (60.0 + rank + 1.0)
            payloads.setdefault(hit.id, hit.payload)
    ordered = sorted(scores, key=lambda item: (-scores[item], item))
    chosen = ordered[offset : offset + limit]
    return [StoreHit(item, scores[item], payloads[item]) for item in chosen]


def resolve_job_store(job_settings: Any, worker_settings: Any) -> str:
    requested = (getattr(job_settings, "vector_store", "") or "").strip()
    if requested:
        return require_store(requested)
    if getattr(job_settings, "use_worker_qdrant", False):
        return configured_store(getattr(worker_settings, "vector_store", ""))
    return "qdrant"


def resolve_search_store(request: Any, worker_settings: Any) -> str:
    from chunky_worker.search import SearchError

    try:
        if getattr(request, "use_worker_qdrant", False):
            server = configured_store(getattr(worker_settings, "vector_store", ""))
            requested = (getattr(request, "vector_store", "") or "").strip()
            if requested and require_store(requested) != server:
                raise SearchError(
                    "Worker vector store does not accept a client store override",
                    status_code=400,
                    error_type="invalid_store",
                )
            return server
        requested = (getattr(request, "vector_store", "") or "").strip()
        if not requested:
            return "qdrant"
        return require_store(requested)
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None


def endpoint_for_job(job_settings: Any, worker_settings: Any, kind: str) -> StoreEndpoint:
    from chunky_worker.qdrant_ingest import normalize_distance

    if getattr(job_settings, "use_worker_qdrant", False):
        url = (getattr(worker_settings, "vector_store_url", "") or getattr(job_settings, "vector_store_url", "") or "").strip()
        key = (getattr(worker_settings, "vector_store_api_key", "") or getattr(job_settings, "vector_store_api_key", "") or "").strip()
    else:
        url = (getattr(job_settings, "vector_store_url", "") or "").strip()
        key = (getattr(job_settings, "vector_store_api_key", "") or "").strip()
    distance = normalize_distance(getattr(job_settings, "qdrant_distance", "cosine") or "cosine")
    collection = collection_name(getattr(job_settings, "qdrant_collection", "") or "documents")
    return StoreEndpoint(validate_store_url(kind, url), key, collection, distance)


def endpoint_for_search(request: Any, worker_settings: Any, kind: str) -> StoreEndpoint:
    from chunky_worker.search import SearchError

    try:
        if getattr(request, "use_worker_qdrant", False):
            if (
                getattr(request, "qdrant_url", None) is not None
                or getattr(request, "qdrant_api_key", None) is not None
                or (getattr(request, "vector_store_url", "") or "").strip()
                or (getattr(request, "vector_store_api_key", "") or "").strip()
            ):
                raise StoreError(
                    "Worker vector store does not accept client credentials or URLs",
                    "invalid_store",
                    400,
                )
            url = (getattr(worker_settings, "vector_store_url", "") or "").strip()
            key = (getattr(worker_settings, "vector_store_api_key", "") or "").strip()
        else:
            url = (getattr(request, "vector_store_url", "") or "").strip()
            supplied = getattr(request, "vector_store_api_key", None)
            key = supplied.strip() if isinstance(supplied, str) else ""
        collection = collection_name(getattr(request, "collection", "") or "")
        return StoreEndpoint(validate_store_url(kind, url), key, collection, "cosine")
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None


def stored_vector_size(kind: str, endpoint: StoreEndpoint) -> int | None:
    stats = open_vector_store(kind).describe(endpoint)
    if stats is None:
        return None
    return stats.vector_size


def upsert_prepared(
    kind: str,
    endpoint: StoreEndpoint,
    points: list[Any],
    *,
    vector_size: int,
    batch_size: int,
    on_progress: Callable[[int, int], None] | None = None,
) -> int:
    if batch_size < 1:
        raise StoreError("batch size must be at least 1", "invalid_batch", 400)
    prepared = [
        StorePoint(id=str(point.id), vector=list(point.vector), payload=dict(point.payload))
        for point in points
    ]
    return open_vector_store(kind).upsert(
        endpoint,
        prepared,
        vector_size=vector_size,
        distance=endpoint.distance,
        batch_size=batch_size,
        on_progress=on_progress,
    )


def search_collection(request: Any, *, settings: Any, embeddings: Any, kind: str) -> dict[str, Any]:
    import logging

    from chunky_worker.search import SearchError, embed_query_vector, resolve_backend

    endpoint = endpoint_for_search(request, settings, kind)
    if request.papers_first or request.expand_documents or request.expand_section:
        raise SearchError(
            "Paper summaries and section expansion stay on Qdrant collections.",
            status_code=400,
            error_type="unsupported_search_mode",
        )
    store = open_vector_store(kind)
    if request.mode == "hybrid" and not store.supports_hybrid:
        raise SearchError(
            f"{store_label(kind)} supports dense search.",
            status_code=400,
            error_type="unsupported_search_mode",
        )
    try:
        stats = store.describe(endpoint)
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None
    if stats is None:
        raise SearchError(
            f"Collection {endpoint.collection!r} was not found",
            status_code=404,
            error_type="not_found",
        )
    backend, backend_kind, model = resolve_backend(request, settings, embeddings)
    vector = embed_query_vector(backend, model, request.query, endpoint.api_key)
    if stats.vector_size != len(vector):
        raise SearchError(
            f"Collection {endpoint.collection!r} has vector size {stats.vector_size}, "
            f"but {model} produces vectors of size {len(vector)}. Refusing to search.",
            status_code=409,
            error_type="dimension_mismatch",
        )
    try:
        hits = store.query(
            endpoint,
            vector=vector,
            text=request.query,
            mode=request.mode,
            limit=request.limit,
            offset=request.offset,
            filters=list(request.filters),
            score_threshold=request.score_threshold,
            weights=request.rrf_weights,
        )
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None
    except SearchError:
        raise
    except Exception as exc:
        raise SearchError(
            redact_text(str(exc), endpoint.api_key, url_password(endpoint.url)),
            status_code=502,
            error_type="store_error",
        ) from None
    logging.getLogger(__name__).info(
        "search store=%s collection=%s limit=%s offset=%s hits=%s",
        kind,
        endpoint.collection,
        request.limit,
        request.offset,
        len(hits),
    )
    next_offset = request.offset + request.limit if len(hits) == request.limit else None
    return {
        "results": [{"id": hit.id, "score": hit.score, "payload": hit.payload} for hit in hits],
        "limit": request.limit,
        "offset": request.offset,
        "next_offset": next_offset,
        "embedding_model": model,
        "embedding_backend": backend_kind,
        "embedding_dim": len(vector),
        "collection": endpoint.collection,
        "vector_store": kind,
    }


def collection_names(kind: str, endpoint: StoreEndpoint) -> dict[str, Any]:
    from chunky_worker.search import SearchError

    try:
        names = open_vector_store(kind).list_collections(endpoint)
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None
    return {
        "collections": [{"name": name} for name in names],
        "target_label": store_label(kind),
    }


def collection_page(kind: str, endpoint: StoreEndpoint, *, limit: int, offset: int, settings: Any) -> dict[str, Any]:
    from chunky_worker.search import SearchError

    store = open_vector_store(kind)
    try:
        collection_name(endpoint.collection)
        raw = store.scroll(endpoint, limit=limit, offset=offset)
    except StoreError as exc:
        raise SearchError(str(exc), status_code=exc.status_code, error_type=exc.error_type) from None
    distance = raw.get("distance") or endpoint.distance or "cosine"
    dimensions = raw.get("dimensions")
    backend = settings.embedding_backend if settings.embedding_backend in {"ollama", "openai"} else "ollama"
    return {
        "collection": endpoint.collection,
        "points": raw.get("points") or [],
        "limit": limit,
        "next_offset": raw.get("next_offset"),
        "points_count": raw.get("points_count"),
        "semantic_search_available": True,
        "semantic_search_reason": None,
        "embedding": {
            "backend": backend,
            "model": settings.embedding_model,
            "dimensions": dimensions if isinstance(dimensions, int) else 0,
            "distance": distance,
            "hybrid": bool(store.supports_hybrid),
        },
    }


class QdrantVectorStore:
    kind = "qdrant"
    supports_hybrid = True

    def __init__(self, ingestor: Any | None = None, searcher: Any | None = None) -> None:
        self.ingestor = ingestor or QdrantCloudIngestor()
        self.searcher = searcher

    def _searcher(self) -> Any:
        if self.searcher is None:
            from chunky_worker.search import QdrantPointSearcher

            self.searcher = QdrantPointSearcher()
        return self.searcher

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        size = self.ingestor.collection_vector_size(
            url=endpoint.url,
            api_key=endpoint.api_key,
            collection=endpoint.collection,
        )
        if size is None:
            return None
        return CollectionStats(vector_size=size, distance=endpoint.distance)

    def upsert(
        self,
        endpoint: StoreEndpoint,
        points: list[StorePoint],
        *,
        vector_size: int,
        distance: str,
        batch_size: int,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int:
        prepared = [PreparedPoint(id=point.id, vector=list(point.vector), payload=dict(point.payload)) for point in points]
        return self.ingestor.upsert_cloud(
            url=endpoint.url,
            api_key=endpoint.api_key,
            collection=endpoint.collection,
            points=prepared,
            vector_size=vector_size,
            distance=distance,
            batch_size=batch_size,
            on_progress=on_progress,
        )

    def query(
        self,
        endpoint: StoreEndpoint,
        *,
        vector: list[float],
        text: str,
        mode: str,
        limit: int,
        offset: int,
        filters: list[Any],
        score_threshold: float | None,
        weights: list[float] | None = None,
    ) -> list[StoreHit]:
        searcher = self._searcher()
        shared = {
            "url": endpoint.url,
            "api_key": endpoint.api_key,
            "collection": endpoint.collection,
            "vector": vector,
            "limit": limit,
            "offset": offset,
            "filters": filters,
            "score_threshold": score_threshold,
            "using": None,
        }
        if mode == "hybrid":
            hits = searcher.query_hybrid(**shared, text=text, weights=weights)
        elif mode == "dense":
            hits = searcher.query_dense(**shared)
        else:
            raise StoreError("mode must be dense or hybrid", "invalid_search", 400)
        return [StoreHit(str(hit.id), float(hit.score), dict(hit.payload or {})) for hit in hits]

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]:
        payload = self._searcher().list_collections(url=endpoint.url, api_key=endpoint.api_key)
        return [str(row.get("name")) for row in payload.get("collections", [])]

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]:
        return self._searcher().scroll_points(
            url=endpoint.url,
            api_key=endpoint.api_key,
            collection=endpoint.collection,
            limit=limit,
            offset=offset,
        )


def _open_qdrant(**kwargs: Any) -> QdrantVectorStore:
    return QdrantVectorStore(ingestor=kwargs.get("ingestor"), searcher=kwargs.get("searcher"))


register_vector_store("qdrant", _open_qdrant)
