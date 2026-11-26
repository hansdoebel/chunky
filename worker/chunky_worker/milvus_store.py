"""Milvus adapter over the v2 HTTP API. Hybrid search stays on Qdrant and Weaviate."""

from __future__ import annotations

import json
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
    redact_text,
    register_vector_store,
    vector_text,
)

_METRICS = {"cosine": "COSINE", "euclid": "L2", "dot": "IP"}
_FROM_METRIC = {value: key for key, value in _METRICS.items()}
_OUTPUT = ["id", "body", "text", *SCALAR_KEYS]


def _floats(vector: list[float]) -> list[float]:
    vector_text(vector)
    return [float(value) for value in vector]


def _literal(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return format(value, ".8g")
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


def _like(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "\\%").replace("_", "\\_")


def _atom(atom: Any) -> str:
    if "." in atom.key or not atom.key:
        raise StoreError(f"Invalid filter key: {atom.key!r}", "invalid_filter", 400)
    key = atom.key
    if atom.op == "eq":
        return f"{key} == {_literal(atom.value)}"
    if atom.op == "text":
        return f'{key} like "%{_like(str(atom.value))}%"'
    if atom.op == "any":
        return "(" + " or ".join(f"{key} == {_literal(item)}" for item in atom.value) + ")"
    if atom.op == "empty":
        return f'({key} == "" or {key} is null)'
    if atom.op == "range":
        parts = []
        for operator, bound in ((">", atom.gt), (">=", atom.gte), ("<", atom.lt), ("<=", atom.lte)):
            if bound is not None:
                parts.append(f"{key} {operator} {format(float(bound), '.8g')}")
        return "(" + " and ".join(parts) + ")"
    raise StoreError(f"Unsupported filter {atom.op}", "invalid_filter", 400)


def milvus_filter(filters: list[Any]) -> str:
    compiled = compile_filters(filters)
    if compiled is None:
        return ""
    parts = [_atom(atom) for atom in compiled.must]
    parts += [f"not ({_atom(atom)})" for atom in compiled.must_not]
    if compiled.should:
        parts.append("(" + " or ".join(_atom(atom) for atom in compiled.should) + ")")
    return " and ".join(parts)


def _missing(message: str) -> bool:
    text = message.lower()
    return any(token in text for token in ("not exist", "not found", "can't find", "cannot find", "collection not"))


def _data_rows(body: Any) -> list[dict[str, Any]]:
    data = body.get("data") if isinstance(body, dict) else None
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]
    if isinstance(data, dict):
        for key in ("results", "entities", "data"):
            rows = data.get(key)
            if isinstance(rows, list):
                return [row for row in rows if isinstance(row, dict)]
    return []


def _score(distance: float, metric: str) -> float:
    if metric == "L2":
        return 1.0 / (1.0 + distance)
    return distance


def _parse_collection(data: dict[str, Any]) -> tuple[int, str] | None:
    description = str(data.get("description") or "")
    if description.startswith("chunky:"):
        parts = description.split(":")
        if len(parts) == 3 and parts[1].isdigit() and parts[2] in _FROM_METRIC:
            return int(parts[1]), _FROM_METRIC[parts[2]]
    fields = data.get("fields") or (data.get("schema") or {}).get("fields") or []
    dimension = data.get("dimension") or data.get("dimensions")
    for field in fields if isinstance(fields, list) else []:
        if not isinstance(field, dict):
            continue
        params = field.get("params") or field.get("elementTypeParams") or {}
        if isinstance(params, dict) and params.get("dim"):
            dimension = params["dim"]
    metric = str(data.get("metricType") or data.get("metric_type") or "COSINE")
    if isinstance(dimension, int) and metric in _FROM_METRIC:
        return dimension, _FROM_METRIC[metric]
    return None


class MilvusStore:
    kind = "milvus"
    supports_hybrid = False

    def __init__(self, transport: HTTPTransport | None = None, **kwargs: Any) -> None:
        self.transport = transport or HttpxTransport()

    def _post(self, endpoint: StoreEndpoint, path: str, body: dict[str, Any]) -> Any:
        payload = http_json(
            self.transport,
            "POST",
            join_url(endpoint.url, path),
            headers=http_headers(endpoint.api_key),
            json_body=body,
            endpoint=endpoint,
        )
        if isinstance(payload, dict) and payload.get("code") not in (None, 0):
            message = str(payload.get("message") or payload.get("msg") or payload)
            if _missing(message):
                return None
            raise StoreError(redact_text(message, endpoint.api_key)[:400], "store_error", 502)
        return payload

    def _info(self, endpoint: StoreEndpoint) -> tuple[int, str] | None:
        body = self._post(endpoint, "v2/vectordb/collections/describe", {"collectionName": collection_name(endpoint.collection)})
        if body is None:
            return None
        data = body.get("data") if isinstance(body, dict) else None
        if not isinstance(data, dict):
            raise StoreError("Milvus describe response had no collection data", "store_error", 502)
        parsed = _parse_collection(data)
        if parsed is None:
            raise StoreError(
                f"Collection {endpoint.collection!r} has no Chunky vector description",
                "embedding_identity_mismatch",
                409,
            )
        return parsed

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        parsed = self._info(endpoint)
        if parsed is None:
            return None
        return CollectionStats(parsed[0], parsed[1])

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
        if distance not in _METRICS:
            raise StoreError(f"Unsupported distance: {distance}", "invalid_distance", 400)
        if batch_size < 1:
            raise StoreError("batch size must be at least 1", "invalid_batch", 400)
        name = collection_name(endpoint.collection)
        existing = self._info(endpoint)
        metric = _METRICS[distance]
        if existing is None:
            self._post(
                endpoint,
                "v2/vectordb/collections/create",
                {
                    "collectionName": name,
                    "dimension": vector_size,
                    "metricType": metric,
                    "idType": "VarChar",
                    "primaryFieldName": "id",
                    "vectorFieldName": "vector",
                    "description": f"chunky:{vector_size}:{metric}",
                },
            )
        else:
            found, stored = existing
            if found != vector_size:
                raise DimensionMismatch(
                    f"Collection {name!r} has vector size {found}, "
                    f"but the embedding model produced size {vector_size}. Refusing to upsert."
                )
            if stored != distance:
                raise StoreError(f"Collection {name!r} uses distance {stored}", "invalid_distance", 409)
        written = 0
        total = len(points)
        for start in range(0, total, batch_size):
            batch = points[start : start + batch_size]
            rows = []
            for point in batch:
                if len(point.vector) != vector_size:
                    raise StoreError("Embedding vectors have inconsistent dimensions", "invalid_vector", 400)
                if len(point.id) > 256:
                    raise StoreError("Milvus ids must be 256 characters or fewer", "invalid_id", 400)
                row = {
                    "id": point.id,
                    "vector": _floats(point.vector),
                    "body": json.dumps(point.payload, default=str),
                    "text": point_text(point.payload),
                }
                for key in SCALAR_KEYS:
                    value = point.payload.get(key)
                    if isinstance(value, str) and value:
                        row[key] = value
                    elif isinstance(value, bool) or isinstance(value, int):
                        row[key] = value
                rows.append(row)
            self._post(endpoint, "v2/vectordb/entities/upsert", {"collectionName": name, "data": rows})
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
            raise StoreError("Milvus supports dense search.", "unsupported_search_mode", 400)
        name = collection_name(endpoint.collection)
        existing = self._info(endpoint)
        if existing is None:
            raise StoreError(f"Collection {name!r} was not found", "not_found", 404)
        found, distance = existing
        if found != len(vector):
            raise DimensionMismatch(
                f"Collection {name!r} has vector size {found}, "
                f"but the query vector has size {len(vector)}. Refusing to search."
            )
        metric = _METRICS[distance]
        body: dict[str, Any] = {
            "collectionName": name,
            "data": [_floats(vector)],
            "annsField": "vector",
            "limit": int(limit),
            "offset": int(offset),
            "outputFields": _OUTPUT,
            "searchParams": {"metricType": metric},
        }
        expression = milvus_filter(filters)
        if expression:
            body["filter"] = expression
        payload = self._post(endpoint, "v2/vectordb/entities/search", body)
        hits = []
        for row in _data_rows(payload):
            distance_value = row.get("distance", row.get("score", 0))
            entity = row.get("entity") if isinstance(row.get("entity"), dict) else row
            hits.append(StoreHit(str(entity.get("id") or row.get("id")), _score(float(distance_value), metric), payload_from_record(entity)))
        return apply_threshold(hits, score_threshold)

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]:
        body = self._post(endpoint, "v2/vectordb/collections/list", {})
        data = body.get("data") if isinstance(body, dict) else None
        if isinstance(data, list):
            return [str(item.get("name") if isinstance(item, dict) else item) for item in data]
        if isinstance(data, dict) and isinstance(data.get("collections"), list):
            return [str(item) for item in data["collections"]]
        return []

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]:
        name = collection_name(endpoint.collection)
        existing = self._info(endpoint)
        if existing is None:
            raise StoreError(f"Collection {name!r} was not found", "not_found", 404)
        body = self._post(
            endpoint,
            "v2/vectordb/entities/query",
            {
                "collectionName": name,
                "filter": 'id != ""',
                "limit": int(limit),
                "offset": int(offset),
                "outputFields": ["id", "body"],
            },
        )
        rows = _data_rows(body)
        return {
            "points": [{"id": str(row.get("id")), "payload": payload_from_record(row)} for row in rows],
            "next_offset": str(offset + limit) if len(rows) == limit else None,
            "points_count": None,
            "dimensions": existing[0],
            "distance": existing[1],
        }


def open_milvus(**kwargs: Any) -> MilvusStore:
    return MilvusStore(transport=kwargs.get("transport"))


register_vector_store("milvus", open_milvus)
