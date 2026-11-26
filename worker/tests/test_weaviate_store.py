"""Weaviate adapter with a scripted HTTP client."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from chunky_worker.qdrant_ingest import DimensionMismatch
from chunky_worker.settings import Settings
from chunky_worker.vector_store import HTTPResult, StoreEndpoint, StorePoint, require_store
from chunky_worker.weaviate_store import WeaviateStore, _graphql_where
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


class FakeHTTP:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, object, dict]] = []
        self.classes: dict[str, dict] = {}
        self.objects: list[dict] = []
        self.graphql_row = {
            "chunky_id": "a",
            "body": json.dumps({"text": "Hello", "year": 2024}),
            "_additional": {"distance": 0.25},
        }

    def send(self, method, url, *, headers, json_body=None):
        self.calls.append((method, url, json_body, dict(headers)))
        if url.endswith("/v1/schema") and method == "GET":
            classes = [{"class": name, "description": spec.get("description")} for name, spec in self.classes.items()]
            return HTTPResult(200, {"classes": classes})
        if "/v1/schema/" in url and method == "GET":
            name = url.rstrip("/").rsplit("/", 1)[-1]
            if name not in self.classes:
                return HTTPResult(404, {"error": "missing"})
            return HTTPResult(200, self.classes[name])
        if url.endswith("/v1/schema") and method == "POST":
            self.classes[json_body["class"]] = json_body
            return HTTPResult(200, json_body)
        if url.endswith("/v1/batch/objects") and method == "POST":
            self.objects.extend(json_body["objects"])
            return HTTPResult(200, [{"result": {"status": "SUCCESS"}}])
        if url.endswith("/v1/graphql") and method == "POST":
            query = json_body["query"]
            class_name = "Documents" if "Documents(" in query else ""
            return HTTPResult(200, {"data": {"Get": {class_name: [self.graphql_row]}}})
        if "/v1/objects?" in url and method == "GET":
            return HTTPResult(200, {"objects": [{"properties": {"chunky_id": "a", "body": self.graphql_row["body"]}}], "totalResults": 1})
        return HTTPResult(500, {"error": url})


def _endpoint() -> StoreEndpoint:
    return StoreEndpoint("https://weaviate.example", "weaviate-secret", "documents", "cosine")


def test_schema_batch_and_dense_query():
    http = FakeHTTP()
    store = WeaviateStore(transport=http)
    endpoint = _endpoint()
    assert store.describe(endpoint) is None
    written = store.upsert(
        endpoint,
        [StorePoint("point-1", [0.1, 0.2, 0.3], {"text": "Hello", "year": 2024, "headings": ["Intro"]})],
        vector_size=3,
        distance="cosine",
        batch_size=10,
    )
    assert written == 1
    schema = http.classes["Documents"]
    assert schema["description"] == "chunky:3:cosine"
    assert schema["vectorizer"] == "none"
    assert http.objects[0]["vector"] == [0.1, 0.2, 0.3]
    assert http.objects[0]["properties"]["year"] == 2024
    assert http.calls[0][3]["authorization"] == "Bearer weaviate-secret"
    hits = store.query(
        endpoint,
        vector=[0.1, 0.2, 0.3],
        text="Hello",
        mode="dense",
        limit=5,
        offset=0,
        filters=[SimpleNamespace(key="year", match=2024, text=None, any=None, empty=False, should=False, negate=False, gt=None, gte=None, lt=None, lte=None)],
        score_threshold=0.5,
    )
    assert hits[0].id == "a"
    assert hits[0].score == pytest.approx(0.75)
    assert hits[0].payload["year"] == 2024
    query = next(body["query"] for method, url, body, _headers in http.calls if url.endswith("/v1/graphql"))
    assert "nearVector" in query and "valueInt: 2024" in query
    assert store.list_collections(endpoint) == ["Documents"]
    page = store.scroll(endpoint, limit=10, offset=0)
    assert page["dimensions"] == 3 and page["points"][0]["id"] == "a"


def test_dimension_guard_and_hybrid_query():
    http = FakeHTTP()
    http.classes["Documents"] = {"class": "Documents", "description": "chunky:4:cosine", "vectorizer": "none"}
    store = WeaviateStore(transport=http)
    with pytest.raises(DimensionMismatch):
        store.upsert(_endpoint(), [StorePoint("a", [0.1], {"text": "x"})], vector_size=1, distance="cosine", batch_size=1)
    http.classes["Documents"]["description"] = "chunky:2:cosine"
    hits = store.query(
        _endpoint(),
        vector=[0.2, 0.4],
        text='say "hello"',
        mode="hybrid",
        limit=3,
        offset=1,
        filters=[],
        score_threshold=None,
        weights=[3, 1],
    )
    assert hits
    query = next(body["query"] for method, url, body, _headers in reversed(http.calls) if isinstance(body, dict) and "query" in body)
    assert "hybrid:" in query and 'say \\"hello\\"' in query and "alpha: 0.75" in query and "offset: 1" in query
    where = _graphql_where([
        SimpleNamespace(key="doi", match="10.1/x", text=None, any=None, empty=False, should=False, negate=True, gt=None, gte=None, lt=None, lte=None)
    ])
    assert "Not" in where and "10.1/x" in where


def test_worker_roundtrip_and_env(tmp_settings, monkeypatch):
    http = FakeHTTP()
    from chunky_worker.app import create_app
    from chunky_worker.vector_store import register_vector_store
    from chunky_worker.weaviate_store import open_weaviate

    register_vector_store("weaviate", lambda **kwargs: WeaviateStore(transport=http))
    try:
        app = create_app(settings=tmp_settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings())
        body = {
            "mode": "chunk_and_embed",
            "ingest_target": "qdrant_cloud",
            "vector_store": "weaviate",
            "vector_store_url": "https://weaviate.example",
            "vector_store_api_key": "weaviate-secret",
            "embedding_model": "qwen3-embedding",
            "qdrant_collection": "documents",
        }
        with TestClient(app, headers=auth_headers()) as client:
            response = client.post("/v1/jobs", files={"file": ("paper.txt", b"hello", "text/plain")}, data={"settings": json.dumps(body)})
            job = wait_for_status(client, response.json()["id"], "succeeded", "failed")
            assert job["status"] == "succeeded", job
            assert job["result"]["ingest"]["store"] == "weaviate"
            assert "weaviate-secret" not in json.dumps(job)
            found = client.post(
                "/v1/search",
                json={
                    "query": "hello",
                    "collection": "documents",
                    "vector_store": "weaviate",
                    "vector_store_url": "https://weaviate.example",
                    "embedding_model": "qwen3-embedding",
                },
            )
            assert found.status_code == 200
            assert found.json()["results"][0]["payload"]["text"] == "Hello"
    finally:
        register_vector_store("weaviate", open_weaviate)
    for name in ("CHUNKY_VECTOR_STORE", "CHUNKY_VECTOR_STORE_URL", "CHUNKY_VECTOR_STORE_API_KEY", "CHUNKY_WORKER_TOKEN", "CHUNKY_WORKER_TOKEN_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", "/tmp/chunky-test-no-such-config")
    monkeypatch.setenv("CHUNKY_VECTOR_STORE", "weaviate")
    assert Settings.from_env().vector_store == "weaviate"
    assert require_store("weaviate") == "weaviate"
