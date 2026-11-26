"""pgvector adapter with a scripted SQL client."""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from chunky_worker.pgvector_store import PgVectorStore, filter_sql
from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.settings import Settings
from chunky_worker.vector_store import StoreEndpoint, StorePoint, compile_filters, require_store
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


class ScriptedSQL:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple]] = []
        self.meta: list[dict] = []
        self.rows: list[dict] = []

    def execute(self, statement: str, parameters=()):
        params = tuple(parameters)
        self.calls.append((statement, params))
        text = " ".join(statement.split()).lower()
        if text.startswith("select count"):
            return [{"count": 1}]
        if "chunky_collection_meta" in text and text.startswith("select") and "where collection" in text:
            name = params[0] if params else None
            return [row for row in self.meta if row["collection"] == name]
        if "chunky_collection_meta" in text and text.startswith("select"):
            return list(self.meta)
        if text.startswith("insert into") and "chunky_collection_meta" in text:
            self.meta.append({"collection": params[0], "dimensions": params[1], "distance": params[2]})
            return []
        if " as score" in text:
            return list(self.rows)
        if text.startswith("select id, payload from"):
            return [{"id": "a", "payload": {"text": "Hello world"}}]
        return []


def _endpoint() -> StoreEndpoint:
    return StoreEndpoint("postgresql://localhost/chunks", "", "documents", "cosine")


def test_upsert_creates_hnsw_table_and_query_filters():
    sql = ScriptedSQL()
    store = PgVectorStore(transport=sql)
    endpoint = _endpoint()
    assert store.describe(endpoint) is None
    written = store.upsert(
        endpoint,
        [StorePoint("a", [0.1, 0.2, 0.3], {"text": "Hello", "year": 2024})],
        vector_size=3,
        distance="cosine",
        batch_size=10,
    )
    assert written == 1
    joined = "\n".join(statement for statement, _ in sql.calls)
    assert "CREATE EXTENSION IF NOT EXISTS vector" in joined
    assert "embedding vector(3)" in joined
    assert "vector_cosine_ops" in joined
    assert "ON CONFLICT (id) DO UPDATE" in joined
    sql.rows = [{"id": "a", "payload": {"text": "Hello", "year": 2024}, "score": 0.75}]
    hits = store.query(
        endpoint,
        vector=[0.1, 0.2, 0.3],
        text="Hello",
        mode="dense",
        limit=5,
        offset=0,
        filters=[_filter("year", match=2024)],
        score_threshold=0.5,
    )
    assert hits[0].id == "a" and hits[0].payload["year"] == 2024
    query = sql.calls[-1][0]
    assert "<=>" in query and "payload @>" in query
    assert sql.calls[-1][1][1] == '{"year":2024}'
    listed = store.list_collections(endpoint)
    assert listed == ["documents"]
    page = store.scroll(endpoint, limit=10, offset=0)
    assert page["dimensions"] == 3 and page["points"][0]["payload"]["text"] == "Hello world"


def test_dimension_and_distance_guards_and_hybrid_rrf():
    sql = ScriptedSQL()
    sql.meta.append({"collection": "documents", "dimensions": 4, "distance": "cosine"})
    store = PgVectorStore(transport=sql)
    with pytest.raises(DimensionMismatch):
        store.upsert(endpoint := _endpoint(), [StorePoint("a", [0.1], {"text": "x"})], vector_size=1, distance="cosine", batch_size=1)
    sql.meta[0]["dimensions"] = 2
    sql.meta[0]["distance"] = "dot"
    with pytest.raises(Exception, match="distance"):
        store.upsert(endpoint, [StorePoint("a", [0.1, 0.2], {"text": "x"})], vector_size=2, distance="cosine", batch_size=1)
    sql.meta[0]["distance"] = "cosine"
    sql.rows = [
        {"id": "a", "payload": {"text": "alpha"}, "score": 0.9},
        {"id": "b", "payload": {"text": "beta"}, "score": 0.1},
    ]
    hits = store.query(
        endpoint,
        vector=[0.2, 0.3],
        text="alpha",
        mode="hybrid",
        limit=1,
        offset=0,
        filters=[],
        score_threshold=None,
        weights=[1, 1],
    )
    assert hits[0].id == "a"
    assert any("plainto_tsquery" in statement for statement, _ in sql.calls)
    dot = PgVectorStore(transport=ScriptedSQL())
    dot_sql = dot.transport
    dot_sql.meta.append({"collection": "documents", "dimensions": 2, "distance": "dot"})
    dot.query(endpoint, vector=[0.2, 0.3], text="", mode="dense", limit=1, offset=0, filters=[], score_threshold=None)
    assert "<#>" in dot_sql.calls[-1][0]


def test_filter_should_group_and_worker_roundtrip(tmp_settings):
    compiled = compile_filters([
        _filter("source", text="paper", should=True),
        _filter("doi", match="10.1/x", negate=True),
    ])
    clause, params = filter_sql(compiled)
    assert "NOT" in clause and "ILIKE" in clause
    assert any(item == '{"doi":"10.1/x"}' for item in params)
    sql = ScriptedSQL()
    from chunky_worker.pgvector_store import open_pgvector
    from chunky_worker.vector_store import register_vector_store

    register_vector_store("pgvector", lambda **kwargs: PgVectorStore(transport=sql))
    try:
        _roundtrip(tmp_settings, sql)
    finally:
        register_vector_store("pgvector", open_pgvector)
    assert require_store("pgvector") == "pgvector"


def _roundtrip(tmp_settings, sql):
    from chunky_worker.app import create_app

    app = create_app(settings=tmp_settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings())
    body = {
        "mode": "chunk_and_embed",
        "ingest_target": "qdrant_cloud",
        "vector_store": "pgvector",
        "vector_store_url": "postgresql://chunky:secret@localhost/chunks",
        "embedding_model": "qwen3-embedding",
        "qdrant_collection": "documents",
    }
    with TestClient(app, headers=auth_headers()) as client:
        response = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(body)})
        assert response.status_code == 202
        job = wait_for_status(client, response.json()["id"], "succeeded", "failed")
        assert job["status"] == "succeeded", job
        assert job["result"]["ingest"]["store"] == "pgvector"
        assert "secret" not in json.dumps(job)
        sql.rows = [{"id": "hit", "payload": {"text": "Hello world"}, "score": 0.8}]
        found = client.post(
            "/v1/search",
            json={
                "query": "hello",
                "collection": "documents",
                "vector_store": "pgvector",
                "vector_store_url": "postgresql://localhost/chunks",
                "embedding_model": "qwen3-embedding",
            },
        )
        assert found.status_code == 200
        assert found.json()["vector_store"] == "pgvector"
        assert found.json()["results"][0]["id"] == "hit"


def test_env_accepts_pgvector(monkeypatch):
    for name in ("CHUNKY_VECTOR_STORE", "CHUNKY_VECTOR_STORE_URL", "CHUNKY_VECTOR_STORE_API_KEY", "CHUNKY_WORKER_TOKEN", "CHUNKY_WORKER_TOKEN_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")
    monkeypatch.setenv("CHUNKY_VECTOR_STORE", "pgvector")
    monkeypatch.setenv("CHUNKY_VECTOR_STORE_URL", "postgresql://localhost/chunks")
    settings = Settings.from_env()
    assert settings.vector_store == "pgvector"
    assert "chunks" in settings.vector_store_url


def _filter(key, **kwargs):
    data = {"key": key, "match": None, "text": None, "any": None, "empty": False, "should": False, "negate": False, "gt": None, "gte": None, "lt": None, "lte": None}
    data.update(kwargs)
    from types import SimpleNamespace

    return SimpleNamespace(**data)
