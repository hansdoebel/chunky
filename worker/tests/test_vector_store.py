"""Vector-store contract. Qdrant stays the default path; other stores are injected."""

from __future__ import annotations

import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from chunky_worker.models import IngestReceipt, IngestTarget, JobSettings
from chunky_worker.settings import Settings
from chunky_worker.vector_store import (
    CollectionStats,
    HttpxTransport,
    PsycopgTransport,
    QdrantVectorStore,
    StoreEndpoint,
    StoreError,
    StoreHit,
    StorePoint,
    apply_threshold,
    compile_filters,
    configured_store,
    fuse_ranks,
    open_vector_store,
    payload_from_record,
    quote_identifier,
    record_fields,
    register_vector_store,
    require_store,
    unregister_vector_store,
    validate_store_url,
)
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status
from tests.test_qdrant_ingest import RecordingIngestor, _upload


class MemoryStore:
    kind = "memory"
    supports_hybrid = False

    def __init__(self) -> None:
        self.points: list[StorePoint] = []
        self.queries: list[dict] = []

    def describe(self, endpoint: StoreEndpoint) -> CollectionStats | None:
        if not self.points:
            return None
        return CollectionStats(len(self.points[0].vector), endpoint.distance, len(self.points))

    def upsert(self, endpoint, points, *, vector_size, distance, batch_size, on_progress=None) -> int:
        if points and len(points[0].vector) != vector_size:
            raise StoreError("dimension mismatch", "dimension_mismatch", 409)
        self.points.extend(points)
        if on_progress:
            on_progress(len(points), len(points))
        return len(points)

    def query(self, endpoint, *, vector, text, mode, limit, offset, filters, score_threshold, weights=None):
        self.queries.append({"mode": mode, "text": text, "filters": filters, "limit": limit, "offset": offset})
        hits = [StoreHit(point.id, 1.0, point.payload) for point in self.points]
        return apply_threshold(hits, score_threshold)[offset : offset + limit]

    def list_collections(self, endpoint) -> list[str]:
        return ["documents"]

    def scroll(self, endpoint, *, limit, offset) -> dict:
        page = self.points[offset : offset + limit]
        nxt = str(offset + limit) if offset + limit < len(self.points) else None
        return {
            "points": [{"id": point.id, "payload": point.payload} for point in page],
            "next_offset": nxt,
            "points_count": len(self.points),
            "dimensions": len(self.points[0].vector) if self.points else 0,
            "distance": "cosine",
        }


@pytest.fixture
def memory_store():
    store = MemoryStore()
    register_vector_store("memory", lambda **kwargs: store)
    try:
        yield store
    finally:
        unregister_vector_store("memory")


def test_default_settings_hide_store_credentials_and_keep_qdrant_receipts():
    data = JobSettings().public_dict()
    assert "vector_store" not in data
    assert "vector_store_url" not in data
    assert "vector_store_api_key" not in data
    receipt = IngestReceipt(target=IngestTarget.QDRANT_CLOUD, collection="documents", upserted=1, vector_size=3, distance="cosine")
    assert "store" not in receipt.model_dump(mode="json")
    named = receipt.model_copy(update={"store": "memory"})
    assert named.model_dump(mode="json")["store"] == "memory"


def test_qdrant_adapter_delegates_without_taking_the_production_path():
    ingestor = RecordingIngestor()
    searcher = SimpleNamespace(
        query_dense=lambda **kwargs: [SimpleNamespace(id="a", score=0.4, payload={"text": "a"})],
        query_hybrid=lambda **kwargs: [SimpleNamespace(id="b", score=0.2, payload={"text": "b"})],
        list_collections=lambda **kwargs: {"collections": [{"name": "documents"}]},
    )
    store = open_vector_store("qdrant", ingestor=ingestor, searcher=searcher)
    assert isinstance(store, QdrantVectorStore)
    endpoint = StoreEndpoint("http://127.0.0.1:6333", "secret", "documents", "cosine")
    written = store.upsert(
        endpoint,
        [StorePoint("a", [0.1, 0.2], {"text": "a"})],
        vector_size=2,
        distance="cosine",
        batch_size=10,
    )
    assert written == 1
    assert ingestor.calls[0]["collection"] == "documents"
    assert ingestor.calls[0]["points"][0].payload == {"text": "a"}
    assert store.query(endpoint, vector=[0.1, 0.2], text="a", mode="dense", limit=1, offset=0, filters=[], score_threshold=None)[0].id == "a"
    assert store.query(endpoint, vector=[0.1, 0.2], text="a", mode="hybrid", limit=1, offset=0, filters=[], score_threshold=None, weights=[1, 1])[0].id == "b"
    assert store.list_collections(endpoint) == ["documents"]
    with pytest.raises(StoreError, match="Unsupported"):
        require_store("unknownstore")


def test_filter_compiler_rrf_and_payload_roundtrip():
    filters = [
        SimpleNamespace(key="year", match=2024, text=None, any=None, empty=False, should=False, negate=False, gt=None, gte=None, lt=None, lte=None),
        SimpleNamespace(key="source", match=None, text="paper", any=None, empty=False, should=True, negate=False, gt=None, gte=None, lt=None, lte=None),
        SimpleNamespace(key="doi", match="10.1/x", text=None, any=None, empty=False, should=False, negate=True, gt=None, gte=None, lt=None, lte=None),
    ]
    compiled = compile_filters(filters)
    assert compiled is not None
    assert compiled.must[0].op == "eq" and compiled.must[0].value == 2024
    assert compiled.should[0].op == "text"
    assert compiled.must_not[0].key == "doi"
    assert compile_filters([]) is None
    fused = fuse_ranks(
        [[StoreHit("a", 1, {"n": 1}), StoreHit("b", 1, {"n": 2})], [StoreHit("b", 1, {"n": 2}), StoreHit("c", 1, {})]],
        weights=[1, 1],
        limit=2,
        offset=0,
    )
    assert fused[0].id == "b"
    assert apply_threshold(fused, 1) == []
    point = StorePoint("a", [0.1], {"text": "Hello", "year": 2024, "headings": ["Intro"], "source": ""})
    restored = payload_from_record(record_fields(point))
    assert restored["headings"] == ["Intro"]
    assert restored["year"] == 2024
    assert quote_identifier("chunky_documents") == '"chunky_documents"'
    with pytest.raises(StoreError):
        quote_identifier('bad"name')
    assert validate_store_url("weaviate", "https://weaviate.example") == "https://weaviate.example"
    with pytest.raises(StoreError):
        validate_store_url("weaviate", "https://user:pass@weaviate.example")
    assert validate_store_url("pgvector", "postgresql://chunky:secret@db.internal:5432/chunks").startswith("postgresql://")
    assert configured_store("") == "qdrant"


def test_http_transport_and_missing_postgres_driver(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["authorization"] == "Bearer secret"
        return httpx.Response(200, json={"ok": True})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    result = HttpxTransport(client=client).send("POST", "https://store.example", headers={"authorization": "Bearer secret"}, json_body={"a": 1})
    assert result.status_code == 200 and result.body == {"ok": True}

    real_import = __import__

    def guarded(name, *args, **kwargs):
        if name == "psycopg" or name.startswith("psycopg."):
            raise ImportError("missing")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr("builtins.__import__", guarded)
    with pytest.raises(StoreError, match="psycopg"):
        PsycopgTransport("postgresql://db.internal/chunks").execute("select 1")


def test_omitted_store_keeps_the_qdrant_ingestor(tmp_settings, memory_store):
    ingestor = RecordingIngestor()
    app = _app(tmp_settings, ingestor)
    with TestClient(app, headers=auth_headers()) as client:
        response = _upload(client, {"mode": "chunk_and_embed", "ingest_target": "qdrant_cloud", "qdrant_url": "http://127.0.0.1:6333", "qdrant_api_key": "secret", "embedding_model": "qwen3-embedding"})
        assert response.status_code == 202
        body = wait_for_status(client, response.json()["id"], "succeeded")
    assert ingestor.calls
    assert memory_store.points == []
    assert "store" not in body["result"]["ingest"]
    assert "vector_store" not in body["settings"]


def test_selected_store_writes_and_searches_without_qdrant(tmp_settings, memory_store):
    ingestor = RecordingIngestor()
    app = _app(tmp_settings, ingestor)
    settings = {
        "mode": "chunk_and_embed",
        "ingest_target": "qdrant_cloud",
        "vector_store": "memory",
        "vector_store_url": "http://127.0.0.1:9",
        "vector_store_api_key": "memory-secret",
        "embedding_model": "qwen3-embedding",
        "qdrant_collection": "documents",
    }
    with TestClient(app, headers=auth_headers()) as client:
        rejected = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(settings | {"vector_store": "unknownstore"})})
        assert rejected.status_code == 400
        response = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(settings)})
        assert response.status_code == 202
        body = wait_for_status(client, response.json()["id"], "succeeded")
        dumped = json.dumps(body)
        assert "memory-secret" not in dumped
        assert body["result"]["ingest"]["store"] == "memory"
        assert body["result"]["ingest"]["target"] == "qdrant_cloud"
        assert body["result"]["ingest"]["upserted"] >= 2
        assert "127.0.0.1:9" not in dumped
        assert ingestor.calls == []
        assert any(point.payload.get("text") == "Hello world" for point in memory_store.points)
        found = client.post("/v1/search", json={"query": "hello", "collection": "documents", "vector_store": "memory", "vector_store_url": "http://127.0.0.1:9", "embedding_model": "qwen3-embedding"})
        assert found.status_code == 200
        payload = found.json()
        assert payload["vector_store"] == "memory"
        assert payload["results"]
        papers = client.post("/v1/search", json={"query": "hello", "collection": "documents", "vector_store": "memory", "vector_store_url": "http://127.0.0.1:9", "embedding_model": "qwen3-embedding", "papers_first": True})
        assert papers.status_code == 400
        assert papers.json()["error_type"] == "unsupported_search_mode"
    tmp_settings.vector_store = "memory"
    tmp_settings.vector_store_url = "http://127.0.0.1:9"
    listed_app = _app(tmp_settings, ingestor)
    with TestClient(listed_app, headers=auth_headers()) as client:
        config = client.get("/v1/ui/config").json()
        assert config["vector_store"] == "memory"
        assert config["qdrant_label"] == "memory"
        page = client.get("/v1/collections/documents/points").json()
        assert page["semantic_search_available"] is True
        assert page["points"]


def test_qdrant_config_stays_labeled_worker_qdrant(tmp_settings):
    app = _app(tmp_settings, RecordingIngestor())
    with TestClient(app, headers=auth_headers()) as client:
        config = client.get("/v1/ui/config").json()
    assert config["vector_store"] == "qdrant"
    assert config["qdrant_label"] == "Worker Qdrant"
    assert config["vector_store_label"] == "Worker Qdrant"
    assert config["qdrant_available"] is False
    search = client_search_without_store(tmp_settings)
    assert search.status_code == 400
    assert "qdrant_url" in search.text


def test_env_selects_qdrant_and_rejects_unknown_stores(monkeypatch):
    for name in ("CHUNKY_VECTOR_STORE", "CHUNKY_VECTOR_STORE_URL", "CHUNKY_VECTOR_STORE_API_KEY", "CHUNKY_WORKER_TOKEN", "CHUNKY_WORKER_TOKEN_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")
    assert Settings.from_env().vector_store == "qdrant"
    monkeypatch.setenv("CHUNKY_VECTOR_STORE", "unknownstore")
    with pytest.raises(ValueError, match="Unsupported vector store"):
        Settings.from_env()


def _app(settings, ingestor):
    from chunky_worker.app import create_app

    return create_app(settings=settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings(), ingestor=ingestor)


def client_search_without_store(settings):
    app = _app(settings, RecordingIngestor())
    with TestClient(app, headers=auth_headers()) as client:
        return client.post("/v1/search", json={"query": "hello", "collection": "documents", "embedding_model": "qwen3-embedding"})
