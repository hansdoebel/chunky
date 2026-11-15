"""HTTP contract tests for the worker, with Docling and Ollama mocked."""

from __future__ import annotations

import json

from fastapi.testclient import TestClient

from chunky_worker.app import MLX_VLM_MODELS, TRANSFORMERS_VLM_MODELS, create_app
from chunky_worker.jobs import JobStore
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status


def _upload(client, content=b"hello", filename="note.txt", settings=None):
    data = {}
    if settings is not None:
        data["settings"] = json.dumps(settings)
    return client.post(
        "/v1/jobs",
        files={"file": (filename, content, "text/plain")},
        data=data,
    )


def test_health_ok_when_backends_mocked(client, monkeypatch):
    monkeypatch.setattr("chunky_worker.app.docling_import_status", lambda: (True, None))
    response = client.get("/v1/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["docling"]["importable"] is True
    assert body["embeddings"]["reachable"] is True
    assert body["embeddings"]["backend"] == "ollama"
    assert body["vlm"]["engine"] == "vllm"
    assert body["vlm"]["preset"] == "granite_docling"
    assert body["vlm"]["model"] == "ibm-granite/granite-docling-258M"
    assert body["vlm"]["device"] == "cuda"
    assert body["vlm"]["flash_attention2"] is False
    assert body["vlm"]["mlx"] is False


def test_health_degraded_when_docling_missing_and_ollama_down(tmp_settings, monkeypatch):
    monkeypatch.setattr("chunky_worker.app.docling_import_status", lambda: (False, "No module named 'docling'"))
    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(reachable=False),
        store=JobStore(),
    )
    with __import__("fastapi.testclient", fromlist=["TestClient"]).TestClient(app) as client:
        body = client.get("/v1/health").json()
    assert body["status"] == "degraded"
    assert body["docling"]["importable"] is False
    assert "docling" in (body["docling"]["error"] or "").lower()
    assert body["embeddings"]["reachable"] is False


def test_models_lists_embeddings_and_known_vlms(client):
    body = client.get("/v1/models").json()
    names = [item["name"] for item in body["embeddings"]]
    assert "qwen3-embedding" in names
    vlm_names = {item["name"]: item for item in body["vlm"]}
    for name in TRANSFORMERS_VLM_MODELS:
        assert vlm_names[name]["available"] is False
        assert vlm_names[name]["revision"] is None
    for name in MLX_VLM_MODELS:
        assert vlm_names[name]["available"] is False
        assert "Apple-only" in vlm_names[name]["reason"]
    assert "qwen3-embedding" in body["recommended"]["devbox"]
    assert body["recommended"]["mac"] == ["granite-docling-mlx"]


def test_cached_model_is_available_and_download_stays_local(tmp_settings):
    def fake_download(repo_id, revision, on_progress, cancel_event):
        on_progress(25, "copying")

    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(),
        store=JobStore(),
        model_cache=lambda: (
            [{"repo_id": "ibm-granite/granite-docling-258M", "revision": "rev1", "size": 9}],
            None,
        ),
        model_server=lambda: ["ds4sd/SmolDocling-256M-preview"],
        ollama_tags=lambda: ([{"name": "qwen3-embedding:latest", "size": 4096, "digest": "abc", "parameter_size": "0.6B", "quantization": "Q8_0"}], None),
        downloader=fake_download,
    )
    with TestClient(app) as open_client:
        denied = open_client.post("/v1/models/download", json={"repo_id": "ibm-granite/granite-docling-258M"})
        assert denied.status_code == 401
    with TestClient(app, headers=auth_headers()) as client:
        granite = next(item for item in client.get("/v1/models").json()["vlm"] if item["name"] == "granite-docling-transformers")
        assert granite["available"] is True
        assert granite["revision"] == "rev1"
        assert granite["engine"] == "vllm"
        names = {item["name"] for item in client.get("/v1/models").json()["installed"]}
        assert "qwen3-embedding:latest" in names
        assert "ibm-granite/granite-docling-258M" in names
        started = client.post("/v1/models/download", json={"repo_id": "ibm-granite/granite-docling-258M"})
        assert started.status_code == 202
        assert started.json()["kind"] == "huggingface"
        ollama = client.post("/v1/models/download", json={"repo_id": "qwen3-embedding"})
        assert ollama.status_code == 202
        assert ollama.json()["kind"] == "ollama"
        job_id = started.json()["id"]
        record = None
        for _ in range(50):
            record = client.get(f"/v1/models/download/{job_id}").json()
            if record["status"] == "succeeded":
                break
        assert record["status"] == "succeeded"
        assert record["repo_id"] == "ibm-granite/granite-docling-258M"


def test_create_job_requires_file(client):
    response = client.post("/v1/jobs", data={"settings": "{}"})
    assert response.status_code == 422


def test_invalid_settings_json_is_400(client):
    response = client.post(
        "/v1/jobs",
        files={"file": ("a.txt", b"x", "text/plain")},
        data={"settings": "{not-json"},
    )
    assert response.status_code == 400
    assert "Invalid settings JSON" in response.json()["detail"]


def test_chunk_only_job_returns_artifacts(client, pipeline):
    response = _upload(client, filename="paper.txt", settings={"mode": "chunk_only"})
    assert response.status_code == 202
    job_id = response.json()["id"]
    assert response.json()["status"] == "queued"

    body = wait_for_status(client, job_id, "succeeded")
    assert body["filename"] == "paper.txt"
    result = body["result"]
    assert result["mode"] == "chunk_only"
    assert result["page_count"] == 2
    assert len(result["chunks"]) == 2
    assert result["chunks"][0]["text"] == "Hello world"
    assert result["embeddings"] is None
    assert result["output_file"]
    assert pipeline.calls
    assert pipeline.calls[0]["settings"].mode.value == "chunk_only"
    stages = {stage["name"]: stage for stage in result["metrics"]["stages"]}
    assert stages["ocr"]["status"] == "skipped"
    assert stages["embedding"]["status"] == "skipped"
    assert stages["convert_layout"]["status"] == "ok"
    assert result["metrics"]["host"] == "devbox"


def test_chunk_and_embed_uses_mock_backend(client, embeddings):
    response = _upload(
        client,
        filename="paper.txt",
        settings={"mode": "chunk_and_embed", "embedding_model": "qwen3-embedding"},
    )
    body = wait_for_status(client, response.json()["id"], "succeeded")
    result = body["result"]
    assert result["mode"] == "chunk_and_embed"
    assert result["embeddings"] == [[0.0, 0.1, 0.2], [1.0, 0.1, 0.2]]
    assert result["embedding_model"] == "qwen3-embedding"
    assert result["embedding_dim"] == 3
    assert len(embeddings.embed_calls) == 2
    assert embeddings.embed_calls[0][0] == ["chunky"]
    texts, model = embeddings.embed_calls[1]
    assert texts == ["Hello world", "Second chunk"]
    assert model == "qwen3-embedding"


def test_conversion_failure_marks_job_failed(tmp_settings, embeddings):
    from fastapi.testclient import TestClient

    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(fail=True, fail_message="broken pdf"),
        embeddings=embeddings,
        store=JobStore(),
    )
    with TestClient(app, headers=auth_headers()) as client:
        job_id = _upload(client).json()["id"]
        body = wait_for_status(client, job_id, "failed")
    assert body["error"] == "broken pdf"
    assert body["error_type"] == "conversion_error"
    assert body["result"] is None


def test_unknown_job_is_404(client):
    missing = "00000000-0000-0000-0000-000000000000"
    assert client.get(f"/v1/jobs/{missing}").status_code == 404
    assert client.post(f"/v1/jobs/{missing}/cancel").status_code == 404
    assert client.get(f"/v1/jobs/{missing}/events").status_code == 404


def test_cancel_running_job(tmp_settings, embeddings):
    from fastapi.testclient import TestClient

    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(delay=3.0),
        embeddings=embeddings,
        store=JobStore(),
    )
    with TestClient(app, headers=auth_headers()) as client:
        job_id = _upload(client).json()["id"]
        wait_for_status(client, job_id, "running", "queued")
        canceled = client.post(f"/v1/jobs/{job_id}/cancel")
        assert canceled.status_code == 200
        assert canceled.json()["status"] == "canceled"
        body = wait_for_status(client, job_id, "canceled")
        assert body["status"] == "canceled"


def test_cancel_after_success_is_conflict(client):
    job_id = _upload(client).json()["id"]
    wait_for_status(client, job_id, "succeeded")
    response = client.post(f"/v1/jobs/{job_id}/cancel")
    assert response.status_code == 409
    assert response.json()["status"] == "succeeded"


def test_sse_streams_progress_and_completion(client):
    job_id = _upload(client, settings={"mode": "chunk_only"}).json()["id"]
    events = []
    with client.stream("GET", f"/v1/jobs/{job_id}/events") as response:
        assert response.status_code == 200
        assert "text/event-stream" in response.headers["content-type"]
        for line in response.iter_lines():
            if not line or not line.startswith("data: "):
                continue
            events.append(json.loads(line[len("data: "):]))
    types = [event["type"] for event in events]
    assert "progress" in types
    assert types[-1] == "complete"
    assert events[-1]["status"] == "succeeded"
    assert any(event.get("percent") == 0 for event in events)
    assert any("Converting" in (event.get("message") or "") for event in events)


def test_job_settings_map_daemon_fields(client, pipeline):
    settings = {
        "mode": "chunk_only",
        "vlm_model": "granite-docling-transformers",
        "accelerator": "cuda",
        "chunk_max_tokens": 256,
        "enable_ocr": True,
    }
    job_id = _upload(client, settings=settings).json()["id"]
    wait_for_status(client, job_id, "succeeded")
    passed = pipeline.calls[0]["settings"]
    assert passed.vlm_model == "granite-docling-transformers"
    assert passed.accelerator == "cuda"
    assert passed.chunk_max_tokens == 256
    assert passed.enable_ocr is True
