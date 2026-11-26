"""Milvus adapter with a scripted HTTP client."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from chunky_worker.milvus_store import MilvusStore, milvus_filter
from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.settings import Settings
from chunky_worker.vector_store import HTTPResult, StoreEndpoint, StorePoint, require_store
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


class FakeHTTP:
    def __init__(self) -> None:
        self.calls: list[tuple[str, object, dict]] = []
        self.collections: dict[str, dict] = {}
        self.rows: list[dict] = []
        self.distance = 0.8

    def send(self, method, url, *, headers, json_body=None):
        self.calls.append((url, json_body, dict(headers)))
        path = url.split("/v2/vectordb/", 1)[-1]
        if path == "collections/describe":
            name = json_body["collectionName"]
            if name not in self.collections:
                return HTTPResult(200, {"code": 100, "message": "collection not found"})
            return HTTPResult(200, {"code": 0, "data": self.collections[name]})
        if path == "collections/create":
            self.collections[json_body["collectionName"]] = json_body
            return HTTPResult(200, {"code": 0, "data": {}})
        if path == "entities/upsert":
            self.rows.extend(json_body["data"])
            return HTTPResult(200, {"code": 0, "data": {"upsertCount": len(json_body["data"])}})
        if path == "entities/search":
            return HTTPResult(200, {"code": 0, "data": [{"id": "a", "distance": self.distance, "body": json.dumps({"text": "Hello", "year": 2024})}]})
        if path == "entities/query":
            return HTTPResult(200, {"code": 0, "data": [{"id": "a", "body": json.dumps({"text": "Hello"})}]})
        if path == "collections/list":
            return HTTPResult(200, {"code": 0, "data": list(self.collections)})
        return HTTPResult(500, {"error": path})


def _endpoint() -> StoreEndpoint:
    return StoreEndpoint("https://milvus.example", "milvus-secret", "documents", "cosine")


def _year(value=2024, **extra):
    data = {"key": "year", "match": value, "text": None, "any": None, "empty": False, "should": False, "negate": False, "gt": None, "gte": None, "lt": None, "lte": None}
    data.update(extra)
    return SimpleNamespace(**data)


def test_create_upsert_and_filtered_search():
    http = FakeHTTP()
    store = MilvusStore(transport=http)
    endpoint = _endpoint()
    assert store.describe(endpoint) is None
    assert store.upsert(endpoint, [StorePoint("a", [0.1, 0.2, 0.3], {"text": "Hello", "year": 2024})], vector_size=3, distance="cosine", batch_size=8) == 1
    assert http.collections["documents"]["description"] == "chunky:3:COSINE"
    assert http.collections["documents"]["metricType"] == "COSINE"
    assert http.rows[0]["year"] == 2024
    assert http.calls[0][2]["authorization"] == "Bearer milvus-secret"
    hits = store.query(endpoint, vector=[0.1, 0.2, 0.3], text="Hello", mode="dense", limit=4, offset=0, filters=[_year()], score_threshold=0.5)
    assert hits[0].id == "a" and hits[0].payload["text"] == "Hello" and hits[0].score == 0.8
    search = next(body for url, body, _headers in http.calls if url.endswith("/entities/search"))
    assert search["filter"] == "year == 2024"
    assert search["searchParams"]["metricType"] == "COSINE"
    assert store.list_collections(endpoint) == ["documents"]
    assert store.scroll(endpoint, limit=5, offset=0)["points"][0]["payload"]["text"] == "Hello"


def test_guards_l2_score_and_filter_expression():
    http = FakeHTTP()
    http.collections["documents"] = {"collectionName": "documents", "description": "chunky:4:COSINE", "dimension": 4, "metricType": "COSINE"}
    store = MilvusStore(transport=http)
    with pytest.raises(DimensionMismatch):
        store.upsert(_endpoint(), [StorePoint("a", [0.1], {"text": "x"})], vector_size=1, distance="cosine", batch_size=1)
    http.collections["documents"] = {"description": "chunky:2:L2", "dimension": 2, "metricType": "L2"}
    http.distance = 1
    hits = store.query(_endpoint(), vector=[0.2, 0.4], text="", mode="dense", limit=1, offset=0, filters=[], score_threshold=None)
    assert hits[0].score == pytest.approx(0.5)
    with pytest.raises(Exception, match="dense"):
        store.query(_endpoint(), vector=[0.2, 0.4], text="x", mode="hybrid", limit=1, offset=0, filters=[], score_threshold=None)
    expression = milvus_filter([_year(match=None, gte=2020), _year(key="doi", match="10.1/x", negate=True)])
    assert "year >= 2020" in expression and 'not (doi == "10.1/x")' in expression


def test_worker_roundtrip_and_env(tmp_settings, monkeypatch):
    http = FakeHTTP()
    from chunky_worker.app import create_app
    from chunky_worker.milvus_store import open_milvus
    from chunky_worker.vector_store import register_vector_store

    register_vector_store("milvus", lambda **kwargs: MilvusStore(transport=http))
    try:
        app = create_app(settings=tmp_settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings())
        body = {
            "mode": "chunk_and_embed",
            "ingest_target": "qdrant_cloud",
            "vector_store": "milvus",
            "vector_store_url": "https://milvus.example",
            "vector_store_api_key": "milvus-secret",
            "embedding_model": "qwen3-embedding",
            "qdrant_collection": "documents",
        }
        with TestClient(app, headers=auth_headers()) as client:
            response = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(body)})
            job = wait_for_status(client, response.json()["id"], "succeeded", "failed")
            assert job["status"] == "succeeded", job
            assert job["result"]["ingest"]["store"] == "milvus"
            assert "milvus-secret" not in json.dumps(job)
            hybrid = client.post("/v1/search", json={"query": "hello", "collection": "documents", "vector_store": "milvus", "vector_store_url": "https://milvus.example", "embedding_model": "qwen3-embedding", "mode": "hybrid"})
            assert hybrid.status_code == 400
            assert hybrid.json()["error_type"] == "unsupported_search_mode"
            found = client.post("/v1/search", json={"query": "hello", "collection": "documents", "vector_store": "milvus", "vector_store_url": "https://milvus.example", "embedding_model": "qwen3-embedding"})
            assert found.status_code == 200
            assert found.json()["vector_store"] == "milvus"
            assert found.json()["results"][0]["payload"]["text"] == "Hello"
    finally:
        register_vector_store("milvus", open_milvus)
    for name in ("CHUNKY_VECTOR_STORE", "CHUNKY_VECTOR_STORE_URL", "CHUNKY_VECTOR_STORE_API_KEY", "CHUNKY_WORKER_TOKEN", "CHUNKY_WORKER_TOKEN_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")
    monkeypatch.setenv("CHUNKY_VECTOR_STORE", "milvus")
    assert Settings.from_env().vector_store == "milvus"
    assert require_store("milvus") == "milvus"
