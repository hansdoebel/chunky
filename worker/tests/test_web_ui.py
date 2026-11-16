import json
from copy import deepcopy

import pytest
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.jobs import JobStore
from chunky_worker.models import JobSettings
from chunky_worker.qdrant_ingest import IngestError, PreparedPoint, QdrantCloudIngestor, embedding_identity, validate_collection_identity
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


def ui_app(settings, **kwargs):
    return create_app(settings=settings, pipeline=FakePipeline(), embeddings=FakeEmbeddings(), **kwargs)


def test_shell_static_auth_and_cache(tmp_settings, tmp_path):
    assets = tmp_path / "dist"
    (assets / "assets").mkdir(parents=True)
    (assets / "index.html").write_text("<html>Chunky</html>")
    (assets / "assets" / "app.js").write_text("export {}")
    with TestClient(ui_app(tmp_settings, web_dist=assets)) as client:
        assert client.get("/").status_code == 200
        assert client.get("/assets/app.js").status_code == 200
        assert client.get("/assets/%2e%2e/index.html").status_code == 404
        assert client.get("/v1/ui/config").status_code == 401
        assert client.get("/v1/jobs").status_code == 401
        response = client.get("/v1/ui/config", headers=auth_headers())
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert "default-src 'self'" in response.headers["content-security-policy"]
    with TestClient(ui_app(tmp_settings, web_dist=tmp_path / "missing")) as client:
        assert client.get("/").status_code == 503
        assert client.get("/v1/jobs", headers=auth_headers()).status_code == 200


def test_projection_and_pagination(tmp_settings):
    store = JobStore()
    with TestClient(ui_app(tmp_settings, store=store), headers=auth_headers()) as client:
        response = client.post("/v1/jobs", files={"file": ("note.txt", b"hi")}, data={"settings": json.dumps({"mode": "chunk_and_embed"})})
        job_id = response.json()["id"]
        wait_for_status(client, job_id, "succeeded")
        complete = client.get(f"/v1/jobs/{job_id}").json()
        assert complete["result"]["embeddings"]
        preview = client.get(f"/v1/jobs/{job_id}?include_embeddings=false").json()
        assert "embeddings" not in preview["result"]
        assert store.get(job_id).result.embeddings
        page = client.get("/v1/jobs?limit=1&offset=0").json()
        assert page["total"] == 1
        assert page["jobs"][0]["id"] == job_id
        assert "result" not in page["jobs"][0]
        assert "settings" not in page["jobs"][0]
        assert client.get("/v1/jobs?limit=0").status_code == 422
        assert client.get("/v1/jobs?offset=1").json()["jobs"] == []


@pytest.mark.parametrize("url", ["https://user:pass@example.com", "https://example.com?key=hidden", "file:///tmp/qdrant", "https://example.com/#hidden"])
def test_unsafe_worker_url_is_not_available(tmp_settings, url):
    tmp_settings.qdrant_url = url
    tmp_settings.qdrant_api_key = "server-secret"
    with TestClient(ui_app(tmp_settings), headers=auth_headers()) as client:
        body = client.get("/v1/ui/config").json()
        assert body["qdrant_available"] is False
        assert "server-secret" not in json.dumps(body)
        assert url not in json.dumps(body)


def test_worker_credentials_never_sent_to_client_host(tmp_settings, monkeypatch):
    tmp_settings.qdrant_url = "https://worker-qdrant.example"
    tmp_settings.qdrant_api_key = "server-secret"
    app = ui_app(tmp_settings)
    seen = []
    monkeypatch.setattr(app.state.runner, "start", lambda job_id, path: seen.append(app.state.store.get(job_id)))
    request = {"mode": "chunk_and_embed", "ingest_target": "qdrant_cloud", "use_worker_qdrant": True}
    with TestClient(app, headers=auth_headers()) as client:
        for override in ({"qdrant_url": "https://attacker.example"}, {"qdrant_api_key": "other"}, {"mode": "chunk_only"}):
            response = client.post("/v1/jobs", files={"file": ("note.txt", b"hi")}, data={"settings": json.dumps(request | override)})
            assert response.status_code == 400
            assert "server-secret" not in response.text
        assert not seen
        response = client.post("/v1/jobs", files={"file": ("note.txt", b"hi")}, data={"settings": json.dumps(request)})
        assert response.status_code == 202
        assert seen[0].settings.qdrant_url == tmp_settings.qdrant_url
        assert seen[0].settings.qdrant_api_key == tmp_settings.qdrant_api_key
        public = client.get(f"/v1/jobs/{seen[0].id}")
        assert "server-secret" not in public.text
        assert tmp_settings.qdrant_url not in public.text


def identity():
    return embedding_identity(backend="ollama", model="model-a", endpoint="http://localhost:11434", dimensions=3, distance="cosine", hybrid=False)


def collection(expected):
    return {"config": {"metadata": {"chunky_embedding": expected}, "params": {"vectors": {"size": 3, "distance": "Cosine"}}}}


@pytest.mark.parametrize("change", ["unknown", "model", "width", "hybrid", "distance"])
def test_identity_refuses_unknown_or_incompatible_collections(change):
    expected = identity()
    info = collection(deepcopy(expected))
    if change == "unknown":
        info["config"]["metadata"] = {}
    elif change == "model":
        info["config"]["metadata"]["chunky_embedding"]["model"] = "model-b"
    elif change == "width":
        info["config"]["params"]["vectors"]["size"] = 4
    elif change == "hybrid":
        info["config"]["params"]["vectors"] = {"dense": {"size": 3, "distance": "Cosine"}}
    else:
        info["config"]["params"]["vectors"]["distance"] = "Dot"
    with pytest.raises(IngestError):
        validate_collection_identity(info, expected)


def test_new_collection_identity_metadata_and_existing_no_mutations(monkeypatch):
    expected = identity()
    class Client:
        info = None
        writes = 0
        creates = []
        def collection_exists(self, **kwargs):
            return self.info is not None
        def get_collection(self, **kwargs):
            return self.info
        def create_collection(self, **kwargs):
            self.creates.append(kwargs)
            self.info = collection(kwargs["metadata"]["chunky_embedding"])
        def upsert(self, **kwargs):
            self.writes += 1
        def close(self):
            pass
    client = Client()
    ingestor = QdrantCloudIngestor()
    monkeypatch.setattr(ingestor, "_client", lambda *args: client)
    monkeypatch.setattr("chunky_worker.qdrant_ingest.ensure_payload_indexes", lambda *args: None)
    args = dict(url="https://qdrant.example", api_key="secret", collection="new", points=[PreparedPoint("00000000-0000-0000-0000-000000000001", [1, 2, 3], {})], vector_size=3, distance="cosine", batch_size=10, identity=expected)
    assert ingestor.upsert_cloud(**args) == 1
    assert client.creates[0]["metadata"] == {"chunky_embedding": expected}
    assert "localhost" not in json.dumps(client.creates[0]["metadata"])
    monkeypatch.setattr("chunky_worker.qdrant_ingest.ensure_payload_indexes", lambda *args: pytest.fail("existing collection changed"))
    assert ingestor.upsert_cloud(**args) == 1
    client.info["config"]["metadata"] = {}
    with pytest.raises(IngestError):
        ingestor.upsert_cloud(**args)
    assert client.writes == 2


def test_server_error_redaction_and_upsert_race_guard(monkeypatch):
    expected = identity()
    class Client:
        reads = 0
        writes = 0
        def collection_exists(self, **kwargs):
            return True
        def get_collection(self, **kwargs):
            self.reads += 1
            info = collection(deepcopy(expected))
            if self.reads > 2:
                info["config"]["metadata"] = {}
            return info
        def upsert(self, **kwargs):
            self.writes += 1
        def close(self):
            pass
    client = Client()
    ingestor = QdrantCloudIngestor()
    monkeypatch.setattr(ingestor, "_client", lambda *args: client)
    with pytest.raises(IngestError):
        ingestor.upsert_cloud(url="https://qdrant.example", api_key="server-secret", collection="existing", points=[PreparedPoint("00000000-0000-0000-0000-000000000001", [1, 2, 3], {})], vector_size=3, distance="cosine", batch_size=1, identity=expected)
    assert client.writes == 0
    monkeypatch.setattr(client, "get_collection", lambda **kwargs: (_ for _ in ()).throw(RuntimeError("failed key=server-secret")))
    with pytest.raises(IngestError, match="failed key=\\[redacted\\]") as error:
        ingestor.validate_identity(url="https://qdrant.example", api_key="server-secret", collection="existing", identity=expected)
    assert "server-secret" not in str(error.value)
