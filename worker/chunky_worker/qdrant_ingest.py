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


def _quantization_config(name: str, *, on_disk: bool):
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
    if key == "scalar":
        return ScalarQuantization(
            scalar=ScalarQuantizationConfig(type="int8", always_ram=always_ram)
        )
    if key == "binary":
        return BinaryQuantization(binary=BinaryQuantizationConfig(always_ram=always_ram))
    raise IngestError(f"Unsupported Qdrant quantization: {name}")


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
    "doc_title",
    "authors",
    "content_type",
    "language",
    "doi",
    "picture_class",
)
TEXT_PAYLOAD_INDEXES = (
    "picture_description",
    "table_markdown",
    "embedding_text",
)


def stored_chunk_text(chunk: dict[str, Any]) -> str:
    """Payload text matches the string that was embedded."""
    serialized = chunk.get("embedding_text")
    if isinstance(serialized, str) and serialized != "":
        return serialized
    return str(chunk.get("text") or "")


def ensure_payload_indexes(client, collection: str) -> None:
    from qdrant_client.models import PayloadSchemaType

    specs = [(name, PayloadSchemaType.KEYWORD) for name in KEYWORD_PAYLOAD_INDEXES]
    specs += [(name, PayloadSchemaType.TEXT) for name in TEXT_PAYLOAD_INDEXES]
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
    payload: dict[str, Any] = {
        "text": stored_chunk_text(chunk),
        "source": chunk.get("source") or source,
    }
    embedding_text = chunk.get("embedding_text")
    if isinstance(embedding_text, str) and embedding_text != "":
        payload["embedding_text"] = embedding_text
    put_visual = (
        ("picture_description", chunk.get("picture_description")),
        ("picture_class", chunk.get("picture_class")),
        ("table_markdown", chunk.get("table_markdown")),
    )
    page = chunk.get("page")
    if settings.metadata_include_page and page is not None:
        payload["page"] = int(page)

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
    put_string(settings.metadata_include_content_type, "content_type", chunk.get("content_type"))
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
    return payload


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
            from qdrant_client.models import (
                Distance,
                Modifier,
                PointStruct,
                SparseVector,
                SparseVectorParams,
                VectorParams,
            )
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
                compression = _quantization_config(quantization, on_disk=on_disk)
                dense = VectorParams(
                    size=vector_size,
                    distance=distance_enum,
                    on_disk=True if on_disk else None,
                )
                if hybrid:
                    client.create_collection(
                        collection_name=collection,
                        vectors_config={"dense": dense},
                        sparse_vectors_config={"sparse": SparseVectorParams(modifier=Modifier.IDF)},
                        on_disk_payload=on_disk,
                        quantization_config=compression,
                    )
                else:
                    client.create_collection(
                        collection_name=collection,
                        vectors_config=dense,
                        on_disk_payload=True if on_disk else None,
                        quantization_config=compression,
                    )
            ensure_payload_indexes(client, collection)

            sparse_rows = sparse_vectors([point.payload.get("text") or "" for point in points]) if hybrid else None
            total = len(points)
            written = 0
            step = batch_size
            for start in range(0, total, step):
                batch = points[start : start + step]
                structs = []
                for offset, point in enumerate(batch):
                    if sparse_rows is None:
                        vector: Any = point.vector
                    else:
                        indices, values = sparse_rows[start + offset]
                        vector = {
                            "dense": point.vector,
                            "sparse": SparseVector(indices=indices, values=values),
                        }
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
