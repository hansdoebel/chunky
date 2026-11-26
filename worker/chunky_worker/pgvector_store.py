"""Postgres pgvector adapter. Tests inject a SQL transport; psycopg is optional."""

from __future__ import annotations

import json
from typing import Any, Sequence

from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.vector_store import (
    CollectionStats,
    CompiledFilters,
    FilterAtom,
    PsycopgTransport,
    SQLTransport,
    StoreEndpoint,
    StoreError,
    StoreHit,
    StorePoint,
    apply_threshold,
    collection_name,
    compile_filters,
    fuse_ranks,
    payload_from_record,
    quote_identifier,
    register_vector_store,
    table_name,
    validate_store_url,
    vector_text,
)

_META = quote_identifier("chunky_collection_meta")
_OPS = {"cosine": "vector_cosine_ops", "euclid": "vector_l2_ops", "dot": "vector_ip_ops"}


def _like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _atom_sql(atom: FilterAtom) -> tuple[str, list[Any]]:
    if atom.op == "eq":
        return "payload @> %s::jsonb", [json.dumps({atom.key: atom.value}, separators=(",", ":"))]
    if atom.op == "text":
        pattern = "%" + _like(str(atom.value)) + "%"
        sql = (
            "(COALESCE(payload->>%s, '') ILIKE %s ESCAPE '\\' OR EXISTS ("
            "SELECT 1 FROM jsonb_array_elements_text("
            "CASE WHEN jsonb_typeof(payload->%s) = 'array' THEN payload->%s ELSE '[]'::jsonb END"
            ") element WHERE element ILIKE %s ESCAPE '\\'))"
        )
        return sql, [atom.key, pattern, atom.key, atom.key, pattern]
    if atom.op == "any":
        return "payload->>%s = ANY(%s)", [atom.key, [str(item) for item in atom.value]]
    if atom.op == "empty":
        return "(NOT (payload ? %s) OR payload->>%s IS NULL OR payload->>%s = '')", [atom.key, atom.key, atom.key]
    if atom.op == "range":
        parts: list[str] = []
        params: list[Any] = []
        for operator, bound in ((">", atom.gt), (">=", atom.gte), ("<", atom.lt), ("<=", atom.lte)):
            if bound is not None:
                parts.append(f"(payload->>%s)::double precision {operator} %s")
                params.extend([atom.key, float(bound)])
        if not parts:
            raise StoreError(f"Filter {atom.key!r} needs a range", "invalid_filter", 400)
        return "(" + " AND ".join(parts) + ")", params
    raise StoreError(f"Unsupported filter {atom.op}", "invalid_filter", 400)


def filter_sql(filters: CompiledFilters | None) -> tuple[str, list[Any]]:
    if filters is None:
        return "", []
    parts: list[str] = []
    params: list[Any] = []
    for atom in filters.must:
        sql, extra = _atom_sql(atom)
        parts.append(sql)
        params.extend(extra)
    for atom in filters.must_not:
        sql, extra = _atom_sql(atom)
        parts.append(f"NOT ({sql})")
        params.extend(extra)
    if filters.should:
        choices: list[str] = []
        for atom in filters.should:
            sql, extra = _atom_sql(atom)
            choices.append(sql)
            params.extend(extra)
        parts.append("(" + " OR ".join(choices) + ")")
    return " AND ".join(parts), params


def _metric(distance: str) -> tuple[str, str]:
    if distance == "cosine":
        return "1 - (embedding <=> %s::vector)", "embedding <=> %s::vector"
    if distance == "euclid":
        return "1.0 / (1.0 + (embedding <-> %s::vector))", "embedding <-> %s::vector"
    if distance == "dot":
        return "-(embedding <#> %s::vector)", "embedding <#> %s::vector"
    raise StoreError(f"Unsupported distance: {distance}", "invalid_distance", 400)


def _index_name(collection: str) -> str:
    return quote_identifier("hnsw_" + collection)


class PgVectorStore:
    kind = "pgvector"
    supports_hybrid = True

    def __init__(self, transport: SQLTransport | None = None, **kwargs: Any) -> None:
        self.transport = transport

    def _sql(self, endpoint: StoreEndpoint) -> SQLTransport:
        validate_store_url("pgvector", endpoint.url)
        collection_name(endpoint.collection)
        if self.transport is not None:
            return self.transport
        return PsycopgTransport(endpoint.url)

    def _run(self, sql: SQLTransport, statement: str, parameters: Sequence[Any] = ()) -> list[dict[str, Any]]:
        return list(sql.execute(statement, tuple(parameters)))

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        sql = self._sql(endpoint)
        try:
            rows = self._read_meta(sql, endpoint.collection)
        except StoreError as exc:
            if "does not exist" in str(exc).lower():
                return None
            raise
        if not rows:
            return None
        row = rows[0]
        return CollectionStats(int(row["dimensions"]), str(row["distance"]))

    def _read_meta(self, sql: SQLTransport, collection: str) -> list[dict[str, Any]]:
        return self._run(
            sql,
            f"SELECT dimensions, distance FROM {_META} WHERE collection = %s",
            (collection,),
        )

    def _ensure_meta(self, sql: SQLTransport) -> None:
        self._run(sql, "CREATE EXTENSION IF NOT EXISTS vector")
        self._run(
            sql,
            f"CREATE TABLE IF NOT EXISTS {_META} ("
            "collection text PRIMARY KEY, dimensions integer NOT NULL, distance text NOT NULL)",
        )

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
        if distance not in _OPS:
            raise StoreError(f"Unsupported distance: {distance}", "invalid_distance", 400)
        if batch_size < 1:
            raise StoreError("batch size must be at least 1", "invalid_batch", 400)
        sql = self._sql(endpoint)
        self._ensure_meta(sql)
        existing = self._read_meta(sql, endpoint.collection)
        table = table_name(endpoint.collection)
        if not existing:
            self._run(
                sql,
                f"CREATE TABLE IF NOT EXISTS {table} ("
                f"id text PRIMARY KEY, embedding vector({vector_size}) NOT NULL, payload jsonb NOT NULL)",
            )
            self._run(
                sql,
                f"CREATE INDEX IF NOT EXISTS {_index_name(endpoint.collection)} "
                f"ON {table} USING hnsw (embedding {_OPS[distance]})",
            )
            self._run(
                sql,
                f"INSERT INTO {_META} (collection, dimensions, distance) VALUES (%s, %s, %s) "
                "ON CONFLICT (collection) DO NOTHING",
                (endpoint.collection, vector_size, distance),
            )
        else:
            found = int(existing[0]["dimensions"])
            if found != vector_size:
                raise DimensionMismatch(
                    f"Collection {endpoint.collection!r} has vector size {found}, "
                    f"but the embedding model produced size {vector_size}. Refusing to upsert."
                )
            if str(existing[0]["distance"]) != distance:
                raise StoreError(
                    f"Collection {endpoint.collection!r} uses distance {existing[0]['distance']}",
                    "invalid_distance",
                    409,
                )
        written = 0
        total = len(points)
        for start in range(0, total, batch_size):
            batch = points[start : start + batch_size]
            values = ",".join(["(%s, %s::vector, %s::jsonb)"] * len(batch))
            params: list[Any] = []
            for point in batch:
                if len(point.vector) != vector_size:
                    raise StoreError("Embedding vectors have inconsistent dimensions", "invalid_vector", 400)
                params.extend([point.id, vector_text(point.vector), json.dumps(point.payload, default=str)])
            self._run(
                sql,
                f"INSERT INTO {table} (id, embedding, payload) VALUES {values} "
                "ON CONFLICT (id) DO UPDATE SET embedding = EXCLUDED.embedding, payload = EXCLUDED.payload",
                params,
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
        sql = self._sql(endpoint)
        stats = self.describe(endpoint)
        if stats is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        if stats.vector_size != len(vector):
            raise DimensionMismatch(
                f"Collection {endpoint.collection!r} has vector size {stats.vector_size}, "
                f"but the query vector has size {len(vector)}. Refusing to search."
            )
        compiled = compile_filters(filters)
        if mode == "hybrid":
            window = max(limit + max(offset, 0), 1)
            dense = self._dense(sql, endpoint, vector, stats.distance, compiled, window, 0)
            lexical = self._lexical(sql, endpoint, text, compiled, window)
            hits = fuse_ranks([dense, lexical], weights=weights, limit=limit, offset=offset)
            return apply_threshold(hits, score_threshold)
        if mode != "dense":
            raise StoreError("mode must be dense or hybrid", "invalid_search", 400)
        return apply_threshold(self._dense(sql, endpoint, vector, stats.distance, compiled, limit, offset), score_threshold)

    def _dense(self, sql, endpoint, vector, distance, compiled, limit, offset) -> list[StoreHit]:
        score, order = _metric(distance)
        clause, params = filter_sql(compiled)
        where = f" WHERE {clause}" if clause else ""
        literal = vector_text(vector)
        rows = self._run(
            sql,
            f"SELECT id, payload, {score} AS score FROM {table_name(endpoint.collection)}{where} "
            f"ORDER BY {order} LIMIT %s OFFSET %s",
            (literal, *params, literal, limit, offset),
        )
        return [_hit(row) for row in rows]

    def _lexical(self, sql, endpoint, text, compiled, limit) -> list[StoreHit]:
        document = "to_tsvector('simple', coalesce(payload->>'text','') || ' ' || coalesce(payload->>'embedding_text',''))"
        clause, params = filter_sql(compiled)
        extra = f" AND {clause}" if clause else ""
        rows = self._run(
            sql,
            f"SELECT id, payload, ts_rank_cd({document}, plainto_tsquery('simple', %s)) AS score "
            f"FROM {table_name(endpoint.collection)} "
            f"WHERE {document} @@ plainto_tsquery('simple', %s){extra} "
            "ORDER BY score DESC LIMIT %s",
            (text, text, *params, limit),
        )
        return [_hit(row) for row in rows]

    def list_collections(self, endpoint: StoreEndpoint) -> list[str]:
        sql = self._sql(endpoint)
        try:
            rows = self._run(sql, f"SELECT collection FROM {_META} ORDER BY collection")
        except StoreError as exc:
            if "does not exist" in str(exc).lower():
                return []
            raise
        return [str(row["collection"]) for row in rows]

    def scroll(self, endpoint: StoreEndpoint, *, limit: int, offset: int) -> dict[str, Any]:
        sql = self._sql(endpoint)
        stats = self.describe(endpoint)
        if stats is None:
            raise StoreError(f"Collection {endpoint.collection!r} was not found", "not_found", 404)
        table = table_name(endpoint.collection)
        rows = self._run(
            sql,
            f"SELECT id, payload FROM {table} ORDER BY id LIMIT %s OFFSET %s",
            (limit, offset),
        )
        counted = self._run(sql, f"SELECT count(*)::int AS count FROM {table}")
        total = int(counted[0]["count"]) if counted else None
        nxt = str(offset + limit) if len(rows) == limit else None
        return {
            "points": [{"id": str(row["id"]), "payload": payload_from_record(row)} for row in rows],
            "next_offset": nxt,
            "points_count": total,
            "dimensions": stats.vector_size,
            "distance": stats.distance,
        }


def _hit(row: dict[str, Any]) -> StoreHit:
    return StoreHit(str(row["id"]), float(row["score"]), payload_from_record(row))


def open_pgvector(**kwargs: Any) -> PgVectorStore:
    return PgVectorStore(transport=kwargs.get("transport"))


register_vector_store("pgvector", open_pgvector)
