import json

import pytest
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.jobs import JobStore
from chunky_worker.models import JobMode, JobResult, JobSettings
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers


def report_app(settings, store):
    return create_app(settings=settings, store=store, pipeline=FakePipeline(), embeddings=FakeEmbeddings())


@pytest.mark.parametrize("job_key,server_key", [("job-secret", "server-secret"), ('quote"key', "back\\slash"), (":", "id"), ("prefix", "prefix-secret")])
def test_verification_get_redacts_job_and_server_keys_without_mutating_report(tmp_settings, job_key, server_key):
    store = JobStore()
    job = store.create("fixture.pdf", JobSettings(qdrant_api_key=job_key))
    tmp_settings.qdrant_api_key = server_key
    path = tmp_settings.work_dir / job.id / "verification.json"
    path.parent.mkdir(parents=True)
    original = {"status": "yellow", "id": "schema retained", "pages": [{"page": 1, "status": "yellow", "flags": [job_key, server_key]}], "store": {"error": f"Failure with {server_key}"}, "count": 0, "matched": False, "empty": None}
    path.write_text(json.dumps(original))
    with TestClient(report_app(tmp_settings, store)) as client:
        assert client.get(f"/v1/jobs/{job.id}/verification").status_code == 401
        response = client.get(f"/v1/jobs/{job.id}/verification", headers=auth_headers())
        assert response.status_code == 200
        report = response.json()
        assert set(report) == set(original)
        assert report["pages"][0]["flags"] == ["[redacted]", "[redacted]"]
        assert report["store"]["error"] == "Failure with [redacted]"
        assert report["count"] == 0 and report["matched"] is False and report["empty"] is None
    assert json.loads(path.read_text()) == original


def test_verification_get_does_not_copy_job_vectors(tmp_settings):
    class UncopyableVectors(list):
        def __deepcopy__(self, memo):
            raise AssertionError("Verification report copied vectors")

    store = JobStore()
    job = store.create("fixture.pdf", JobSettings())
    job.result = JobResult(mode=JobMode.CHUNK_AND_EMBED)
    vectors = UncopyableVectors([[1.0, 2.0, 3.0]])
    job.result.embeddings = vectors
    path = tmp_settings.work_dir / job.id / "verification.json"
    path.parent.mkdir(parents=True)
    path.write_text('{"status":"green","pages":[]}')
    with TestClient(report_app(tmp_settings, store), headers=auth_headers()) as client:
        assert client.get(f"/v1/jobs/{job.id}/verification").json() == {"status": "green", "pages": []}
    assert job.result.embeddings is vectors


@pytest.mark.parametrize("content", ["not json", "[]"])
def test_verification_get_handles_missing_and_invalid_reports(tmp_settings, content):
    store = JobStore()
    job = store.create("fixture.pdf", JobSettings())
    path = tmp_settings.work_dir / job.id / "verification.json"
    with TestClient(report_app(tmp_settings, store), headers=auth_headers()) as client:
        assert client.get("/v1/jobs/unknown/verification").status_code == 404
        assert client.get(f"/v1/jobs/{job.id}/verification").status_code == 404
        path.parent.mkdir(parents=True)
        path.write_text(content)
        response = client.get(f"/v1/jobs/{job.id}/verification")
        assert response.status_code == 500
        assert "Verification report" in response.json()["detail"]
