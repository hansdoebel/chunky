from copy import deepcopy
from types import SimpleNamespace

import pytest
from qdrant_client import QdrantClient, models

from chunky_worker.app import create_app
from chunky_worker.document_summary import summary_payload
from chunky_worker.jobs import JobRunner, JobStore
from chunky_worker.models import JobSettings
from chunky_worker.qdrant_ingest import build_points, embedding_identity
from chunky_worker.search import QdrantPointSearcher
from fastapi.testclient import TestClient
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers

DOI = "10.1234/Exact.Case"


@pytest.mark.parametrize("enabled", [True, False])
@pytest.mark.parametrize("override", [None, "10.9999/imported"])
def test_ingest_summary_inherits_prepared_passage_doi(tmp_settings, enabled, override):
    settings = JobSettings(metadata_include_doi=enabled, bibliography_doi=override)
    chunks = [{"text": "Abstract text", "headings": ["Abstract"], "doi": DOI}]
    points = build_points(chunks=chunks, vectors=[[0.0, 0.1, 0.2]], source="paper.pdf", settings=settings, embedding_model="fixture")
    runner = JobRunner(JobStore(), tmp_settings, FakePipeline(), FakeEmbeddings())
    result = runner._with_summary_point(points, chunks=chunks, job=SimpleNamespace(settings=settings, filename="paper.pdf"), result=SimpleNamespace(doc_title="Paper", authors=None, year=None), model="fixture")
    assert result[-1].payload.get("doi") == ((override or DOI) if enabled else None)
    assert result[-1].payload.get("doi") == result[0].payload.get("doi")
    assert result[-1].payload["summary_metadata_version"] == 1
    assert len(result[-1].vector) == len(result[0].vector) == 3


def test_summary_without_doi_is_known_not_legacy():
    payload = summary_payload(text="abstract", kind="abstract", source="p", doc_title=None, authors=None, year=None, document_id=None)
    assert payload["summary_metadata_version"] == 1
    assert "doi" not in payload


class MemoryQdrant(QdrantClient):
    def close(self, **kwargs):
        pass

    def create_payload_index(self, **kwargs):
        raise AssertionError("Search must not mutate indexes")


@pytest.fixture
def paper_client(tmp_settings):
    db = MemoryQdrant(":memory:")
    identity = embedding_identity(backend=tmp_settings.embedding_backend, model=tmp_settings.embedding_model, endpoint=tmp_settings.ollama_url, dimensions=3, distance="cosine", hybrid=False)
    db.create_collection("papers", vectors_config=models.VectorParams(size=3, distance=models.Distance.COSINE), metadata={"chunky_embedding": identity})
    tmp_settings.qdrant_url = "http://localhost:6333"
    embeddings = FakeEmbeddings()
    app = create_app(settings=tmp_settings, pipeline=FakePipeline(), embeddings=embeddings, searcher=QdrantPointSearcher(lambda url, key: db), model_cache=lambda: ([], None), model_server=lambda: [], ollama_tags=lambda: ([], None))
    with TestClient(app, headers=auth_headers()) as client:
        yield db, client, embeddings
    QdrantClient.close(db)


def store(db, *payloads):
    db.upsert("papers", points=[models.PointStruct(id=i + 1, vector=[0.0, 0.1, 0.2], payload=p) for i, p in enumerate(payloads)])


def search(client, *, expand=False, doi=DOI, papers=True, model=None):
    return client.post("/v1/search", json={"collection": "papers", "query": "paper", "use_worker_qdrant": True, "papers_first": papers, "expand_documents": expand, "embedding_model": model, "filters": [{"key": "doi", "match": doi}, {"key": "library_id", "match": "wanted"}]})


@pytest.mark.parametrize("expand", [False, True])
def test_old_summary_with_matching_passage_fails_explicitly_without_mutation(paper_client, expand):
    db, client, embeddings = paper_client
    store(db, {"record_type": "document", "source": "p", "library_id": "wanted"}, {"source": "p", "doi": DOI, "library_id": "wanted"})
    before = deepcopy(db.scroll("papers", with_vectors=True)[0])
    response = search(client, expand=expand)
    assert response.status_code == 409
    assert "summary_doi_coverage_incomplete" in response.text
    assert embeddings.embed_calls == []
    assert db.scroll("papers", with_vectors=True)[0] == before
    passages = search(client, papers=False)
    assert passages.status_code == 200
    assert [p["id"] for p in passages.json()["results"]] == ["2"]


@pytest.mark.parametrize("expand", [False, True])
def test_exact_doi_with_known_absence_and_other_library_legacy(paper_client, expand):
    db, client, _ = paper_client
    store(db,
          {"record_type": "document", "source": "p", "doi": DOI, "library_id": "wanted", "summary_metadata_version": 1},
          {"source": "p", "doi": DOI, "library_id": "wanted"},
          {"record_type": "document", "source": "unknown", "library_id": "wanted", "summary_metadata_version": 1},
          {"record_type": "document", "source": "old", "library_id": "other"})
    response = search(client, expand=expand)
    assert response.status_code == 200, response.text
    assert [p["id"] for p in response.json()["results"]] == (["1", "2"] if expand else ["1"])
    assert search(client, expand=expand, doi=DOI.lower()).json()["results"] == []
    assert search(client, expand=expand, doi="https://doi.org/" + DOI).json()["results"] == []
    mismatch = search(client, expand=expand, model="other-model")
    assert mismatch.status_code == 409
    assert "embedding_identity_mismatch" in mismatch.text


def test_legacy_summary_with_explicit_doi_remains_searchable(paper_client):
    db, client, _ = paper_client
    store(db, {"record_type": "document", "source": "p", "doi": DOI, "library_id": "wanted"})
    response = search(client)
    assert response.status_code == 200, response.text
    assert [p["id"] for p in response.json()["results"]] == ["1"]


def test_coverage_keeps_other_document_filters(paper_client):
    db, client, _ = paper_client
    store(db,
          {"record_type": "document", "source": "p", "doi": DOI, "library_id": "wanted", "year": 2024},
          {"record_type": "document", "source": "old", "library_id": "wanted", "year": 1999})
    response = client.post("/v1/search", json={"collection": "papers", "query": "paper", "use_worker_qdrant": True, "papers_first": True, "filters": [{"key": "doi", "match": DOI}, {"key": "library_id", "match": "wanted"}, {"key": "year", "gte": 2020}]})
    assert response.status_code == 200, response.text
    assert [p["id"] for p in response.json()["results"]] == ["1"]


def test_doi_paper_search_preserves_dimension_guard(paper_client):
    db, client, embeddings = paper_client
    store(db, {"record_type": "document", "source": "p", "doi": DOI, "library_id": "wanted"})
    embeddings.embed = lambda texts, model: [[1.0, 2.0]]
    response = search(client)
    assert response.status_code == 409
    assert "dimension_mismatch" in response.text


def test_failed_coverage_lookup_never_reports_no_matches(paper_client):
    db, client, embeddings = paper_client
    db.scroll = lambda **kwargs: (_ for _ in ()).throw(RuntimeError("coverage unavailable"))
    response = search(client)
    assert response.status_code == 502
    assert "qdrant_error" in response.text
    assert "results" not in response.json()
    assert embeddings.embed_calls == []


@pytest.mark.parametrize("expand", [False, True])
@pytest.mark.parametrize("library", ["wanted", "other"])
def test_doi_or_year_coverage_does_not_require_other_alternative(paper_client, expand, library):
    db, client, embeddings = paper_client
    store(db,
          {"record_type": "document", "source": "old", "library_id": library, "year": 1999},
          {"source": "old", "doi": DOI, "library_id": library, "year": 1999})
    before = deepcopy(db.scroll("papers", with_vectors=True)[0])
    response = client.post("/v1/search", json={"collection": "papers", "query": "paper", "use_worker_qdrant": True, "papers_first": True, "expand_documents": expand, "filters": [{"key": "doi", "match": DOI, "should": True}, {"key": "year", "match": 2024, "should": True}, {"key": "library_id", "match": "wanted"}]})
    if library == "wanted":
        assert response.status_code == 409
        assert "summary_doi_coverage_incomplete" in response.text
        assert embeddings.embed_calls == []
    else:
        assert response.status_code == 200, response.text
        assert response.json()["results"] == []
    after = db.scroll("papers", with_vectors=True)[0]
    assert [(p.id, p.payload) for p in after] == [(p.id, p.payload) for p in before]
    for actual, original in zip(after, before):
        assert actual.vector == pytest.approx(original.vector)
