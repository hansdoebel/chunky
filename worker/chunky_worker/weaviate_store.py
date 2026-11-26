"""Weaviate adapter over the HTTP schema, batch, and GraphQL APIs."""

from __future__ import annotations

import json
import uuid
from typing import Any
from urllib.parse import urlencode

from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.vector_store import (
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
    record_fields,
    redact_text,
    register_vector_store,
    vector_text,
)

_TEXT = ("chunky_id", "body", "text", "headings", "source", "doi", "content_type", "record_type", "library_id", "doc_title", "language")
_INTS = ("page", "page_end", "year", "chunk_index")
_ALLOWED = set(_TEXT) | set(_INTS)
_DISTANCE = {"cosine": "cosine", "euclid": "l2-squared", "dot": "dot"}


def weaviate_class(name: str) -> str:
    cleaned = collection_name(name)
    return cleaned[:1].upper() + cleaned[1:]


def _floats(vector: list[float]) -> list[float]:
    vector_text(vector)
    return [float(value) for value in vector]


def _point_uuid(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except ValueError:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "chunky:" + value))


def _graphql_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _graphql_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "valueBoolean: " + ("true" if value else "false")
    if isinstance(value, int):
        return f"valueInt: {value}"
    return "valueText: " + _graphql_string(str(value))


def _graphql_atom(atom: Any) -> str:
    path = "path: [" + _graphql_string(atom.key) + "]"
    if atom.op == "eq":
        return "{operator: Equal, " + path + ", " + _graphql_scalar(atom.value) + "}"
    if atom.op == "text":
        return "{operator: Like, " + path + ", valueText: " + _graphql_string("*" + str(atom.value) + "*") + "}"
    if atom.op == "empty":
        return "{operator: IsNull, " + path + ", valueBoolean: true}"
    if atom.op == "any":
        choices = ["{operator: Equal, " + path + ", " + _graphql_scalar(item) + "}" for item in atom.value]
        return "{operator: Or, operands: [" + ", ".join(choices) + "]}"
    if atom.op == "range":
        pieces = []
        for operator, bound in (("GreaterThan", atom.gt), ("GreaterThanEqual", atom.gte), ("LessThan", atom.lt), ("LessThanEqual", atom.lte)):
            if bound is not None:
                number = int(bound) if float(bound).is_integer() else float(bound)
                value = f"valueInt: {number}" if isinstance(number, int) else f"valueNumber: {number}"
                pieces.append("{operator: " + operator + ", " + path + ", " + value + "}")
        return "{operator: And, operands: [" + ", ".join(pieces) + "]}"
    raise StoreError(f"Unsupported filter {atom.op}", "invalid_filter", 400)


def _graphql_where(filters: list[Any]) -> str:
    compiled = compile_filters(filters)
    if compiled is None:
        return ""
    operands = [_graphql_atom(atom) for atom in compiled.must]
    operands += ["{operator: Not, operands: [" + _graphql_atom(atom) + "]}" for atom in compiled.must_not]
    if compiled.should:
        operands.append("{operator: Or, operands: [" + ", ".join(_graphql_atom(atom) for atom in compiled.should) + "]}")
    if not operands:
        return ""
    if len(operands) == 1:
        return ", where: " + operands[0]
    return ", where: {operator: And, operands: [" + ", ".join(operands) + "]}"


def _alpha(weights: list[float] | None) -> float:
    if not weights:
        return 0.5
    dense, lexical = float(weights[0]), float(weights[1])
    total = dense + lexical
    if total <= 0:
        return 0.5
    return dense / total


def _schema(class_name: str, vector_size: int, distance: str) -> dict[str, Any]:
    properties = [{"name": name, "dataType": ["text"]} for name in _TEXT]
    properties += [{"name": name, "dataType": ["int"]} for name in _INTS]
    return {
        "class": class_name,
        "vectorizer": "none",
        "description": f"chunky:{vector_size}:{distance}",
        "vectorIndexConfig": {"distance": _DISTANCE[distance]},
        "properties": properties,
    }


def _parse_description(description: str) -> tuple[int, str] | None:
    parts = (description or "").split(":")
    if len(parts) != 3 or parts[0] != "chunky" or not parts[1].isdigit() or parts[2] not in _DISTANCE:
        return None
    return int(parts[1]), parts[2]


def _properties(point: StorePoint) -> dict[str, Any]:
    fields = {key: value for key, value in record_fields(point).items() if key in _ALLOWED and value != ""}
    fields["chunky_id"] = point.id
    fields["body"] = record_fields(point)["body"]
    return fields


def _object_hit(row: dict[str, Any]) -> StoreHit:
    props = row.get("properties") if isinstance(row.get("properties"), dict) else row
    additional = row.get("_additional") if isinstance(row.get("_additional"), dict) else {}
    if "score" in additional:
        score = float(additional["score"])
    elif "distance" in additional:
        score = 1.0 - float(additional["distance"])
    else:
        score = 0.0
    identity = props.get("chunky_id") or additional.get("id") or row.get("id") or ""
    return StoreHit(str(identity), score, payload_from_record(props))


class WeaviateStore:
    kind = "weaviate"
    supports_hybrid = True

    def __init__(self, transport: HTTPTransport | None = None, **kwargs: Any) -> None:
        self.transport = transport or HttpxTransport()

    def _send(self, endpoint: StoreEndpoint, method: str, path: str, body: Any | None = None) -> Any:
        return http_json(
            self.transport,
            method,
            join_url(endpoint.url, path),
            headers=http_headers(endpoint.api_key),
            json_body=body,
            endpoint=endpoint,
        )

    def _class_info(self, endpoint: StoreEndpoint, class_name: str) -> dict[str, Any] | None:
        try:
            body = self._send(endpoint, "GET", f"v1/schema/{class_name}")
        except StoreError as exc:
            if exc.status_code == 404:
                return None
            raise
        if not isinstance(body, dict):
            raise StoreError("Weaviate schema response was not an object", "store_error", 502)
        return body

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        class_name = weaviate_class(endpoint.collection)
        info = self._class_info(endpoint, class_name)
        if info is None:
            return None
        parsed = _parse_description(str(info.get("description") or ""))
        if parsed is None:
            raise StoreError(
                f"Collection {endpoint.collection!r} is not a Chunky Weaviate class",
                "embedding_identity_mismatch",
                409,
            )
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
        if distance not in _DISTANCE:
            raise StoreError(f"Unsupported distance: {distance}", "invalid_distance", 400)
        if batch_size < 1:
            raise StoreError("batch size must be at least 1", "invalid_batch", 400)
        class_name = weaviate_class(endpoint.collection)
        info = self._class_info(endpoint, class_name)
        if info is None:
            self._send(endpoint, "POST", "v1/schema", _schema(class_name, vector_size, distance))
        else:
            parsed = _parse_description(str(info.get("description") or ""))
            if parsed is None:
                raise StoreError(
                    f"Collection {endpoint.collection!r} is not a Chunky Weaviate class",
                    "embedding_identity_mismatch",
                    409,
                )
            found, stored = parsed
            if found != vector_size:
                raise DimensionMismatch(
                    f"Collection {endpoint.collection!r} has vector size {found}, "
                    f"but the embedding model produced size {vector_size}. Refusing to upsert."
                )
            if stored != distance:
                raise StoreError(
                    f"Collection {endpoint.collection!r} uses distance {stored}",
                    "invalid_distance",
                    409,
                )
        written = 0
        total = len(points)
        for start in range(0, total, batch_size):
            batch = points[start : start + batch_size]
            objects = []
            for point in batch:
                if len(point.vector) != vector_size:
                    raise StoreError("Embedding vectors have inconsistent dimensions", "invalid_vector", 400)
                objects.append(
                    {
                        "class": class_name,
                        "id": _point_uuid(point.id),
                        "properties": _properties(point),
                        "vector": _floats(point.vector),
                    }
                )
            body = self._send(endpoint, "POST", "v1/batch/objects", {"objects": objects})
            _raise_batch_errors(body, endpoint)
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
        class_name = weaviate_class(endpoint.collection)
        stats = self.describe(endpoint)
        if stats is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        if stats.vector_size != len(vector):
            raise DimensionMismatch(
                f"Collection {endpoint.collection!r} has vector size {stats.vector_size}, "
                f"but the query vector has size {len(vector)}. Refusing to search."
            )
        floats = _floats(vector)
        rendered = "[" + ",".join(format(value, ".8g") for value in floats) + "]"
        where = _graphql_where(filters)
        if mode == "hybrid":
            search = "hybrid: {query: " + _graphql_string(text) + ", vector: " + rendered + ", alpha: " + format(_alpha(weights), ".8g") + "}"
        elif mode == "dense":
            search = "nearVector: {vector: " + rendered + "}"
        else:
            raise StoreError("mode must be dense or hybrid", "invalid_search", 400)
        query = (
            "{ Get { "
            + class_name
            + "("
            + search
            + ", limit: "
            + str(int(limit))
            + ", offset: "
            + str(int(offset))
            + where
            + ") { chunky_id body _additional { id distance score } } } }"
        )
        body = self._send(endpoint, "POST", "v1/graphql", {"query": query})
        if isinstance(body, dict) and body.get("errors"):
            raise StoreError(redact_text(json.dumps(body["errors"])[:400], endpoint.api_key), "store_error", 502)
        rows = (((body or {}).get("data") or {}).get("Get") or {}).get(class_name) or []
        if not isinstance(rows, list):
            raise StoreError("Weaviate query response was not a list", "store_error", 502)
        return apply_threshold([_object_hit(row) for row in rows if isinstance(row, dict)], score_threshold)

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]:
        body = self._send(endpoint, "GET", "v1/schema")
        classes = body.get("classes") if isinstance(body, dict) else None
        names = []
        for item in classes or []:
            if isinstance(item, dict) and _parse_description(str(item.get("description") or "")):
                names.append(str(item.get("class")))
        return names

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]:
        class_name = weaviate_class(endpoint.collection)
        stats = self.describe(endpoint)
        if stats is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        path = "v1/objects?" + urlencode({"class": class_name, "limit": int(limit), "offset": int(offset)})
        body = self._send(endpoint, "GET", path)
        objects = body.get("objects") if isinstance(body, dict) else None
        if not isinstance(objects, list):
            raise StoreError("Weaviate objects response was not a list", "store_error", 502)
        total = body.get("totalResults") if isinstance(body, dict) else None
        nxt = str(offset + limit) if len(objects) == limit else None
        return {
            "points": [
                {"id": hit.id, "payload": hit.payload}
                for hit in (_object_hit(row) for row in objects if isinstance(row, dict))
            ],
            "next_offset": nxt,
            "points_count": int(total) if isinstance(total, int) else None,
            "dimensions": stats.vector_size,
            "distance": stats.distance,
        }


def _raise_batch_errors(body: Any, endpoint: StoreEndpoint) -> None:
    rows = body if isinstance(body, list) else []
    if isinstance(body, dict):
        found = body.get("result") or body.get("results") or body.get("objects") or []
        rows = found if isinstance(found, list) else []
    for row in rows:
        if not isinstance(row, dict):
            continue
        result = row.get("result") if isinstance(row.get("result"), dict) else row
        errors = result.get("errors") if isinstance(result, dict) else None
        if errors:
            raise StoreError(redact_text(json.dumps(errors)[:300], endpoint.api_key), "store_error", 502)


def open_weaviate(**kwargs: Any) -> WeaviateStore:
    return WeaviateStore(transport=kwargs.get("transport"))


register_vector_store("weaviate", open_weaviate)
