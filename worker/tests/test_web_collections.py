import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.qdrant_ingest import embedding_identity
from chunky_worker.search import QdrantPointSearcher
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers


def trusted_info(settings, *, model=None, hybrid=False):
    identity = embedding_identity(backend=settings.embedding_backend, model=model or settings.embedding_model, endpoint=settings.embedding_url or settings.ollama_url, dimensions=3, distance="cosine", hybrid=hybrid)
    dense = {"size": 3, "distance": "Cosine"}
    return {"config": {"metadata": {"chunky_embedding": identity}, "params": {"vectors": {"dense": dense} if hybrid else dense}}, "points_count": 1201}


class BrowserQdrant:
    def __init__(self, info):
        self.info = info
        self.scrolls = []
        self.queries = []
        self.indexes = 0
        self.exists = True
        self.fail = False
        self.reads = 0
        self.replace_after = None

    def get_collections(self):
        if self.fail:
            raise RuntimeError("qdrant failed secret-server-key")
        return SimpleNamespace(collections=[SimpleNamespace(name="papers")])

    def collection_exists(self, **kwargs):
        return self.exists

    def get_collection(self, **kwargs):
        self.reads += 1
        if self.replace_after is not None and self.reads > self.replace_after:
            return {"config": {"metadata": {}, "params": self.info["config"]["params"]}}
        return self.info

    def scroll(self, **kwargs):
        self.scrolls.append(kwargs)
        return [SimpleNamespace(id=1001, payload={"text": "Past the first thousand", "source": "fixture.pdf", "page": 2})], 1002

    def create_payload_index(self, **kwargs):
        self.indexes += 1

    def query_points(self, **kwargs):
        self.queries.append(kwargs)
        return SimpleNamespace(points=[SimpleNamespace(id=1001, score=.9, payload={"text": "Scientific fixture text"})])

    def close(self):
        pass


def browser_client(settings, fake, embeddings=None):
    calls = []
    def factory(url, key):
        calls.append((url, key))
        return fake
    app = create_app(settings=settings, pipeline=FakePipeline(), embeddings=embeddings or FakeEmbeddings(), searcher=QdrantPointSearcher(factory), model_cache=lambda: ([], None), model_server=lambda: [], ollama_tags=lambda: ([], None))
    return TestClient(app, headers=auth_headers()), calls


def configure(settings, *, key="secret-server-key"):
    settings.qdrant_url = "https://configured.example"
    settings.qdrant_api_key = key


def test_auth_config_and_configured_only_target(tmp_settings):
    configure(tmp_settings)
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, calls = browser_client(tmp_settings, fake)
    with client:
        assert client.get("/v1/collections", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert client.get("/v1/collections/papers/points", headers={"Authorization": "Bearer wrong"}).status_code == 401
        config = client.get("/v1/ui/config").json()
        assert config["qdrant_read_available"] and config["qdrant_available"]
        response = client.get("/v1/collections?qdrant_url=https://other.example")
        assert response.json() == {"collections": [{"name": "papers"}], "target_label": "Worker Qdrant"}
        assert calls == [(tmp_settings.qdrant_url, tmp_settings.qdrant_api_key)]
        assert tmp_settings.qdrant_api_key not in response.text
        assert tmp_settings.qdrant_url not in response.text


def test_keyless_scroll_cursor_and_safe_identity_summary(tmp_settings):
    configure(tmp_settings, key="")
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, calls = browser_client(tmp_settings, fake)
    with client:
        config = client.get("/v1/ui/config").json()
        assert config["qdrant_read_available"] and not config["qdrant_available"]
        body = client.get("/v1/collections/papers/points?limit=1&offset=1001").json()
        assert body["points_count"] == 1201
        assert body["points"][0]["id"] == "1001"
        assert body["next_offset"] == "1002"
        assert body["limit"] == 1 and body["semantic_search_available"]
        assert set(body["embedding"]) == {"backend", "model", "dimensions", "distance", "hybrid"}
        assert "endpoint_sha256" not in json.dumps(body)
        assert fake.scrolls[0] == {"collection_name": "papers", "limit": 1, "offset": 1001, "with_payload": True, "with_vectors": False}
        cursor = "fef8e7d1-7602-48ad-a4c4-030d9c7dfdb0"
        assert client.get(f"/v1/collections/papers/points?offset={cursor}").status_code == 200
        assert fake.scrolls[1]["offset"] == cursor
        assert all(key == "" for _, key in calls)
        for query in ("limit=0", "limit=101", "offset=-1", "offset=not-a-point", "offset=18446744073709551616", "offset=" + "9" * 100):
            assert client.get("/v1/collections/papers/points?" + query).status_code == 422


@pytest.mark.parametrize("url", ["", "https://user:key@target.example", "https://target.example?secret=x", "https://target.example/#secret", "file:///tmp/db", "https://target.example:bad"])
def test_unsafe_or_missing_target_never_opens_client(tmp_settings, url):
    configure(tmp_settings)
    tmp_settings.qdrant_url = url
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, calls = browser_client(tmp_settings, fake)
    with client:
        assert not client.get("/v1/ui/config").json()["qdrant_read_available"]
        assert client.get("/v1/collections").status_code == 400
        assert not calls


def test_unknown_identity_browsable_not_searchable_and_errors_redacted(tmp_settings):
    configure(tmp_settings)
    info = trusted_info(tmp_settings)
    info["config"]["metadata"] = {}
    fake = BrowserQdrant(info)
    client, _ = browser_client(tmp_settings, fake)
    with client:
        body = client.get("/v1/collections/papers/points").json()
        assert body["points"] and not body["semantic_search_available"] and body["semantic_search_reason"]
        assert body["embedding"] is None
        response = client.post("/v1/search", json={"query": "fixture", "collection": "papers", "use_worker_qdrant": True})
        assert response.status_code == 409 and not fake.queries and not fake.indexes
        fake.fail = True
        response = client.get("/v1/collections")
        assert response.status_code == 502
        assert "secret-server-key" not in response.text
        fake.fail = False
        fake.exists = False
        assert client.get("/v1/collections/missing/points").status_code == 404


@pytest.mark.parametrize("change", ["model", "backend", "endpoint", "width", "distance", "hybrid"])
def test_managed_search_refuses_incompatible_identity_before_query(tmp_settings, change):
    configure(tmp_settings)
    info = trusted_info(tmp_settings)
    metadata = info["config"]["metadata"]["chunky_embedding"]
    if change == "model": metadata["model"] = "different-same-width-model"
    elif change == "backend": metadata["backend"] = "openai"
    elif change == "endpoint": metadata["endpoint_sha256"] = "0" * 64
    elif change == "width": info["config"]["params"]["vectors"]["size"] = 4
    elif change == "distance": info["config"]["params"]["vectors"]["distance"] = "Dot"
    else: metadata["hybrid"] = True
    fake = BrowserQdrant(info)
    client, _ = browser_client(tmp_settings, fake)
    with client:
        response = client.post("/v1/search", json={"query": "fixture", "collection": "papers", "use_worker_qdrant": True})
        assert response.status_code == 409, response.text
        assert response.json()["error_type"] == "embedding_identity_mismatch"
        assert not fake.queries and not fake.indexes


def test_managed_dense_and_hybrid_search_never_mutate_indexes(tmp_settings):
    configure(tmp_settings, key="")
    fake = BrowserQdrant(trusted_info(tmp_settings, hybrid=True))
    client, _ = browser_client(tmp_settings, fake)
    with client:
        for mode in ("dense", "hybrid"):
            response = client.post("/v1/search", json={"query": "fixture", "collection": "papers", "mode": mode, "use_worker_qdrant": True, "limit": 1, "offset": 1001})
            assert response.status_code == 200, response.text
            assert response.json()["results"][0]["score"] == .9
            assert response.json()["next_offset"] == 1002
        assert len(fake.queries) == 2 and not fake.indexes
        assert fake.queries[0]["using"] == "dense"
        assert fake.queries[0]["offset"] == 1001
        assert all(call["with_vectors"] is False for call in fake.queries)


def test_managed_target_overrides_rejected_and_dense_hybrid_not_adopted(tmp_settings):
    configure(tmp_settings)
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, calls = browser_client(tmp_settings, fake)
    with client:
        base = {"query": "fixture", "collection": "papers", "use_worker_qdrant": True}
        for override in ({"qdrant_url": "https://other.example"}, {"qdrant_api_key": ""}):
            assert client.post("/v1/search", json=base | override).status_code == 400
        assert not calls
        assert client.post("/v1/search", json=base | {"mode": "hybrid"}).status_code == 409
        assert not fake.queries and not fake.indexes


def test_actual_query_width_and_finiteness_guard(tmp_settings):
    configure(tmp_settings)
    class Embeddings(FakeEmbeddings):
        vector = [1, 2]
        def embed(self, texts, model): return [self.vector]
    backend = Embeddings()
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, _ = browser_client(tmp_settings, fake, backend)
    with client:
        base = {"query": "fixture", "collection": "papers", "use_worker_qdrant": True}
        assert client.post("/v1/search", json=base).status_code == 409
        backend.vector = [1, float("nan"), 3]
        response = client.post("/v1/search", json=base)
        assert response.status_code == 502 and response.json()["error_type"] == "embedding_error"
        assert not fake.queries


def test_collection_replacement_before_query_is_refused(tmp_settings):
    configure(tmp_settings)
    fake = BrowserQdrant(trusted_info(tmp_settings))
    fake.replace_after = 1
    client, _ = browser_client(tmp_settings, fake)
    with client:
        response = client.post("/v1/search", json={"query": "fixture", "collection": "papers", "use_worker_qdrant": True})
        assert response.status_code == 409
        assert not fake.queries and not fake.indexes


def test_legacy_search_keeps_index_preparation(tmp_settings):
    configure(tmp_settings)
    fake = BrowserQdrant(trusted_info(tmp_settings))
    client, _ = browser_client(tmp_settings, fake)
    with client:
        response = client.post("/v1/search", json={"query": "fixture", "collection": "papers"})
        assert response.status_code == 200
        assert fake.indexes > 0


def test_matching_custom_model_provider_and_endpoint_queries_without_key_egress(tmp_settings, monkeypatch):
    configure(tmp_settings)
    info = trusted_info(tmp_settings, model="custom-document-model")
    recorded = info["config"]["metadata"]["chunky_embedding"]
    recorded["backend"] = "openai"
    recorded["endpoint_sha256"] = embedding_identity(backend="openai", model="custom-document-model", endpoint="http://custom-embedding.example", dimensions=3, distance="cosine", hybrid=False)["endpoint_sha256"]
    fake = BrowserQdrant(info)
    backends = []
    backend = FakeEmbeddings()
    def make_backend(kind, url):
        backends.append((kind, url))
        return backend
    monkeypatch.setattr("chunky_worker.search.make_embedding_backend", make_backend)
    client, calls = browser_client(tmp_settings, fake)
    with client:
        response = client.post("/v1/search", json={"query": "fixture", "collection": "papers", "use_worker_qdrant": True, "embedding_backend": "openai", "embedding_model": "custom-document-model", "embedding_url": "http://custom-embedding.example"})
        assert response.status_code == 200, response.text
        assert response.json()["embedding_backend"] == "openai"
        assert response.json()["embedding_model"] == "custom-document-model"
        assert backends == [("openai", "http://custom-embedding.example")]
        assert all(url == tmp_settings.qdrant_url and key == tmp_settings.qdrant_api_key for url, key in calls)
        assert "secret-server-key" not in response.text
        assert backend.embed_calls == [(["fixture"], "custom-document-model")]
        assert not fake.indexes
