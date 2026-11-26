"""Chroma adapter with a scripted HTTP client."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from chunky_worker.chroma_store import ChromaStore, chroma_where
from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.settings import Settings
from chunky_worker.vector_store import HTTPResult, StoreEndpoint, StorePoint, require_store
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


class FakeHTTP:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, object, dict]] = []
        self.collections: list[dict] = []
        self.upserts: list[dict] = []

    def send(self, method, url, *, headers, json_body=None):
        self.calls.append((method, url, json_body, dict(headers)))
        if url.endswith("/collections") and method == "GET":
            return HTTPResult(200, list(self.collections))
        if url.endswith("/collections") and method == "POST":
            created = {"id": "col-1", "name": json_body["name"], "metadata": json_body["metadata"]}
            self.collections.append(created)
            return HTTPResult(200, created)
        if url.endswith("/upsert") and method == "POST":
            self.upserts.append(json_body)
            return HTTPResult(200, {})
        if url.endswith("/query") and method == "POST":
            metadata = {"body": json.dumps({"text": "Hello", "year": 2024}), "chunky_id": "a", "text": "Hello", "year": 2024}
            return HTTPResult(200, {"ids": [["raw-id"]], "distances": [[0.25]], "metadatas": [[metadata]]})
        if url.endswith("/get") and method == "POST":
            return HTTPResult(200, {"ids": ["raw-id"], "metadatas": [{"body": json.dumps({"text": "Hello"}), "chunky_id": "a"}]})
        if url.endswith("/count") and method == "GET":
            return HTTPResult(200, 1)
        return HTTPResult(500, {"error": url})


def _endpoint() -> StoreEndpoint:
    return StoreEndpoint("https://chroma.example", "chroma-secret", "documents", "cosine")


def _year(**extra):
    data = {"key": "year", "match": 2024, "text": None, "any": None, "empty": False, "should": False, "negate": False, "gt": None, "gte": None, "lt": None, "lte": None}
    data.update(extra)
    return SimpleNamespace(**data)


def test_create_upsert_and_dense_query():
    http = FakeHTTP()
    store = ChromaStore(transport=http)
    endpoint = _endpoint()
    assert store.describe(endpoint) is None
    assert store.upsert(endpoint, [StorePoint("a", [0.1, 0.2, 0.3], {"text": "Hello", "year": 2024})], vector_size=3, distance="cosine", batch_size=5) == 1
    assert http.collections[0]["metadata"] == {"dimension": 3, "distance": "cosine"}
    assert http.upserts[0]["embeddings"] == [[0.1, 0.2, 0.3]]
    assert http.upserts[0]["metadatas"][0]["year"] == 2024
    assert "/collections/col-1/upsert" in http.calls[-1][1]
    assert http.calls[0][3]["x-chroma-token"] == "chroma-secret"
    assert http.calls[0][3]["authorization"] == "Bearer chroma-secret"
    hits = store.query(endpoint, vector=[0.1, 0.2, 0.3], text="Hello", mode="dense", limit=4, offset=0, filters=[_year()], score_threshold=0.5)
    assert hits[0].id == "a" and hits[0].score == pytest.approx(0.75) and hits[0].payload["text"] == "Hello"
    query = next(body for method, url, body, _headers in http.calls if url.endswith("/query"))
    assert query["where"] == {"year": {"$eq": 2024}}
    assert query["offset"] == 0
    assert store.list_collections(endpoint) == ["documents"]
    page = store.scroll(endpoint, limit=10, offset=0)
    assert page["points_count"] == 1 and page["points"][0]["id"] == "a" and page["distance"] == "cosine"


def test_dimension_guard_and_where_expression():
    http = FakeHTTP()
    http.collections.append({"id": "col-1", "name": "documents", "metadata": {"dimension": 4, "distance": "cosine"}})
    store = ChromaStore(transport=http)
    with pytest.raises(DimensionMismatch):
        store.upsert(_endpoint(), [StorePoint("a", [0.1], {"text": "x"})], vector_size=1, distance="cosine", batch_size=1)
    with pytest.raises(Exception, match="dense"):
        store.query(_endpoint(), vector=[0.1, 0.2, 0.3, 0.4], text="x", mode="hybrid", limit=1, offset=0, filters=[], score_threshold=None)
    where = chroma_where([_year(match=None, gte=2020), _year(key="doi", match="10.1/x", negate=True)])
    assert where == {"$and": [{"year": {"$gte": 2020.0}}, {"doi": {"$ne": "10.1/x"}}]}


def test_worker_roundtrip_and_env(tmp_settings, monkeypatch):
    http = FakeHTTP()
    from chunky_worker.app import create_app
    from chunky_worker.chroma_store import open_chroma
    from chunky_worker.vector_store import register_vector_store

    register_vector_store("chroma", lambda **kwargs: ChromaStore(transport=http))
    try:
        app = create_app(settings=tmp_settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings())
        body = {
            "mode": "chunk_and_embed",
            "ingest_target": "qdrant_cloud",
            "vector_store": "chroma",
            "vector_store_url": "https://chroma.example",
            "vector_store_api_key": "chroma-secret",
            "embedding_model": "qwen3-embedding",
            "qdrant_collection": "documents",
        }
        with TestClient(app, headers=auth_headers()) as client:
            response = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(body)})
            job = wait_for_status(client, response.json()["id"], "succeeded", "failed")
            assert job["status"] == "succeeded", job
            assert job["result"]["ingest"]["store"] == "chroma"
            assert "chroma-secret" not in json.dumps(job)
            found = client.post("/v1/search", json={"query": "hello", "collection": "documents", "vector_store": "chroma", "vector_store_url": "https://chroma.example", "embedding_model": "qwen3-embedding"})
            assert found.status_code == 200
            assert found.json()["vector_store"] == "chroma"
            assert found.json()["results"][0]["id"] == "a"
    finally:
        register_vector_store("chroma", open_chroma)
    for name in ("CHUNKY_VECTOR_STORE", "CHUNKY_VECTOR_STORE_URL", "CHUNKY_VECTOR_STORE_API_KEY", "CHUNKY_WORKER_TOKEN", "CHUNKY_WORKER_TOKEN_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")
    monkeypatch.setenv("CHUNKY_VECTOR_STORE", "chroma")
    assert Settings.from_env().vector_store == "chroma"
    assert require_store("chroma") == "chroma"
