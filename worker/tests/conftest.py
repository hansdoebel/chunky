"""Shared fixtures: a FastAPI test client with mocked Docling and Ollama."""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.exceptions import JobCanceled
from chunky_worker.jobs import JobStore
from chunky_worker.models import JobMode, JobSettings
from chunky_worker.settings import Settings

class FakePipeline:
    def __init__(self, delay: float = 0.0, fail: bool = False, fail_message: str = "boom") -> None:
        self.delay = delay
        self.fail = fail
        self.fail_message = fail_message
        self.calls: list[dict] = []

    def convert_and_chunk(self, input_path, output_dir, settings, on_progress, cancel_event):
        self.calls.append(
            {
                "input_path": Path(input_path),
                "output_dir": Path(output_dir),
                "settings": settings,
            }
        )
        on_progress("Initializing converter...", 0)
        if self.delay:
            deadline = time.monotonic() + self.delay
            while time.monotonic() < deadline:
                if cancel_event.is_set():
                    raise JobCanceled()
                time.sleep(0.02)
        if cancel_event.is_set():
            raise JobCanceled()
        on_progress("Converting document...", 10)
        if self.fail:
            return {"success": False, "error": self.fail_message, "error_type": "conversion_error"}
        on_progress("Chunking document...", 88)
        output_file = Path(output_dir) / f"{Path(input_path).stem}.json"
        output_file.write_text("{}", encoding="utf-8")
        on_progress("Conversion complete", 100)
        return {
            "success": True,
            "input_file": str(input_path),
            "output_file": str(output_file),
            "output_format": settings.format,
            "page_count": 2,
            "text_items_count": 4,
            "table_count": 0,
            "doc_title": "Fixture Doc",
            "authors": None,
            "language": "en",
            "year": 2024,
            "chunks": [
                {
                    "text": "Hello world",
                    "embedding_text": "Hello world",
                    "page": 1,
                    "headings": ["Intro"],
                    "content_type": "text",
                    "chunk_index": 0,
                    "token_count": 2,
                },
                {
                    "text": "Second chunk",
                    "embedding_text": "Second chunk",
                    "page": 2,
                    "headings": [],
                    "content_type": "text",
                    "chunk_index": 1,
                    "token_count": 2,
                },
            ],
        }

class FakeEmbeddings:
    def __init__(self, reachable: bool = True, models: list[str] | None = None) -> None:
        self.reachable = reachable
        self.models = models if models is not None else ["qwen3-embedding"]
        self.embed_calls: list[tuple[list[str], str]] = []

    def health(self):
        if self.reachable:
            return True, None
        return False, "connection refused"

    def list_models(self):
        if not self.reachable:
            return [], "connection refused"
        return list(self.models), None

    def embed(self, texts, model):
        self.embed_calls.append((list(texts), model))
        return [[float(i), 0.1, 0.2] for i, _ in enumerate(texts)]

TEST_TOKEN = "test-token"

def auth_headers(token: str = TEST_TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}

@pytest.fixture
def tmp_settings(tmp_path: Path) -> Settings:
    return Settings(
        host="127.0.0.1",
        port=8080,
        log_dir=tmp_path / "logs",
        work_dir=tmp_path / "work",
        cache_dir=tmp_path / "cache",
        scripts_dir=tmp_path / "scripts",
        ollama_url="http://127.0.0.1:11434",
        vllm_url="http://127.0.0.1:8000",
        embedding_model="qwen3-embedding",
        token=TEST_TOKEN,
    )

@pytest.fixture
def pipeline() -> FakePipeline:
    return FakePipeline()

@pytest.fixture
def embeddings() -> FakeEmbeddings:
    return FakeEmbeddings()

@pytest.fixture
def client(tmp_settings, pipeline, embeddings):
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        model_cache=lambda: ([], None),
        model_server=lambda: [],
        ollama_tags=lambda: ([], None),
    )
    with TestClient(app, headers=auth_headers(tmp_settings.token or "")) as test_client:
        yield test_client

def wait_for_status(client: TestClient, job_id: str, *statuses: str, timeout: float = 5.0) -> dict:
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        response = client.get(f"/v1/jobs/{job_id}")
        assert response.status_code == 200
        last = response.json()
        if last["status"] in statuses:
            return last
        time.sleep(0.02)
    raise AssertionError(f"job {job_id} did not reach {statuses}; last={last}")
