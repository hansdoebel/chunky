"""Qdrant ingest targets. qdrant-client is mocked; the API key must not leak."""

from __future__ import annotations

import json

from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.jobs import JobStore
from chunky_worker.models import JobSettings
from chunky_worker.qdrant_ingest import (
    DimensionMismatch,
    PreparedPoint,
    QdrantCloudIngestor,
    build_points,
    INTEGER_PAYLOAD_INDEXES,
    KEYWORD_PAYLOAD_INDEXES,
    TEXT_PAYLOAD_INDEXES,
    content_hash,
    sparse_vectors,
)
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers, wait_for_status

API_KEY = "super-secret-cloud-key"

def _upload(client, settings):
    return client.post(
        "/v1/jobs",
        files={"file": ("paper.txt", b"hello", "text/plain")},
        data={"settings": json.dumps(settings)},
    )

class RecordingIngestor:
    def __init__(self, fail_message: str | None = None, existing_size: int | None = None) -> None:
        self.fail_message = fail_message
        self.existing_size = existing_size
        self.calls: list[dict] = []
        self.size_calls = 0

    def collection_vector_size(self, *, url: str, api_key: str, collection: str) -> int | None:
        self.size_calls += 1
        return self.existing_size

    def upsert_cloud(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail_message:
            raise RuntimeError(self.fail_message)
        return len(kwargs["points"])

def test_payload_matches_mac_field_names():
    settings = JobSettings()
    chunks = [
        {
            "text": "Hello world",
            "embedding_text": "Hello world",
            "page": 3,
            "page_end": 4,
            "pages": [3, 4],
            "bboxes": [{"page": 3, "l": 0, "t": 1, "r": 2, "b": 3}],
            "headings": ["Intro"],
            "content_type": "text",
            "chunk_index": 0,
            "section": "Intro",
        }
    ]
    points = build_points(
        chunks,
        [[0.1, 0.2]],
        source="paper.txt",
        settings=settings,
        embedding_model="qwen3-embedding",
        doc_title="Fixture Doc",
        authors=["Ada", "Bea"],
        language="en",
        year=2024,
        ingested_at="2026-11-15T00:00:00Z",
    )
    payload = points[0].payload
    assert payload["text"] == "Hello world"
    assert payload["source"] == "paper.txt"
    assert payload["page"] == 3
    assert payload["page_end"] == 4
    assert payload["pages"] == [3, 4]
    assert payload["bboxes"][0]["page"] == 3
    assert payload["year"] == 2024
    assert payload["headings"] == ["Intro"]
    assert payload["chunk_index"] == "0"
    assert payload["content_type"] == "text"
    assert payload["section"] == "Intro"
    assert payload["doc_title"] == "Fixture Doc"
    assert payload["authors"] == "Ada; Bea"
    assert payload["language"] == "en"
    assert payload["ingested_at"] == "2026-11-15T00:00:00Z"
    assert payload["content_hash"] == content_hash("Hello world", "qwen3-embedding")
    assert payload["embedding_text"] == "Hello world"
    assert "source_path" not in payload
    assert "picture_description" not in payload
    assert "picture_class" not in payload
    assert "table_markdown" not in payload
    assert isinstance(payload["page"], int)
    assert "page" in INTEGER_PAYLOAD_INDEXES
    assert "page_end" in INTEGER_PAYLOAD_INDEXES
    assert "year" in INTEGER_PAYLOAD_INDEXES
    assert "headings" in TEXT_PAYLOAD_INDEXES
    assert "doc_title" in TEXT_PAYLOAD_INDEXES
    assert "authors" in TEXT_PAYLOAD_INDEXES
    assert "doc_title" not in KEYWORD_PAYLOAD_INDEXES
    assert "content_type" in KEYWORD_PAYLOAD_INDEXES
    assert "content_types" in KEYWORD_PAYLOAD_INDEXES
    assert "doi" in KEYWORD_PAYLOAD_INDEXES
    assert isinstance(payload["chunk_index"], str)


def test_source_path_is_stored_when_the_local_file_is_known():
    settings = JobSettings(source_path="/Users/me/papers/paper.pdf")
    points = build_points(
        [{"text": "Hello", "embedding_text": "Hello", "page": 1}],
        [[0.1, 0.2]],
        source="paper.pdf",
        settings=settings,
        embedding_model="qwen3-embedding",
    )
    assert points[0].payload["source_path"] == "/Users/me/papers/paper.pdf"
    assert points[0].payload["source"] == "paper.pdf"


def test_bibliography_metadata_wins_over_docling_fields():
    settings = JobSettings(
        bibliography_title="Ground Truth",
        bibliography_authors=["Ada Lovelace"],
        bibliography_year=2020,
        bibliography_doi="10.1000/xyz",
        bibliography_venue="Nature",
        bibliography_abstract="A short abstract.",
        bibliography_cite_key="lovelace2020",
        bibliography_source="bibtex",
    )
    points = build_points(
        [{"text": "Hello", "embedding_text": "Hello", "page": 1}],
        [[0.1, 0.2]],
        source="paper.pdf",
        settings=settings,
        embedding_model="qwen3-embedding",
        doc_title="Weak PDF Title",
        authors=["Nobody"],
        year=1999,
    )
    payload = points[0].payload
    assert payload["doc_title"] == "Ground Truth"
    assert payload["authors"] == "Ada Lovelace"
    assert payload["year"] == 2020
    assert payload["doi"] == "10.1000/xyz"
    assert payload["venue"] == "Nature"
    assert payload["abstract"] == "A short abstract."
    assert payload["cite_key"] == "lovelace2020"
    assert payload["metadata_source"] == "bibtex"


def test_picture_and_table_payloads_keep_serialized_text():
    settings = JobSettings()
    picture = {
        "text": "Figure 1",
        "embedding_text": "Figure 1\nA bar chart of revenue.",
        "content_type": "picture",
        "picture_description": "A bar chart of revenue.",
        "picture_class": "bar_chart",
    }
    table = {
        "text": "Year Revenue",
        "embedding_text": "Year Revenue\n| Year | Revenue |",
        "content_type": "table",
        "table_markdown": "| Year | Revenue |\n| --- | --- |\n| 2024 | 10 |",
    }
    points = build_points(
        [picture, table],
        [[0.1, 0.2], [0.3, 0.4]],
        source="paper.pdf",
        settings=settings,
        embedding_model="qwen3-embedding",
    )
    picture_payload, table_payload = (point.payload for point in points)
    assert picture_payload["text"] == "Figure 1\nA bar chart of revenue."
    assert picture_payload["embedding_text"] == picture_payload["text"]
    assert picture_payload["content_type"] == "figure"
    assert picture_payload["content_types"] == ["figure"]
    assert picture_payload["picture_description"] == "A bar chart of revenue."
    assert picture_payload["picture_class"] == "bar_chart"
    assert "table_markdown" not in picture_payload
    assert table_payload["text"] == "Year Revenue\n| Year | Revenue |"
    assert table_payload["embedding_text"] == table_payload["text"]
    assert table_payload["content_type"] == "table"
    assert table_payload["table_markdown"].startswith("| Year | Revenue |")
    assert "picture_description" not in table_payload
    assert "picture_class" not in table_payload


def test_missing_content_type_is_left_off_the_payload():
    settings = JobSettings()
    points = build_points(
        [{"text": "Hello", "embedding_text": "Hello"}],
        [[0.1, 0.2]],
        source="paper.pdf",
        settings=settings,
        embedding_model="qwen3-embedding",
    )
    assert "content_type" not in points[0].payload
    assert "content_types" not in points[0].payload


def test_disabled_metadata_flags_omit_fields():
    settings = JobSettings(
        metadata_include_page=False,
        metadata_include_headings=False,
        metadata_include_content_hash=False,
        metadata_include_doc_title=False,
    )
    points = build_points(
        [{"text": "x", "page": 1, "headings": ["H"], "chunk_index": 1}],
        [[1.0]],
        source="a.txt",
        settings=settings,
        embedding_model="m",
        doc_title="Title",
        ingested_at="t",
    )
    payload = points[0].payload
    assert "page" not in payload
    assert "headings" not in payload
    assert "content_hash" not in payload
    assert "doc_title" not in payload
    assert payload["text"] == "x"
    assert payload["source"] == "a.txt"

def test_return_vectors_includes_chunks_and_vectors(tmp_settings, pipeline, embeddings):
    ingestor = RecordingIngestor()
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        ingestor=ingestor,
    )
    with TestClient(app, headers=auth_headers()) as client:
        response = _upload(client, {"mode": "chunk_only", "ingest_target": "return_vectors"})
        body = wait_for_status(client, response.json()["id"], "succeeded")
    result = body["result"]
    assert result["embeddings"] == [[0.0, 0.1, 0.2], [1.0, 0.1, 0.2]]
    assert len(result["chunks"]) == 2
    assert result["ingest"]["target"] == "return_vectors"
    assert result["embedding_dim"] == 3
    assert ingestor.calls == []

def test_qdrant_cloud_upserts_and_hides_key_and_vectors(tmp_settings, pipeline, embeddings):
    ingestor = RecordingIngestor()
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        ingestor=ingestor,
    )
    with TestClient(app, headers=auth_headers()) as client:
        response = _upload(
            client,
            {
                "mode": "chunk_and_embed",
                "ingest_target": "qdrant_cloud",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": API_KEY,
                "qdrant_collection": "documents",
                "qdrant_distance": "Cosine",
                "qdrant_batch_size": 1,
            },
        )
        job_id = response.json()["id"]
        body = wait_for_status(client, job_id, "succeeded")
        raw = client.get(f"/v1/jobs/{job_id}").text
    assert API_KEY not in raw
    assert "qdrant_api_key" not in raw
    result = body["result"]
    assert result["embeddings"] is None
    assert result["metrics"]["embeddings_per_s"] is not None
    assert result["metrics"]["embeddings_per_s"] > 0
    assert result["ingest"]["target"] == "qdrant_cloud"
    assert result["ingest"]["upserted"] == 3
    assert result["ingest"]["collection"] == "documents"
    assert result["ingest"]["vector_size"] == 3
    assert result["ingest"]["distance"] == "cosine"
    assert len(ingestor.calls) == 1
    call = ingestor.calls[0]
    assert call["api_key"] == API_KEY
    assert call["url"] == "https://example.cloud.qdrant.io"
    assert call["batch_size"] == 1
    assert call["vector_size"] == 3
    assert call["points"][0].payload["text"] == "Hello world"
    assert call["points"][0].payload["doc_title"] == "Fixture Doc"
    assert call["points"][-1].payload["record_type"] == "document"
    assert call["points"][-1].payload["summary_kind"] in {"abstract", "extract", "generated"}
    log_text = (tmp_settings.log_dir / "chunky-worker.log").read_text(encoding="utf-8")
    assert API_KEY not in log_text

def test_dimension_mismatch_fails_before_upsert(tmp_settings, pipeline, embeddings):
    ingestor = RecordingIngestor(existing_size=1024)
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        ingestor=ingestor,
    )
    with TestClient(app, headers=auth_headers()) as client:
        response = _upload(
            client,
            {
                "ingest_target": "qdrant_cloud",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": API_KEY,
                "qdrant_collection": "documents",
                "embedding_model": "qwen3-embedding",
            },
        )
        body = wait_for_status(client, response.json()["id"], "failed")
    assert body["error_type"] == "dimension_mismatch"
    assert "vector size 1024" in body["error"]
    assert "size 3" in body["error"]
    assert API_KEY not in body["error"]
    assert ingestor.calls == []

    assert embeddings.embed_calls == [(["chunky"], "qwen3-embedding")]

def test_cloud_failure_redacts_key(tmp_settings, pipeline, embeddings):
    ingestor = RecordingIngestor(fail_message=f"upstream rejected {API_KEY}")
    app = create_app(
        settings=tmp_settings,
        pipeline=pipeline,
        embeddings=embeddings,
        store=JobStore(),
        ingestor=ingestor,
    )
    with TestClient(app, headers=auth_headers()) as client:
        response = _upload(
            client,
            {
                "ingest_target": "qdrant_cloud",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": API_KEY,
            },
        )
        body = wait_for_status(client, response.json()["id"], "failed")
    assert body["error_type"] == "exception"
    assert API_KEY not in body["error"]
    assert "[redacted]" in body["error"]
    log_text = (tmp_settings.log_dir / "chunky-worker.log").read_text(encoding="utf-8")
    assert API_KEY not in log_text

def test_sparse_vectors_follow_term_frequency():
    rows = sparse_vectors(["alpha beta", "alpha alpha"])
    assert rows[0][0]
    assert rows[1][0]
    assert len(rows[0][0]) == len(rows[0][1])

def test_hybrid_create_uses_named_vectors_and_quantization(monkeypatch):
    created: dict = {}

    class FakeClient:
        def __init__(self, **kwargs):
            pass

        def collection_exists(self, collection_name):
            return False

        def create_collection(self, **kwargs):
            created["create"] = kwargs

        def upsert(self, **kwargs):
            created["upsert"] = kwargs

        def create_payload_index(self, **kwargs):
            created.setdefault("indexes", []).append(kwargs)

        def close(self):
            pass

    monkeypatch.setattr("qdrant_client.QdrantClient", FakeClient)
    written = QdrantCloudIngestor().upsert_cloud(
        url="https://example.cloud.qdrant.io",
        api_key=API_KEY,
        collection="docs",
        points=[PreparedPoint(id="00000000-0000-0000-0000-000000000001", vector=[0.1, 0.2], payload={"text": "alpha beta"})],
        vector_size=2,
        distance="cosine",
        batch_size=10,
        hybrid=True,
        quantization="scalar",
        on_disk=True,
    )
    assert written == 1
    create = created["create"]
    assert create["vectors_config"]["dense"].size == 2
    assert create["vectors_config"]["dense"].on_disk is True
    assert "sparse_vectors_config" not in create
    assert create["on_disk_payload"] is True
    assert create["quantization_config"] is not None
    point = created["upsert"]["points"][0]
    assert point.vector == {"dense": [0.1, 0.2]}
    bm25 = next(item for item in created["indexes"] if item["field_name"] == "embedding_text" and getattr(item["field_schema"], "scoring", None))
    assert bm25["field_schema"].scoring.type.value == "bm25"


def test_memory_tiers_are_set_on_create_and_update(monkeypatch):
    created: dict = {}

    class FakeClient:
        def __init__(self, **kwargs):
            pass

        def collection_exists(self, collection_name):
            return False

        def create_collection(self, **kwargs):
            created["create"] = kwargs

        def update_collection(self, **kwargs):
            created["update"] = kwargs

        def upsert(self, **kwargs):
            pass

        def create_payload_index(self, **kwargs):
            pass

        def close(self):
            pass

    monkeypatch.setattr("qdrant_client.QdrantClient", FakeClient)
    QdrantCloudIngestor().upsert_cloud(
        url="https://example.cloud.qdrant.io",
        api_key=API_KEY,
        collection="docs",
        points=[PreparedPoint(id="00000000-0000-0000-0000-000000000001", vector=[0.1, 0.2], payload={"text": "alpha"})],
        vector_size=2,
        distance="cosine",
        batch_size=10,
        hybrid=True,
        quantization="scalar",
        on_disk=True,
        vector_memory="cold",
        hnsw_memory="cold",
        quantization_memory="pinned",
        payload_memory="cold",
    )
    dense = created["create"]["vectors_config"]["dense"]
    assert dense.memory == "cold"
    assert created["create"]["hnsw_config"].memory == "cold"
    assert created["create"]["payload"].memory == "cold"
    assert created["create"]["quantization_config"].scalar.memory == "pinned"
    updated = created["update"]["vectors_config"]["dense"]
    assert updated.memory == "cold"
    assert created["update"]["collection_params"].payload.memory == "cold"

def test_cloud_client_creates_collection_and_batches(monkeypatch):
    created: dict = {}

    class FakeClient:
        def __init__(self, **kwargs):
            created["init"] = kwargs

        def collection_exists(self, collection_name):
            created["exists_name"] = collection_name
            return False

        def create_collection(self, **kwargs):
            created["create"] = kwargs

        def upsert(self, **kwargs):
            created.setdefault("upserts", []).append(kwargs)

        def create_payload_index(self, **kwargs):
            created.setdefault("indexes", []).append(kwargs)

        def close(self):
            created["closed"] = True

    monkeypatch.setattr("qdrant_client.QdrantClient", FakeClient)
    points = [
        PreparedPoint(id=f"00000000-0000-0000-0000-00000000000{i}", vector=[float(i), 0.5], payload={"text": "t"})
        for i in range(3)
    ]
    ingestor = QdrantCloudIngestor()
    written = ingestor.upsert_cloud(
        url="https://example.cloud.qdrant.io",
        api_key=API_KEY,
        collection="documents",
        points=points,
        vector_size=2,
        distance="cosine",
        batch_size=2,
    )
    assert written == 3
    assert created["init"]["api_key"] == API_KEY
    assert created["create"]["collection_name"] == "documents"
    assert created["create"]["vectors_config"].size == 2
    assert len(created["upserts"]) == 2
    assert len(created["upserts"][0]["points"]) == 2
    assert len(created["upserts"][1]["points"]) == 1
    assert created["closed"] is True
    indexed = {call["field_name"]: call["field_schema"] for call in created["indexes"]}
    assert indexed["picture_class"].value == "keyword"
    assert indexed["picture_description"].value == "text"
    assert indexed["table_markdown"].value == "text"
    assert indexed["embedding_text"].value == "text"
    assert API_KEY not in repr(vars(ingestor))

def test_existing_collection_dimension_mismatch(monkeypatch):
    class Vectors:
        size = 4

    class Params:
        vectors = Vectors()

    class Config:
        params = Params()

    class Info:
        config = Config()

    class FakeClient:
        def __init__(self, **kwargs):
            pass

        def collection_exists(self, collection_name):
            return True

        def get_collection(self, collection_name):
            return Info()

        def close(self):
            pass

    monkeypatch.setattr("qdrant_client.QdrantClient", FakeClient)
    ingestor = QdrantCloudIngestor()
    try:
        ingestor.upsert_cloud(
            url="https://example.cloud.qdrant.io",
            api_key=API_KEY,
            collection="documents",
            points=[PreparedPoint(id="00000000-0000-0000-0000-000000000001", vector=[1.0, 2.0], payload={})],
            vector_size=2,
            distance="euclid",
            batch_size=10,
        )
    except DimensionMismatch as exc:
        assert exc.error_type == "dimension_mismatch"
        assert "vector size 4" in str(exc)
        assert "size 2" in str(exc)
        assert API_KEY not in str(exc)
    else:
        raise AssertionError("expected DimensionMismatch")

def test_named_dense_vector_size_is_read(monkeypatch):
    class Named:
        def __init__(self, size):
            self.size = size

    class Params:
        vectors = {"dense": Named(8), "other": Named(3)}

    class Config:
        params = Params()

    class Info:
        config = Config()

    class FakeClient:
        def __init__(self, **kwargs):
            self.created = False

        def collection_exists(self, collection_name):
            return True

        def get_collection(self, collection_name):
            return Info()

        def upsert(self, **kwargs):
            return None

        def create_payload_index(self, **kwargs):
            return None

        def close(self):
            pass

    monkeypatch.setattr("qdrant_client.QdrantClient", FakeClient)
    written = QdrantCloudIngestor().upsert_cloud(
        url="https://example.cloud.qdrant.io",
        api_key=API_KEY,
        collection="documents",
        points=[PreparedPoint(id="00000000-0000-0000-0000-000000000001", vector=[0.0] * 8, payload={"text": "t"})],
        vector_size=8,
        distance="dot",
        batch_size=10,
    )
    assert written == 1
