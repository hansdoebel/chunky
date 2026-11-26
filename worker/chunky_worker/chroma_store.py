"""Chroma adapter over the v2 HTTP API. Hybrid search stays on Qdrant, pgvector, and Weaviate."""

from __future__ import annotations

from typing import Any

from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.vector_store import (
    SCALAR_KEYS,
    CollectionStats,
    HTTPTransport,
    HttpxTransport,
    StoreEndpoint,
    StoreError,
    StoreHit,
    StorePoint,
    apply_threshold,
    collection_name,
    compile_filters,
    http_headers,
    http_json,
    join_url,
    payload_from_record,
    point_text,
    record_fields,
    register_vector_store,
    vector_text,
)

_ROOT = "api/v2/tenants/default_tenant/databases/default_database"
_DISTANCES = {"cosine", "l2", "ip"}
_FROM_DISTANCE = {"cosine": "cosine", "euclid": "l2", "dot": "ip"}
_TO_DISTANCE = {value: key for key, value in _FROM_DISTANCE.items()}


def _floats(vector: list[float]) -> list[float]:
    vector_text(vector)
    return [float(value) for value in vector]


def _where_atom(atom: Any, *, negate: bool = False) -> dict[str, Any]:
    if atom.op == "eq":
        return {atom.key: {"$ne" if negate else "$eq": atom.value}}
    if negate:
        raise StoreError(f"Chroma cannot negate a {atom.op} filter", "invalid_filter", 400)
    if atom.op == "text":
        return {atom.key: {"$contains": str(atom.value)}}
    if atom.op == "any":
        return {"$or": [{atom.key: {"$eq": item}} for item in atom.value]}
    if atom.op == "empty":
        return {atom.key: {"$eq": ""}}
    if atom.op == "range":
        spec: dict[str, float] = {}
        if atom.gt is not None:
            spec["$gt"] = float(atom.gt)
        if atom.gte is not None:
            spec["$gte"] = float(atom.gte)
        if atom.lt is not None:
            spec["$lt"] = float(atom.lt)
        if atom.lte is not None:
            spec["$lte"] = float(atom.lte)
        return {atom.key: spec}
    raise StoreError(f"Unsupported filter {atom.op}", "invalid_filter", 400)


def chroma_where(filters: list[Any]) -> dict[str, Any] | None:
    compiled = compile_filters(filters)
    if compiled is None:
        return None
    clauses = [_where_atom(atom) for atom in compiled.must]
    clauses += [_where_atom(atom, negate=True) for atom in compiled.must_not]
    if compiled.should:
        clauses.append({"$or": [_where_atom(atom) for atom in compiled.should]})
    if not clauses:
        return None
    if len(clauses) == 1:
        return clauses[0]
    return {"$and": clauses}


def _score(distance: float, space: str) -> float:
    if space == "l2":
        return 1.0 / (1.0 + distance)
    if space == "ip":
        return -distance
    return 1.0 - distance


def _metadata(point: StorePoint) -> dict[str, Any]:
    fields = record_fields(point)
    metadata: dict[str, Any] = {"body": fields["body"], "chunky_id": point.id}
    text = point_text(point.payload)
    if text:
        metadata["text"] = text
    for key in (*SCALAR_KEYS, "headings"):
        value = fields.get(key)
        if isinstance(value, str) and value:
            metadata[key] = value
        elif isinstance(value, bool) or (isinstance(value, int) and not isinstance(value, bool)):
            metadata[key] = value
    return metadata


def _collections(body: Any) -> list[dict[str, Any]]:
    rows = body if isinstance(body, list) else []
    if isinstance(body, dict):
        rows = body.get("collections") or body.get("data") or []
    return [row for row in rows if isinstance(row, dict)]


class ChromaStore:
    kind = "chroma"
    supports_hybrid = False

    def __init__(self, transport: HTTPTransport | None = None, **kwargs: Any) -> None:
        self.transport = transport or HttpxTransport()

    def _request(self, endpoint: StoreEndpoint, method: str, path: str, body: Any | None = None) -> Any:
        return http_json(
            self.transport,
            method,
            join_url(endpoint.url, path),
            headers=http_headers(endpoint.api_key, chroma=True),
            json_body=body,
            endpoint=endpoint,
        )

    def _collection(self, endpoint: StoreEndpoint) -> dict[str, Any] | None:
        name = collection_name(endpoint.collection)
        try:
            rows = _collections(self._request(endpoint, "GET", f"{_ROOT}/collections"))
        except StoreError as exc:
            if exc.status_code == 404:
                return None
            raise
        for row in rows:
            if row.get("name") == name:
                return row
        return None

    def _stats(self, row: dict[str, Any], name: str) -> CollectionStats:
        metadata = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
        dimension = metadata.get("dimension")
        space = str(metadata.get("distance") or "")
        if not isinstance(dimension, int) or isinstance(dimension, bool) or space not in _DISTANCES:
            raise StoreError(
                f"Collection {name!r} has no Chunky Chroma metadata",
                "embedding_identity_mismatch",
                409,
            )
        return CollectionStats(dimension, _TO_DISTANCE[space])

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        row = self._collection(endpoint)
        if row is None:
            return None
        return self._stats(row, endpoint.collection)

    def upsert(
        self,
        endpoint: StoreEndpoint,
        points: list[StorePoint],
        *,
        vector_size: int,
        distance: str,
        batch_size: int,
        on_progress=None,
    ) -> int:
        if type(vector_size) is not int or vector_size < 1:
            raise StoreError("vector size must be a positive integer", "invalid_vector", 400)
        if distance not in _FROM_DISTANCE:
            raise StoreError(f"Unsupported distance: {distance}", "invalid_distance", 400)
        if batch_size < 1:
            raise StoreError("batch size must be at least 1", "invalid_batch", 400)
        name = collection_name(endpoint.collection)
        space = _FROM_DISTANCE[distance]
        existing = self._collection(endpoint)
        if existing is None:
            created = self._request(
                endpoint,
                "POST",
                f"{_ROOT}/collections",
                {"name": name, "get_or_create": True, "metadata": {"dimension": vector_size, "distance": space}},
            )
            if not isinstance(created, dict) or not created.get("id"):
                raise StoreError("Chroma did not return a collection id", "store_error", 502)
            existing = created
        else:
            stats = self._stats(existing, name)
            if stats.vector_size != vector_size:
                raise DimensionMismatch(
                    f"Collection {name!r} has vector size {stats.vector_size}, "
                    f"but the embedding model produced size {vector_size}. Refusing to upsert."
                )
            if stats.distance != distance:
                raise StoreError(f"Collection {name!r} uses distance {stats.distance}", "invalid_distance", 409)
        collection_id = str(existing["id"])
        written = 0
        total = len(points)
        for start in range(0, total, batch_size):
            batch = points[start : start + batch_size]
            ids = []
            embeddings = []
            metadatas = []
            documents = []
            for point in batch:
                if len(point.vector) != vector_size:
                    raise StoreError("Embedding vectors have inconsistent dimensions", "invalid_vector", 400)
                ids.append(point.id)
                embeddings.append(_floats(point.vector))
                metadatas.append(_metadata(point))
                documents.append(point_text(point.payload))
            self._request(
                endpoint,
                "POST",
                f"{_ROOT}/collections/{collection_id}/upsert",
                {"ids": ids, "embeddings": embeddings, "metadatas": metadatas, "documents": documents},
            )
            written += len(batch)
            if on_progress:
                on_progress(written, total)
        return written

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
        if mode != "dense":
            raise StoreError("Chroma supports dense search.", "unsupported_search_mode", 400)
        row = self._collection(endpoint)
        if row is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        stats = self._stats(row, endpoint.collection)
        if stats.vector_size != len(vector):
            raise DimensionMismatch(
                f"Collection {endpoint.collection!r} has vector size {stats.vector_size}, "
                f"but the query vector has size {len(vector)}. Refusing to search."
            )
        space = _FROM_DISTANCE[stats.distance]
        body: dict[str, Any] = {
            "query_embeddings": [_floats(vector)],
            "n_results": int(limit),
            "offset": int(offset),
            "include": ["metadatas", "documents", "distances"],
        }
        where = chroma_where(filters)
        if where is not None:
            body["where"] = where
        payload = self._request(endpoint, "POST", f"{_ROOT}/collections/{row['id']}/query", body)
        ids = (payload.get("ids") or [[]])[0] if isinstance(payload, dict) else []
        distances = (payload.get("distances") or [[]])[0] if isinstance(payload, dict) else []
        metadatas = (payload.get("metadatas") or [[]])[0] if isinstance(payload, dict) else []
        hits = []
        for index, ident in enumerate(ids):
            metadata = metadatas[index] if index < len(metadatas) and isinstance(metadatas[index], dict) else {}
            distance = float(distances[index]) if index < len(distances) else 0.0
            hits.append(StoreHit(str(metadata.get("chunky_id") or ident), _score(distance, space), payload_from_record(metadata)))
        return apply_threshold(hits, score_threshold)

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]:
        names = []
        for row in _collections(self._request(endpoint, "GET", f"{_ROOT}/collections")):
            metadata = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
            if metadata.get("distance") in _DISTANCES and isinstance(metadata.get("dimension"), int):
                names.append(str(row.get("name")))
        return names

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]:
        row = self._collection(endpoint)
        if row is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        stats = self._stats(row, endpoint.collection)
        payload = self._request(
            endpoint,
            "POST",
            f"{_ROOT}/collections/{row['id']}/get",
            {"limit": int(limit), "offset": int(offset), "include": ["metadatas", "documents"]},
        )
        ids = payload.get("ids") if isinstance(payload, dict) else []
        metadatas = payload.get("metadatas") if isinstance(payload, dict) else []
        if not isinstance(ids, list):
            ids = []
        points = []
        for index, ident in enumerate(ids):
            metadata = metadatas[index] if isinstance(metadatas, list) and index < len(metadatas) and isinstance(metadatas[index], dict) else {}
            points.append({"id": str(metadata.get("chunky_id") or ident), "payload": payload_from_record(metadata)})
        counted = self._request(endpoint, "GET", f"{_ROOT}/collections/{row['id']}/count")
        total = counted.get("count") if isinstance(counted, dict) else counted if isinstance(counted, int) else None
        return {
            "points": points,
            "next_offset": str(offset + limit) if len(points) == limit else None,
            "points_count": int(total) if isinstance(total, int) else None,
            "dimensions": stats.vector_size,
            "distance": stats.distance,
        }


def open_chroma(**kwargs: Any) -> ChromaStore:
    return ChromaStore(transport=kwargs.get("transport"))


register_vector_store("chroma", open_chroma)
