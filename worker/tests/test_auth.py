"""Bearer-token auth. Health stays open; every other /v1 route requires the token."""

from __future__ import annotations

from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.auth import generate_token, write_token_file
from chunky_worker.jobs import JobStore
from tests.conftest import TEST_TOKEN, FakeEmbeddings, FakePipeline, auth_headers


def _app(settings):
    return create_app(
        settings=settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(),
        store=JobStore(),
        model_cache=lambda: ([], None),
        model_server=lambda: [],
        ollama_tags=lambda: ([], None),
    )


def test_health_is_open_without_a_token(tmp_settings):
    with TestClient(_app(tmp_settings)) as client:
        response = client.get("/v1/health")
    assert response.status_code == 200
    assert "token" not in response.text.lower()


def test_protected_routes_reject_missing_token(tmp_settings):
    with TestClient(_app(tmp_settings)) as client:
        assert client.get("/v1/models").status_code == 401
        response = client.post(
            "/v1/jobs",
            files={"file": ("a.txt", b"x", "text/plain")},
            data={"settings": "{}"},
        )
        assert response.status_code == 401
        assert response.json()["detail"] == "Invalid or missing bearer token"
        assert client.get("/v1/jobs/nope").status_code == 401
        assert client.post("/v1/jobs/nope/cancel").status_code == 401
        assert client.get("/v1/jobs/nope/events").status_code == 401
        search = client.post(
            "/v1/search",
            json={"query": "revenue", "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
        assert search.status_code == 401


def test_query_string_token_is_not_accepted(tmp_settings):
    with TestClient(_app(tmp_settings)) as client:
        response = client.get(f"/v1/models?token={TEST_TOKEN}")
    assert response.status_code == 401


def test_wrong_token_is_401(tmp_settings):
    with TestClient(_app(tmp_settings), headers=auth_headers("nope")) as client:
        response = client.get("/v1/models")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"


def test_valid_token_allows_models(tmp_settings):
    with TestClient(_app(tmp_settings), headers=auth_headers()) as client:
        response = client.get("/v1/models")
    assert response.status_code == 200
    assert response.json()["embeddings"]


def test_unconfigured_token_fails_closed(tmp_settings):
    tmp_settings.token = None
    with TestClient(_app(tmp_settings)) as client:
        response = client.get("/v1/models")
    assert response.status_code == 401
    assert response.json()["detail"] == "Worker token is not configured"
    # Health still answers so an operator can see the process is up.
    with TestClient(_app(tmp_settings)) as client:
        assert client.get("/v1/health").status_code == 200


def test_generate_token_is_unique_and_url_safe():
    first = generate_token()
    second = generate_token()
    assert first != second
    assert len(first) >= 32
    assert " " not in first


def test_write_token_file_is_mode_0600(tmp_path):
    path = tmp_path / "nested" / "worker.token"
    token = write_token_file(path)
    assert path.read_text(encoding="utf-8").strip() == token
    assert path.stat().st_mode & 0o777 == 0o600


def test_require_bearer_rejects_non_bearer_scheme(tmp_settings):
    app = _app(tmp_settings)
    with TestClient(app, headers={"Authorization": f"Basic {TEST_TOKEN}"}) as client:
        assert client.get("/v1/models").status_code == 401
