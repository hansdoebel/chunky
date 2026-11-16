"""Embed a query and search a Qdrant collection. Credentials stay in memory."""

from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Protocol
from urllib.parse import urlparse, urlsplit
from uuid import UUID

from pydantic import BaseModel, Field, ValidationError, field_validator

from chunky_worker.embeddings import EmbeddingBackend, make_embedding_backend
from chunky_worker.qdrant_ingest import BM25_TEXT_FIELD, IngestError, _collection_vector_size, dense_vector_name, embedding_identity, redact, validate_collection_identity
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
    text: str | None = None
    any: list[str] | None = None
    negate: bool = False
    empty: bool = False
    should: bool = False
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

    @field_validator("text")
    @classmethod
    def text_is_not_empty(cls, value: str | None) -> str | None:
        if value is None:
            return None
        text = value.strip()
        if not text:
            raise ValueError("text must not be empty")
        return text

    def check_complete(self) -> None:
        if self.match is None and self.text is None and not self.any and not self.empty and not self.has_range():
            raise ValueError(f"Filter {self.key!r} needs a match, text, any, empty, or a range")

class SearchRequest(BaseModel):
    query: str
    collection: str
    mode: str = "dense"
    use_worker_qdrant: bool = False
    qdrant_url: str | None = None
    qdrant_api_key: str | None = Field(default=None, repr=False)
    embedding_model: str | None = None
    embedding_backend: str | None = None
    embedding_url: str | None = None
    limit: int = Field(default=10, ge=1, le=MAX_LIMIT)
    offset: int = Field(default=0, ge=0)
    score_threshold: float | None = None
    filters: list[PayloadFilter] = Field(default_factory=list)
    papers_first: bool = False
    expand_documents: bool = False
    expand_section: bool = False
    section_ratio: float = 0.5
    rrf_weights: list[float] | None = None

    @field_validator("query", "collection")
    @classmethod
    def required_text(cls, value: str) -> str:
        text = value.strip()
        if not text:
            raise ValueError("must not be empty")
        return text

    @field_validator("mode")
    @classmethod
    def known_mode(cls, value: str) -> str:
        mode = value.strip().lower()
        if mode not in {"dense", "hybrid"}:
            raise ValueError("mode must be dense or hybrid")
        return mode

    @field_validator("rrf_weights")
    @classmethod
    def two_weights(cls, value: list[float] | None) -> list[float] | None:
        if value is None:
            return None
        if len(value) != 2 or any(item < 0 for item in value):
            raise ValueError("rrf_weights must be two non-negative numbers")
        return value

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
    info: Any = None

@dataclass
class ScoredHit:
    id: str
    score: float
    payload: dict[str, Any]

class QdrantSearcher(Protocol):
    def list_collections(self, *, url: str, api_key: str) -> dict:
        ...

    def scroll_points(self, *, url: str, api_key: str, collection: str, limit: int, offset: int | str | None) -> dict:
        ...

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
        ensure_indexes: bool = True,
        identity: dict | None = None,
    ) -> list[ScoredHit]:
        ...

    def query_hybrid(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        vector: list[float],
        text: str,
        limit: int,
        offset: int,
        filters: list[PayloadFilter],
        score_threshold: float | None,
        using: str | None,
        weights: list[float] | None,
        ensure_indexes: bool = True,
        identity: dict | None = None,
    ) -> list[ScoredHit]:
        ...

def hybrid_query_arguments(
    *,
    vector: list[float],
    text: str,
    using: str | None,
    filters: list[PayloadFilter],
    limit: int,
    offset: int,
    weights: list[float] | None,
) -> dict[str, Any]:
    from qdrant_client.models import Prefetch, Rrf, RrfQuery, TextQuery

    query_filter = build_query_filter(filters)
    prefetch_limit = max(limit + max(offset, 0), 1)
    dense = Prefetch(query=vector, using=using, filter=query_filter, limit=prefetch_limit)
    lexical = Prefetch(query=TextQuery(text=text), using=BM25_TEXT_FIELD, filter=query_filter, limit=prefetch_limit)
    rrf = Rrf(weights=weights) if weights else Rrf()
    return {
        "prefetch": [dense, lexical],
        "query": RrfQuery(rrf=rrf),
        "query_filter": query_filter,
        "limit": limit,
        "offset": offset,
        "with_payload": True,
        "with_vectors": False,
    }

def source_scroll_filter(source: str, library_filters: list[PayloadFilter]):
    from qdrant_client.models import FieldCondition, Filter, MatchValue

    library = build_query_filter(library_filters)
    must = [FieldCondition(key="source", match=MatchValue(value=source))]
    must_not = None
    if library is not None:
        if library.must:
            must.extend(library.must)
        must_not = library.must_not
    return Filter(must=must, must_not=must_not)


def _load_element_types():
    import sys
    from pathlib import Path

    scripts = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import element_types

    return element_types


def _element_clause(stored: list[str], kinds: list[str]):
    from qdrant_client.models import FieldCondition, Filter, MatchAny

    return Filter(
        should=[
            FieldCondition(key="content_type", match=MatchAny(any=stored)),
            FieldCondition(key="content_types", match=MatchAny(any=kinds)),
        ]
    )


def _element_request(item: PayloadFilter) -> tuple[list[str], list[str]] | None:
    raw: list[str] = []
    if isinstance(item.match, str):
        raw = [item.match]
    elif item.any:
        raw = [str(value) for value in item.any]
    if not raw or item.text is not None or item.has_range():
        return None
    types = _load_element_types()
    stored: list[str] = []
    kinds: list[str] = []
    for value in raw:
        kind = types.element_filter_kind(value)
        if kind is None:
            return None
        if kind not in kinds:
            kinds.append(kind)
        for alias in types.stored_values(kind):
            if alias not in stored:
                stored.append(alias)
    return stored, kinds


def build_query_filter(filters: list[PayloadFilter]):
    if not filters:
        return None
    from qdrant_client.models import FieldCondition, Filter, MatchAny, MatchText, MatchValue, Range

    must = []
    should = []
    must_not = []
    for item in filters:
        item.check_complete()
        if item.key == "content_type":
            expanded = _element_request(item)
            if expanded is not None:
                clause = _element_clause(*expanded)
                target = should if item.should else must_not if item.negate else must
                target.append(clause)
                continue
        if item.empty:
            from qdrant_client.models import IsEmptyCondition, PayloadField
            condition = IsEmptyCondition(is_empty=PayloadField(key=item.key))
            target = should if item.should else must_not if item.negate else must
            target.append(condition)
            continue
        kwargs: dict[str, Any] = {"key": item.key}
        if item.text is not None:
            kwargs["match"] = MatchText(text=item.text)
        elif item.any:
            kwargs["match"] = MatchAny(any=item.any)
        elif item.match is not None:
            kwargs["match"] = MatchValue(value=item.match)
        if item.has_range():
            kwargs["range"] = Range(gt=item.gt, gte=item.gte, lt=item.lt, lte=item.lte)
        condition = FieldCondition(**kwargs)
        target = should if item.should else must_not if item.negate else must
        target.append(condition)
    if should:
        must.append(Filter(should=should))
    if not must and not must_not:
        return None
    return Filter(must=must or None, must_not=must_not or None)

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

def worker_read_target(settings: Settings) -> tuple[str, str]:
    value = (settings.qdrant_url or "").strip()
    try:
        parsed = urlsplit(value)
        valid = parsed.scheme in {"http", "https"} and parsed.hostname and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment
        parsed.port
    except ValueError:
        valid = False
    if not valid:
        raise SearchError("Worker Qdrant is not configured with a safe HTTP(S) URL", error_type="qdrant_not_configured")
    return value, (settings.qdrant_api_key or "").strip()


def _field(value, key, default=None):
    return value.get(key, default) if isinstance(value, dict) else getattr(value, key, default)


def collection_identity(info) -> dict:
    identity = _field(_field(_field(info, "config"), "metadata") or {}, "chunky_embedding")
    valid = (
        isinstance(identity, dict)
        and type(identity.get("schema")) is int
        and identity["schema"] == 1
        and identity.get("backend") in _BACKENDS
        and isinstance(identity.get("model"), str)
        and bool(identity["model"].strip())
        and isinstance(identity.get("endpoint_sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", identity["endpoint_sha256"])
        and type(identity.get("dimensions")) is int
        and identity["dimensions"] > 0
        and identity.get("distance") in {"cosine", "dot", "euclid"}
        and type(identity.get("hybrid")) is bool
    )
    if not valid:
        raise SearchError("Collection embedding identity is unknown. Browse its payloads or choose a browser-managed collection for semantic search.", status_code=409, error_type="embedding_identity_mismatch")
    try:
        validate_collection_identity(info, identity)
    except IngestError as exc:
        raise SearchError(str(exc), status_code=409, error_type="embedding_identity_mismatch") from None
    return dict(identity)


def parse_scroll_offset(value: str | None) -> int | str | None:
    if value is None:
        return None
    if len(value) > 64:
        raise SearchError("offset is too long", status_code=422, error_type="invalid_offset")
    if re.fullmatch(r"[0-9]+", value):
        number = int(value)
        if number <= 2**64 - 1:
            return number
    try:
        return str(UUID(value))
    except ValueError:
        raise SearchError("offset must be a Qdrant point UUID or unsigned integer", status_code=422, error_type="invalid_offset") from None


def resolve_target(request: SearchRequest, settings: Settings) -> tuple[str, str]:
    if request.use_worker_qdrant:
        if request.qdrant_url is not None or request.qdrant_api_key is not None:
            raise SearchError("Worker Qdrant does not accept client credentials or URLs")
        return worker_read_target(settings)
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

PASSAGE_ONLY_KEYS = {"content_type", "page", "page_end", "headings", "section"}

def _chunk_index(payload: dict[str, Any]) -> int:
    raw = payload.get("chunk_index")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return 10**9

def _heading_list(payload: dict[str, Any]) -> list[str]:
    headings = payload.get("headings") or []
    if isinstance(headings, list):
        return [str(item) for item in headings]
    return []

def _section_key(source: str, headings: list[str]) -> str:
    return source + "\n" + "\n".join(headings)

def expand_section_hits(hits: list[ScoredHit], siblings: list[dict[str, Any]], threshold: float) -> list[ScoredHit]:
    ratio = min(max(threshold, 0.0), 1.0) if threshold == threshold else 0.5
    groups: dict[str, list[ScoredHit]] = {}
    for hit in hits:
        payload = hit.payload or {}
        if payload.get("record_type") == "document":
            continue
        headings = _heading_list(payload)
        key = _section_key(str(payload.get("source") or ""), headings)
        groups.setdefault(key, []).append(hit)
    by_group: dict[str, list[dict[str, Any]]] = {}
    for item in siblings:
        if item.get("record_type") == "document":
            continue
        headings = _heading_list(item)
        key = _section_key(str(item.get("source") or ""), headings)
        by_group.setdefault(key, []).append(item)
    merging: set[str] = set()
    for key, group in groups.items():
        headings = _heading_list(group[0].payload or {})
        if not headings:
            continue
        population = max(len(by_group.get(key, [])), len(group))
        share = len(group) / population
        if population > 1 and share + 1e-9 >= ratio:
            merging.add(key)
    emitted: set[str] = set()
    result: list[ScoredHit] = []
    for hit in hits:
        payload = hit.payload or {}
        if payload.get("record_type") == "document":
            result.append(hit)
            continue
        headings = _heading_list(payload)
        key = _section_key(str(payload.get("source") or ""), headings)
        if key not in merging:
            result.append(hit)
            continue
        if key in emitted:
            continue
        emitted.add(key)
        section = by_group.get(key) or []
        if not section:
            section = []
            for member in groups[key]:
                body = dict(member.payload or {})
                body["id"] = member.id
                section.append(body)
        ordered = sorted(section, key=lambda item: (item.get("page") if isinstance(item.get("page"), int) else 10**9, _chunk_index(item), str(item.get("id") or "")))
        pages = [item.get("page") for item in ordered if isinstance(item.get("page"), int)]
        pages += [item.get("page_end") for item in ordered if isinstance(item.get("page_end"), int)]
        text = "\n\n".join(str(item.get("text") or "") for item in ordered)
        merged_payload = dict(groups[key][0].payload or {})
        merged_payload["chunk_ids"] = ",".join(member.id for member in groups[key])
        merged_payload["text"] = text
        if pages:
            merged_payload["page"] = min(pages)
            merged_payload["page_end"] = max(pages)
        result.append(ScoredHit(id=groups[key][0].id, score=max(member.score for member in groups[key]), payload=merged_payload))
    return result

def record_scope(filters: list[PayloadFilter], papers_first: bool) -> list[PayloadFilter]:
    scoped = [item for item in filters if item.key != "record_type"]
    if papers_first:
        scoped = [item for item in scoped if item.key not in PASSAGE_ONLY_KEYS]
        scoped.append(PayloadFilter(key="record_type", match="document"))
    else:
        scoped.append(PayloadFilter(key="record_type", match="document", negate=True))
    return scoped

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
    expected_identity = None
    if request.use_worker_qdrant:
        stored = collection_identity(layout.info)
        endpoint = request.embedding_url or settings.embedding_url or settings.ollama_url
        expected_identity = embedding_identity(backend=kind, model=model, endpoint=endpoint, dimensions=stored["dimensions"], distance=stored["distance"], hybrid=stored["hybrid"])
        try:
            validate_collection_identity(layout.info, expected_identity)
        except IngestError as exc:
            raise SearchError(str(exc), status_code=409, error_type="embedding_identity_mismatch") from None
        if request.mode == "hybrid" and not stored["hybrid"]:
            raise SearchError("This collection has no compatible hybrid layout. Use dense search.", status_code=409, error_type="embedding_identity_mismatch")
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
    if not all(math.isfinite(value) for value in vector):
        raise SearchError("Embedding backend returned a non-finite vector", status_code=502, error_type="embedding_error")
    expected_dimensions = expected_identity["dimensions"] if expected_identity is not None else layout.vector_size
    if expected_dimensions is not None and expected_dimensions != len(vector):
        raise SearchError(
            f"Collection {collection!r} has vector size {expected_dimensions}, "
            f"but {model} produces vectors of size {len(vector)}. Refusing to search.",
            status_code=409,
            error_type="dimension_mismatch",
        )

    def query(filters: list[PayloadFilter], offset: int) -> list[ScoredHit]:
        if request.mode == "hybrid":
            return searcher.query_hybrid(
                url=url,
                api_key=api_key,
                collection=collection,
                vector=vector,
                text=request.query,
                limit=request.limit,
                offset=offset,
                filters=filters,
                score_threshold=request.score_threshold,
                using=layout.using,
                weights=request.rrf_weights,
                **({"ensure_indexes": False, "identity": expected_identity} if request.use_worker_qdrant else {}),
            )
        return searcher.query_dense(
            url=url,
            api_key=api_key,
            collection=collection,
            vector=vector,
            limit=request.limit,
            offset=offset,
            filters=filters,
            score_threshold=request.score_threshold,
            using=layout.using,
            **({"ensure_indexes": False, "identity": expected_identity} if request.use_worker_qdrant else {}),
        )

    paper_count = 0
    try:
        hits = query(record_scope(request.filters, request.papers_first), request.offset)
        paper_count = len(hits)
        if request.papers_first and request.expand_documents and hits:
            sources: list[str] = []
            for hit in hits:
                source = str((hit.payload or {}).get("source") or "")
                if source and source not in sources:
                    sources.append(source)
            if sources:
                expanded = record_scope(
                    request.filters + [PayloadFilter(key="source", any=sources)],
                    False,
                )
                hits = hits + query(expanded, 0)
        if request.expand_section:
            sources = []
            for hit in hits:
                payload = hit.payload or {}
                if payload.get("record_type") == "document":
                    continue
                source = str(payload.get("source") or "")
                if source and source not in sources:
                    sources.append(source)
            loaded: list[dict[str, Any]] = []
            loader = getattr(searcher, "section_chunks", None)
            if callable(loader) and sources:
                library_filters = [item for item in request.filters if item.key == "library_id"]
                try:
                    loaded = loader(
                        url=url,
                        api_key=api_key,
                        collection=collection,
                        sources=sources,
                        library_filters=library_filters,
                    )
                except TypeError:
                    try:
                        loaded = loader(url=url, api_key=api_key, collection=collection, sources=sources)
                    except Exception:
                        loaded = []
                except Exception:
                    loaded = []
            hits = expand_section_hits(hits, loaded, request.section_ratio)
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
    next_offset = request.offset + request.limit if paper_count == request.limit else None
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

def _ensure_filter_indexes(client: Any, collection: str) -> bool:
    try:
        from chunky_worker.qdrant_ingest import ensure_payload_indexes

        ensure_payload_indexes(client, collection)
    except Exception:
        log.debug("payload index ensure skipped for %s", collection)
        return False
    return True

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
        self._indexed: set[tuple[str, str]] = set()

    def _ensure_indexes(self, client: Any, url: str, collection: str) -> None:
        key = (_destination_key(url), collection)
        if key in self._indexed:
            return
        if _ensure_filter_indexes(client, collection):
            self._indexed.add(key)

    def section_chunks(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        sources: list[str],
        library_filters: list[PayloadFilter] | None = None,
    ) -> list[dict[str, Any]]:
        client = self._open(url, api_key)
        found: list[dict[str, Any]] = []
        try:
            for source in sources:
                offset = None
                while True:
                    points, offset = client.scroll(
                        collection_name=collection,
                        scroll_filter=source_scroll_filter(source, library_filters or []),
                        limit=128,
                        offset=offset,
                        with_payload=True,
                        with_vectors=False,
                    )
                    for point in points:
                        payload = _payload_dict(point.payload)
                        if payload.get("record_type") == "document":
                            continue
                        payload["id"] = str(point.id)
                        found.append(payload)
                    if offset is None or len(found) >= 2000:
                        break
            return found
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    def _open(self, url: str, api_key: str):
        if not url:
            raise SearchError("qdrant_url is required")
        try:
            return self._client_factory(url, api_key)
        except SearchError:
            raise
        except Exception as exc:
            raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None

    def list_collections(self, *, url: str, api_key: str) -> dict:
        client = self._open(url, api_key)
        try:
            result = client.get_collections()
            rows = _field(result, "collections", [])
            return {"collections": [{"name": str(_field(row, "name"))} for row in rows], "target_label": "Worker Qdrant"}
        except SearchError:
            raise
        except Exception as exc:
            raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    def scroll_points(self, *, url: str, api_key: str, collection: str, limit: int, offset: int | str | None) -> dict:
        client = self._open(url, api_key)
        try:
            if not client.collection_exists(collection_name=collection):
                raise SearchError("Collection was not found", status_code=404, error_type="not_found")
            info = client.get_collection(collection_name=collection)
            identity = None
            reason = None
            try:
                identity = collection_identity(info)
            except SearchError as exc:
                reason = str(exc)
            points, next_offset = client.scroll(collection_name=collection, limit=limit, offset=offset, with_payload=True, with_vectors=False)
            return {
                "collection": collection,
                "points": [{"id": str(_field(point, "id")), "payload": _payload_dict(_field(point, "payload"))} for point in points],
                "limit": limit,
                "next_offset": str(next_offset) if next_offset is not None else None,
                "points_count": _field(info, "points_count"),
                "semantic_search_available": identity is not None,
                "semantic_search_reason": reason,
                "embedding": {key: identity[key] for key in ("backend", "model", "dimensions", "distance", "hybrid")} if identity is not None else None,
            }
        except SearchError:
            raise
        except Exception as exc:
            raise SearchError(redact(str(exc), api_key), status_code=502, error_type="qdrant_error") from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    def describe(self, *, url: str, api_key: str, collection: str) -> CollectionLayout | None:
        client = self._open(url, api_key)
        try:
            if not client.collection_exists(collection_name=collection):
                return None
            info = client.get_collection(collection_name=collection)
            return CollectionLayout(
                vector_size=_collection_vector_size(info),
                using=dense_vector_name(info),
                info=info,
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
        ensure_indexes: bool = True,
        identity: dict | None = None,
    ) -> list[ScoredHit]:
        client = self._open(url, api_key)
        try:
            if identity is not None:
                try:
                    validate_collection_identity(client.get_collection(collection_name=collection), identity)
                except IngestError as exc:
                    raise SearchError(str(exc), status_code=409, error_type="embedding_identity_mismatch") from None
            if ensure_indexes:
                self._ensure_indexes(client, url, collection)
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

    def query_hybrid(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        vector: list[float],
        text: str,
        limit: int,
        offset: int,
        filters: list[PayloadFilter],
        score_threshold: float | None,
        using: str | None,
        weights: list[float] | None,
        ensure_indexes: bool = True,
        identity: dict | None = None,
    ) -> list[ScoredHit]:
        client = self._open(url, api_key)
        try:
            if identity is not None:
                try:
                    validate_collection_identity(client.get_collection(collection_name=collection), identity)
                except IngestError as exc:
                    raise SearchError(str(exc), status_code=409, error_type="embedding_identity_mismatch") from None
            if ensure_indexes:
                self._ensure_indexes(client, url, collection)
            arguments = hybrid_query_arguments(
                vector=vector,
                text=text,
                using=using,
                filters=filters,
                limit=limit,
                offset=offset,
                weights=weights,
            )
            arguments["score_threshold"] = score_threshold
            response = client.query_points(collection_name=collection, **arguments)
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
            raise SearchError(message, status_code=502, error_type="qdrant_error") from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()
