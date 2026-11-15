"""Qdrant Cloud upserts. Credentials stay in memory for the call and are never logged.

Payload field names match ``ChunkPoint.toQdrantPoint`` in the Mac app
(``Chunky/Sources/Models/QdrantModels.swift``) plus the metadata strings
``DocumentProcessor.buildPoints`` writes.
"""

from __future__ import annotations

import hashlib
import math
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Protocol

from chunky_worker.models import IngestTarget, JobMode, JobSettings

class IngestError(Exception):
    def __init__(self, message: str, error_type: str = "ingest_error") -> None:
        super().__init__(message)
        self.error_type = error_type

class DimensionMismatch(IngestError):
    def __init__(self, message: str) -> None:
        super().__init__(message, error_type="dimension_mismatch")

@dataclass
class PreparedPoint:
    id: str
    vector: list[float]
    payload: dict[str, Any]

class QdrantIngestor(Protocol):
    def collection_vector_size(self, *, url: str, api_key: str, collection: str) -> int | None:
        """Return the existing dense vector size, or None when the collection is missing."""

    def upsert_cloud(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        points: list[PreparedPoint],
        vector_size: int,
        distance: str,
        batch_size: int,
        hybrid: bool = False,
        quantization: str = "none",
        on_disk: bool = False,
        vector_memory: str = "",
        hnsw_memory: str = "",
        quantization_memory: str = "",
        payload_memory: str = "",
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int:
        """Create the collection when missing and upsert. Returns the point count."""

def redact(text: str, secret: str | None) -> str:
    if not secret or secret not in text:
        return text
    return text.replace(secret, "[redacted]")

def normalize_distance(value: str) -> str:
    key = value.strip().lower()
    aliases = {
        "cosine": "cosine",
        "dot": "dot",
        "dotproduct": "dot",
        "euclid": "euclid",
        "euclidean": "euclid",
    }
    if key not in aliases:
        raise IngestError(f"Unsupported Qdrant distance: {value}")
    return aliases[key]

def sparse_vectors(texts: list[str]) -> list[tuple[list[int], list[float]]]:
    tokenized = [_tokenize(text) for text in texts]
    document_frequency: dict[str, int] = {}
    for tokens in tokenized:
        for token in set(tokens):
            document_frequency[token] = document_frequency.get(token, 0) + 1
    vocabulary = {token: index for index, token in enumerate(sorted(document_frequency))}
    count = float(len(texts)) or 1.0
    rows: list[tuple[list[int], list[float]]] = []
    for tokens in tokenized:
        frequencies: dict[str, int] = {}
        for token in tokens:
            frequencies[token] = frequencies.get(token, 0) + 1
        pairs: list[tuple[int, float]] = []
        for token, frequency in frequencies.items():
            index = vocabulary.get(token)
            seen = document_frequency.get(token)
            if index is None or seen is None:
                continue
            score = math.log1p(frequency) * math.log1p(count / float(seen))
            if score > 0:
                pairs.append((index, score))
        pairs.sort()
        rows.append(([index for index, _ in pairs], [score for _, score in pairs]))
    return rows

def _tokenize(text: str) -> list[str]:
    return re.findall(r"[0-9A-Za-z_]{2,}", text.lower())

def _quantization_config(name: str, *, on_disk: bool, memory: str = ""):
    key = (name or "none").strip().lower()
    if key in {"", "none"}:
        return None
    try:
        from qdrant_client.models import (
            BinaryQuantization,
            BinaryQuantizationConfig,
            ScalarQuantization,
            ScalarQuantizationConfig,
        )
    except ImportError as exc:
        raise IngestError("qdrant-client is not installed") from exc
    always_ram = not on_disk
    tier = memory or None
    if key == "scalar":
        return ScalarQuantization(
            scalar=ScalarQuantizationConfig(type="int8", always_ram=always_ram, memory=tier)
        )
    if key == "binary":
        return BinaryQuantization(
            binary=BinaryQuantizationConfig(always_ram=always_ram, memory=tier)
        )
    raise IngestError(f"Unsupported Qdrant quantization: {name}")


def _hnsw_config(memory: str):
    if not memory:
        return None
    from qdrant_client.models import HnswConfigDiff

    return HnswConfigDiff(memory=memory)


def _payload_config(memory: str):
    if not memory:
        return None
    from qdrant_client.models import PayloadStorageParams

    return PayloadStorageParams(memory=memory)


def _apply_memory_tiers(
    client,
    collection: str,
    *,
    hybrid: bool,
    vector_memory: str,
    hnsw_memory: str,
    quantization: str,
    quantization_memory: str,
    payload_memory: str,
    on_disk: bool,
) -> None:
    if not any((vector_memory, hnsw_memory, quantization_memory, payload_memory)):
        return
    from qdrant_client.models import CollectionParamsDiff, VectorParamsDiff

    name = "dense" if hybrid else ""
    vectors = None
    if vector_memory:
        vectors = {name: VectorParamsDiff(memory=vector_memory)}
    compression = _quantization_config(quantization, on_disk=on_disk, memory=quantization_memory)
    params = None
    if payload_memory:
        params = CollectionParamsDiff(payload=_payload_config(payload_memory))
    client.update_collection(
        collection_name=collection,
        vectors_config=vectors,
        hnsw_config=_hnsw_config(hnsw_memory),
        quantization_config=compression,
        collection_params=params,
    )


def content_hash(text: str, model: str) -> str:
    """Same SHA-256 as ``DocumentProcessor.contentHash`` (text + '|' + model)."""
    digest = hashlib.sha256(f"{text}|{model}".encode("utf-8")).hexdigest()
    return digest

def build_points(
    chunks: list[dict[str, Any]],
    vectors: list[list[float]],
    *,
    source: str,
    settings: JobSettings,
    embedding_model: str,
    doc_title: str | None = None,
    authors: Any = None,
    language: str | None = None,
    year: int | None = None,
    ingested_at: str | None = None,
) -> list[PreparedPoint]:
    if len(chunks) != len(vectors):
        raise IngestError(f"Chunk count {len(chunks)} does not match vector count {len(vectors)}")
    if not vectors:
        raise IngestError("No vectors to ingest")
    size = len(vectors[0])
    if any(len(vector) != size for vector in vectors):
        raise IngestError("Embedding vectors have inconsistent dimensions")

    stamp = ingested_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    points: list[PreparedPoint] = []
    for chunk, vector in zip(chunks, vectors):
        payload = _payload(
            chunk,
            source=source,
            settings=settings,
            embedding_model=embedding_model,
            doc_title=doc_title,
            authors=authors,
            language=language,
            year=year,
            ingested_at=stamp,
        )
        point_id = str(chunk.get("id") or uuid.uuid4())
        points.append(PreparedPoint(id=point_id, vector=list(vector), payload=payload))
    return points

KEYWORD_PAYLOAD_INDEXES = (
    "source",
    "content_type",
    "content_types",
    "language",
    "doi",
    "picture_class",
    "record_type",
)
INTEGER_PAYLOAD_INDEXES = (
    "page",
    "page_end",
    "year",
)
TEXT_PAYLOAD_INDEXES = (
    "doc_title",
    "authors",
    "headings",
    "picture_description",
    "table_markdown",
    "embedding_text",
)

def stored_chunk_text(chunk: dict[str, Any]) -> str:
    serialized = chunk.get("embedding_text")
    if isinstance(serialized, str) and serialized != "":
        return serialized
    return str(chunk.get("text") or "")

BM25_TEXT_FIELD = "embedding_text"

def ensure_bm25_text_index(client, collection: str, field_name: str = BM25_TEXT_FIELD) -> None:
    from qdrant_client.models import TextIndexParams, TextIndexType, TextScoringParams, TextScoringType

    try:
        client.create_payload_index(
            collection_name=collection,
            field_name=field_name,
            field_schema=TextIndexParams(
                type=TextIndexType.TEXT,
                scoring=TextScoringParams(type=TextScoringType.BM25),
            ),
        )
    except Exception as exc:
        message = str(exc).lower()
        if "already exists" in message or "already_exists" in message:
            return
        raise

def ensure_payload_indexes(client, collection: str) -> None:
    from qdrant_client.models import PayloadSchemaType

    specs = [(name, PayloadSchemaType.KEYWORD) for name in KEYWORD_PAYLOAD_INDEXES]
    specs += [(name, PayloadSchemaType.TEXT) for name in TEXT_PAYLOAD_INDEXES]
    specs += [(name, PayloadSchemaType.INTEGER) for name in INTEGER_PAYLOAD_INDEXES]
    for field_name, schema in specs:
        try:
            client.create_payload_index(
                collection_name=collection,
                field_name=field_name,
                field_schema=schema,
            )
        except Exception as exc:
            message = str(exc).lower()
            if "already exists" in message or "already_exists" in message:
                continue
            raise

def _chunk_elements(chunk: dict[str, Any]) -> tuple[str, list[str]] | None:
    import sys
    from pathlib import Path

    scripts = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    from element_types import classify

    labels = chunk.get("content_types")
    if isinstance(labels, str):
        labels = [labels]
    elif not isinstance(labels, list):
        labels = []
    return classify([str(item) for item in labels], None if chunk.get("content_type") is None else str(chunk.get("content_type")))


def _payload(
    chunk: dict[str, Any],
    *,
    source: str,
    settings: JobSettings,
    embedding_model: str,
    doc_title: str | None,
    authors: Any,
    language: str | None,
    year: int | None,
    ingested_at: str,
) -> dict[str, Any]:
    embedded = stored_chunk_text(chunk)
    citation = chunk.get("text") if chunk.get("context_prefix") else embedded
    payload: dict[str, Any] = {
        "text": str(citation or ""),
        "source": chunk.get("source") or source,
    }
    source_path = (settings.source_path or "").strip()
    if source_path:
        payload["source_path"] = source_path
    if embedded:
        payload["embedding_text"] = embedded
    put_visual = (
        ("picture_description", chunk.get("picture_description")),
        ("picture_class", chunk.get("picture_class")),
        ("table_markdown", chunk.get("table_markdown")),
    )
    if settings.metadata_include_page:
        page = chunk.get("page")
        if page is not None:
            payload["page"] = int(page)
        page_end = chunk.get("page_end")
        if page_end is not None:
            payload["page_end"] = int(page_end)
        pages = chunk.get("pages")
        if isinstance(pages, list) and pages:
            payload["pages"] = [int(item) for item in pages]
        boxes = chunk.get("bboxes")
        if isinstance(boxes, list) and boxes:
            payload["bboxes"] = boxes
        labels = chunk.get("page_labels")
        if isinstance(labels, list) and labels:
            payload["page_labels"] = [str(item) for item in labels]
        printed = chunk.get("printed_page")
        if isinstance(printed, str) and printed:
            payload["printed_page"] = printed

    resolved_year = chunk.get("year") if chunk.get("year") is not None else year
    if settings.metadata_include_year and resolved_year is not None:
        payload["year"] = int(resolved_year)

    headings = chunk.get("headings") or []
    if settings.metadata_include_headings and headings:
        payload["headings"] = [str(item) for item in headings]

    def put_string(flag: bool, key: str, value: Any) -> None:
        if flag and value is not None and value != "":
            payload[key] = value if isinstance(value, str) else str(value)

    if settings.metadata_include_chunk_index and chunk.get("chunk_index") is not None:
        payload["chunk_index"] = str(chunk["chunk_index"])
    raw_type = chunk.get("content_type")
    if str(raw_type or "").strip().lower() == "document":
        put_string(settings.metadata_include_content_type, "content_type", raw_type)
    else:
        classified = _chunk_elements(chunk)
        if classified and settings.metadata_include_content_type:
            payload["content_type"] = classified[0]
            payload["content_types"] = classified[1]
    put_string(True, "formula_latex", chunk.get("formula_latex"))
    for key, value in put_visual:
        put_string(True, key, value)
    put_string(settings.metadata_include_section, "section", chunk.get("section"))
    put_string(
        settings.metadata_include_doc_title,
        "doc_title",
        chunk.get("doc_title") or doc_title,
    )
    if settings.metadata_include_authors:
        author_value = chunk.get("authors")
        if author_value is None:
            author_value = authors
        if isinstance(author_value, list):
            author_value = "; ".join(str(item) for item in author_value if item)
        put_string(True, "authors", author_value)
    put_string(settings.metadata_include_doi, "doi", chunk.get("doi"))
    put_string(True, "venue", chunk.get("venue"))
    put_string(True, "abstract", chunk.get("abstract"))
    put_string(True, "metadata_source", chunk.get("metadata_source"))
    cited = chunk.get("cited_references")
    if isinstance(cited, list) and cited:
        payload["cited_references"] = cited
    references = chunk.get("references")
    if isinstance(references, list) and references:
        payload["references"] = references
    put_string(settings.metadata_include_document_id, "document_id", chunk.get("document_id"))
    put_string(settings.metadata_include_url, "url", chunk.get("url"))
    put_string(
        settings.metadata_include_language,
        "language",
        chunk.get("language") or language,
    )
    if settings.metadata_include_timestamp:
        payload["ingested_at"] = ingested_at
    if settings.metadata_include_content_hash:
        embed_text = chunk.get("embedding_text") or chunk.get("text") or ""
        payload["content_hash"] = content_hash(str(embed_text), embedding_model)
    if settings.bibliography_title and settings.metadata_include_doc_title:
        payload["doc_title"] = settings.bibliography_title
    if settings.bibliography_authors and settings.metadata_include_authors:
        payload["authors"] = "; ".join(settings.bibliography_authors)
    if settings.bibliography_year is not None and settings.metadata_include_year:
        payload["year"] = int(settings.bibliography_year)
    if settings.bibliography_doi and settings.metadata_include_doi:
        payload["doi"] = settings.bibliography_doi
    if settings.bibliography_venue:
        payload["venue"] = settings.bibliography_venue
    if settings.bibliography_abstract:
        payload["abstract"] = settings.bibliography_abstract
    if settings.bibliography_cite_key:
        payload["cite_key"] = settings.bibliography_cite_key
    if settings.bibliography_source:
        payload["metadata_source"] = settings.bibliography_source
    return payload

def dense_vector_name(info: Any) -> str | None:
    config = getattr(info, "config", None)
    params = getattr(config, "params", None)
    vectors = getattr(params, "vectors", None)
    if vectors is None and isinstance(info, dict):
        vectors = info.get("config", {}).get("params", {}).get("vectors")
    if not isinstance(vectors, dict):
        return None
    if "dense" in vectors:
        return "dense"
    if len(vectors) == 1:
        return next(iter(vectors))
    return None

def _collection_vector_size(info: Any) -> int | None:
    config = getattr(info, "config", None)
    params = getattr(config, "params", None)
    vectors = getattr(params, "vectors", None)
    if vectors is None and isinstance(info, dict):
        vectors = info.get("config", {}).get("params", {}).get("vectors")
    if vectors is None:
        return None
    if hasattr(vectors, "size"):
        return int(vectors.size)
    if isinstance(vectors, dict):
        chosen = vectors.get("dense")
        if chosen is None and vectors:
            chosen = next(iter(vectors.values()))
        if chosen is None:
            return None
        if hasattr(chosen, "size"):
            return int(chosen.size)
        if isinstance(chosen, dict) and "size" in chosen:
            return int(chosen["size"])
    return None

class QdrantCloudIngestor:
    """Upserts with ``qdrant_client``. The API key is a function argument only."""

    def collection_vector_size(self, *, url: str, api_key: str, collection: str) -> int | None:
        client = self._client(url, api_key)
        try:
            if not client.collection_exists(collection_name=collection):
                return None
            info = client.get_collection(collection_name=collection)
            return _collection_vector_size(info)
        except Exception as exc:
            message = redact(str(exc), api_key)
            raise IngestError(message) from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

    def _client(self, url: str, api_key: str):
        if not url:
            raise IngestError("qdrant_url is required for qdrant_cloud")
        if not api_key:
            raise IngestError("qdrant_api_key is required for qdrant_cloud")
        try:
            from qdrant_client import QdrantClient
        except ImportError as exc:
            raise IngestError("qdrant-client is not installed") from exc
        return QdrantClient(url=url, api_key=api_key)

    def upsert_cloud(
        self,
        *,
        url: str,
        api_key: str,
        collection: str,
        points: list[PreparedPoint],
        vector_size: int,
        distance: str,
        batch_size: int,
        hybrid: bool = False,
        quantization: str = "none",
        on_disk: bool = False,
        vector_memory: str = "",
        hnsw_memory: str = "",
        quantization_memory: str = "",
        payload_memory: str = "",
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int:
        if not url:
            raise IngestError("qdrant_url is required for qdrant_cloud")
        if not api_key:
            raise IngestError("qdrant_api_key is required for qdrant_cloud")
        if not collection:
            raise IngestError("qdrant_collection is required for qdrant_cloud")
        if batch_size < 1:
            raise IngestError("qdrant_batch_size must be at least 1")

        distance_name = normalize_distance(distance)
        try:
            from qdrant_client.models import Distance, PointStruct, VectorParams
        except ImportError as exc:
            raise IngestError("qdrant-client is not installed") from exc

        distance_enum = {
            "cosine": Distance.COSINE,
            "dot": Distance.DOT,
            "euclid": Distance.EUCLID,
        }[distance_name]

        client = self._client(url, api_key)
        try:
            if client.collection_exists(collection_name=collection):
                info = client.get_collection(collection_name=collection)
                existing = _collection_vector_size(info)
                if existing is not None and existing != vector_size:
                    raise DimensionMismatch(
                        f"Collection {collection!r} has vector size {existing}, "
                        f"but the embedding model produced size {vector_size}. "
                        "Refusing to upsert."
                    )
            else:
                compression = _quantization_config(
                    quantization, on_disk=on_disk, memory=quantization_memory
                )
                dense = VectorParams(
                    size=vector_size,
                    distance=distance_enum,
                    on_disk=True if on_disk else None,
                    memory=vector_memory or None,
                )
                hnsw = _hnsw_config(hnsw_memory)
                payload = _payload_config(payload_memory)
                if hybrid:
                    client.create_collection(
                        collection_name=collection,
                        vectors_config={"dense": dense},
                        on_disk_payload=on_disk,
                        hnsw_config=hnsw,
                        quantization_config=compression,
                        payload=payload,
                    )
                else:
                    client.create_collection(
                        collection_name=collection,
                        vectors_config=dense,
                        on_disk_payload=True if on_disk else None,
                        hnsw_config=hnsw,
                        quantization_config=compression,
                        payload=payload,
                    )
            _apply_memory_tiers(
                client,
                collection,
                hybrid=hybrid,
                vector_memory=vector_memory,
                hnsw_memory=hnsw_memory,
                quantization=quantization,
                quantization_memory=quantization_memory,
                payload_memory=payload_memory,
                on_disk=on_disk,
            )
            ensure_payload_indexes(client, collection)
            if hybrid:
                ensure_bm25_text_index(client, collection)

            total = len(points)
            written = 0
            step = batch_size
            for start in range(0, total, step):
                batch = points[start : start + step]
                structs = []
                for point in batch:
                    vector: Any = {"dense": point.vector} if hybrid else point.vector
                    structs.append(PointStruct(id=point.id, vector=vector, payload=point.payload))
                client.upsert(collection_name=collection, points=structs, wait=True)
                written += len(batch)
                if on_progress:
                    on_progress(written, total)
            return written
        except IngestError:
            raise
        except Exception as exc:
            message = redact(str(exc), api_key)
            raise IngestError(message) from None
        finally:
            close = getattr(client, "close", None)
            if callable(close):
                close()

def needs_embeddings(settings: JobSettings) -> bool:
    if settings.ingest_target in {IngestTarget.QDRANT_CLOUD, IngestTarget.RETURN_VECTORS}:
        return True
    return settings.mode == JobMode.CHUNK_AND_EMBED
