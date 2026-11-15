"""Verification runs after a job and from the re-verify routes. Qdrant stays mocked."""

from __future__ import annotations

import json
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.jobs import JobStore
from chunky_worker.qdrant_ingest import content_hash
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status
from tests.test_qdrant_ingest import RecordingIngestor, _upload
from tests.test_verification import _pdf

SECRET = "super-secret-cloud-key"


def test_succeeded_job_writes_a_report_next_to_the_upload(client, tmp_settings):
    response = client.post(
        "/v1/jobs",
        files={"file": ("paper.txt", b"hello", "text/plain")},
        data={"settings": json.dumps({"mode": "chunk_only"})},
    )
    job_id = response.json()["id"]
    body = wait_for_status(client, job_id, "succeeded")
    assert body["result"]["verification_status"] == "green"
    report = client.get(f"/v1/jobs/{job_id}/verification")
    assert report.status_code == 200
    payload = report.json()
    assert payload["status"] == "green"
    assert payload["chunk_source"] == "job"
    assert payload["text"]["note"] == "not a pdf"
    raw = report.text
    assert "Hello world" not in raw
    assert "embedding_text" not in raw
    stored = tmp_settings.work_dir / job_id / "verification.json"
    assert stored.is_file()
    names = [path.name for path in (tmp_settings.work_dir / job_id).rglob("*") if path.is_file()]
    assert "verification.json" in names
    assert "chunks.json" not in names


def test_reverify_uses_the_store_and_hides_the_api_key(tmp_settings, pipeline, embeddings):
    class Store(RecordingIngestor):
        def fetch_points(self, *, url, api_key, collection, ids):
            self.seen = {"url": url, "api_key": api_key, "ids": list(ids)}
            points = []
            for index, chunk_id in enumerate(ids):
                text = "Hello world" if index == 0 else "Second chunk"
                points.append(
                    {
                        "id": chunk_id,
                        "vector": [float(index), 0.1, 0.2],
                        "payload": {
                            "text": text,
                            "source": "paper.txt",
                            "content_hash": content_hash(text, "qwen3-embedding"),
                            "page": index + 1,
                        },
                    }
                )
            return points

    ingestor = Store()
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        ingestor=ingestor,
    )
    with TestClient(app, headers=auth_headers()) as client:
        created = _upload(
            client,
            {
                "mode": "chunk_and_embed",
                "ingest_target": "qdrant_cloud",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": SECRET,
                "qdrant_collection": "documents",
            },
        )
        job_id = created.json()["id"]
        body = wait_for_status(client, job_id, "succeeded")
        assert body["result"]["verification_status"] == "green"
        assert SECRET not in client.get(f"/v1/jobs/{job_id}").text
        again = client.post(
            f"/v1/jobs/{job_id}/verify",
            json={
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": SECRET,
                "qdrant_collection": "documents",
            },
        )
        assert again.status_code == 200
        assert SECRET not in again.text
        assert again.json()["store"]["status"] == "green"
    assert ingestor.seen["api_key"] == SECRET
    log_text = (tmp_settings.log_dir / "chunky-worker.log").read_text(encoding="utf-8")
    assert SECRET not in log_text


def test_verify_upload_reads_the_cache_and_does_not_keep_the_pdf(tmp_settings, monkeypatch):
    import sys

    cached = [
        {
            "id": "cached",
            "text": "Hello page",
            "embedding_text": "Hello page",
            "page": 1,
            "chunk_index": 0,
        }
    ]
    monkeypatch.setitem(
        sys.modules,
        "chunky_worker.chunk_cache",
        type("Cache", (), {"chunks_for_pdf_hash": staticmethod(lambda _digest: cached)})(),
    )
    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(),
        store=JobStore(),
    )
    pdf = tmp_settings.work_dir / "hello.pdf"
    pdf.parent.mkdir(parents=True, exist_ok=True)
    _pdf(pdf)
    with TestClient(app, headers=auth_headers()) as client:
        response = client.post(
            "/v1/verify",
            files={"file": ("hello.pdf", pdf.read_bytes(), "application/pdf")},
            data={"settings": "{}"},
        )
    assert response.status_code == 200
    assert response.json()["chunk_source"] == "cache"
    assert "Hello page" not in response.text
    upload_dir = tmp_settings.work_dir / "verification-upload"
    assert not upload_dir.exists() or not any(upload_dir.iterdir())
    reports = list((tmp_settings.work_dir / "verification").glob("*.json"))
    assert len(reports) == 1
    assert "embedding_text" not in reports[0].read_text(encoding="utf-8")


def test_verify_upload_without_chunks_or_cache_is_400(tmp_settings):
    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(),
        store=JobStore(),
    )
    with TestClient(app, headers=auth_headers()) as client:
        response = client.post(
            "/v1/verify",
            files={"file": ("empty.pdf", b"%PDF", "application/pdf")},
            data={"settings": "{}"},
        )
    assert response.status_code == 400


def test_verification_routes_require_auth_and_a_finished_job(client):
    bare = TestClient(client.app)
    assert bare.get("/v1/jobs/missing/verification").status_code == 401
    assert client.get("/v1/jobs/missing/verification").status_code == 404
    assert client.post("/v1/jobs/missing/verify", json={}).status_code == 404
