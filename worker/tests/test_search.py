"""POST /v1/search. The embed server and Qdrant are both mocked."""

from __future__ import annotations

import httpx
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.embeddings import OllamaEmbeddingBackend, OpenAIEmbeddingBackend
from chunky_worker.jobs import JobStore
from chunky_worker.search import (
    MAX_LIMIT,
    PayloadFilter,
    QdrantPointSearcher,
    ScoredHit,
    SearchRequest,
    build_query_filter,
    expand_section_hits,
    resolve_target,
)
from tests.conftest import TEST_TOKEN, FakeEmbeddings, FakePipeline, auth_headers

API_KEY = "super-secret-cloud-key"
QUERY = "revenue by year"

class FakePoint:
    def __init__(self, id, score, payload):
        self.id = id
        self.score = score
        self.payload = payload

class FakeQueryResponse:
    def __init__(self, points):
        self.points = points

class VectorParams:
    def __init__(self, size):
        self.size = size

class CollectionParams:
    def __init__(self, vectors):
        self.vectors = vectors

class CollectionConfig:
    def __init__(self, vectors):
        self.params = CollectionParams(vectors)

class CollectionInfo:
    def __init__(self, vectors):
        self.config = CollectionConfig(vectors)

class FakeQdrant:
    def __init__(self, *, size=3, named="dense", exists=True, points=None, fail=None):
        self.size = size
        self.named = named
        self.exists = exists
        self.points = points if points is not None else [
            FakePoint("p1", 0.91, {"text": "Revenue grew.", "source": "paper.pdf", "page": 2}),
            FakePoint("p2", 0.4, {"text": "Other.", "source": "notes.txt", "page": 1}),
        ]
        self.fail = fail
        self.query_calls = []
        self.closed = 0

    def collection_exists(self, *, collection_name):
        if self.fail == "describe":
            raise RuntimeError(f"qdrant down key={API_KEY}")
        return self.exists

    def get_collection(self, *, collection_name):
        if self.named:
            vectors = {self.named: VectorParams(self.size)}
        else:
            vectors = VectorParams(self.size)
        return CollectionInfo(vectors)

    def query_points(self, **kwargs):
        if self.fail == "query":
            raise RuntimeError(f"query failed key={API_KEY}")
        self.query_calls.append(kwargs)
        return FakeQueryResponse(self.points)

    def close(self):
        self.closed += 1

def _app(tmp_settings, embeddings, searcher):
    return create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=embeddings,
        store=JobStore(),
        searcher=searcher,
        model_cache=lambda: ([], None),
        model_server=lambda: [],
        ollama_tags=lambda: ([], None),
    )

def _install_embed_mock(monkeypatch, *, kind="ollama", vector=None):
    seen = []
    vector = vector if vector is not None else [0.1, 0.2, 0.3]

    def fake_post(url, json=None, timeout=None):
        seen.append({"url": url, "json": json})
        request = httpx.Request("POST", url)
        if kind == "openai":
            body = {"data": [{"index": 0, "embedding": vector}]}
        else:
            body = {"embeddings": [vector]}
        return httpx.Response(200, json=body, request=request)

    monkeypatch.setattr(httpx, "post", fake_post)
    return seen

def _client(tmp_settings, embeddings, fake, factory_log):
    def factory(url, api_key):
        factory_log.append((url, api_key))
        return fake

    app = _app(tmp_settings, embeddings, QdrantPointSearcher(client_factory=factory))
    return TestClient(app, headers=auth_headers(tmp_settings.token or TEST_TOKEN))

def test_hybrid_rrf_request_uses_text_query_and_optional_weights():
    from qdrant_client.models import RrfQuery, TextQuery

    from chunky_worker.search import PayloadFilter, hybrid_query_arguments

    arguments = hybrid_query_arguments(
        vector=[0.1, 0.2, 0.3],
        text="revenue by year",
        using="dense",
        filters=[PayloadFilter(key="source", match="paper.pdf")],
        limit=8,
        offset=2,
        weights=[0.7, 0.3],
    )
    dense, lexical = arguments["prefetch"]
    assert dense.query == [0.1, 0.2, 0.3]
    assert dense.using == "dense"
    assert dense.limit == 10
    assert isinstance(lexical.query, TextQuery)
    assert lexical.query.text == "revenue by year"
    assert lexical.using == "embedding_text"
    assert isinstance(arguments["query"], RrfQuery)
    assert arguments["query"].rrf.weights == [0.7, 0.3]
    assert arguments["limit"] == 8
    assert arguments["offset"] == 2
    assert arguments["with_payload"] is True
    assert arguments["with_vectors"] is False
    plain = hybrid_query_arguments(
        vector=[0.1],
        text="revenue",
        using=None,
        filters=[],
        limit=4,
        offset=0,
        weights=None,
    )
    assert plain["query"].rrf.weights is None
    assert plain["prefetch"][0].using is None
    assert plain["query_filter"] is None

def test_build_query_filter_ands_match_and_range():
    query_filter = build_query_filter(
        [
            PayloadFilter(key="source", match="paper.pdf"),
            PayloadFilter(key="page", match=2),
            PayloadFilter(key="content_type", match="text"),
            PayloadFilter(key="year", gte=2020, lte=2024),
        ]
    )
    must = query_filter.must
    assert [_condition_key(item) for item in must] == ["source", "page", "content_type", "year"]
    assert must[0].match.value == "paper.pdf"
    assert must[1].match.value == 2
    assert "text" in must[2].should[0].match.any
    assert "title" in must[2].should[0].match.any
    assert must[3].range.gte == 2020
    assert must[3].range.lte == 2024
    assert must[3].match is None
    assert build_query_filter([]) is None

def test_build_query_filter_uses_text_for_author_title_and_heading():
    query_filter = build_query_filter(
        [
            PayloadFilter(key="year", gte=2020, lte=2024),
            PayloadFilter(key="authors", text="Ada"),
            PayloadFilter(key="doi", match="10.1000/xyz"),
            PayloadFilter(key="doc_title", text="Revenue"),
            PayloadFilter(key="headings", text="Results"),
            PayloadFilter(key="content_type", match="table"),
        ]
    )
    must = query_filter.must
    assert [_condition_key(item) for item in must] == [
        "year",
        "authors",
        "doi",
        "doc_title",
        "headings",
        "content_type",
    ]
    assert must[0].range.gte == 2020
    assert must[0].range.lte == 2024
    assert must[1].match.text == "Ada"
    assert must[2].match.value == "10.1000/xyz"
    assert must[3].match.text == "Revenue"
    assert must[4].match.text == "Results"
    assert "table" in must[5].should[1].match.any
    inside = {
        "year": 2022,
        "authors": "Ada; Bea",
        "doi": "10.1000/xyz",
        "doc_title": "Revenue notes",
        "headings": ["Intro", "Results"],
        "content_type": "table",
    }
    assert _keeps(inside, query_filter)
    early = dict(inside, year=2010)
    assert not _keeps(early, query_filter)
    other = dict(inside, authors="Bea")
    assert not _keeps(other, query_filter)

def _condition_key(condition) -> str:
    if getattr(condition, "should", None):
        return condition.should[0].key
    return condition.key


def _keeps(payload, query_filter) -> bool:
    for condition in query_filter.must:
        if not _matches(payload, condition):
            return False
    return True


def _matches(payload, condition) -> bool:
    if getattr(condition, "should", None):
        return any(_matches(payload, item) for item in condition.should)
    value = payload.get(condition.key)
    match = condition.match
    if match is not None and getattr(match, "any", None):
        if isinstance(value, list):
            if not any(item in match.any for item in value):
                return False
        elif value not in match.any:
            return False
    elif match is not None and getattr(match, "text", None):
        needle = str(match.text).lower()
        if isinstance(value, list):
            if not any(needle in str(item).lower() for item in value):
                return False
        elif needle not in str(value or "").lower():
            return False
    elif match is not None and getattr(match, "value", None) is not None:
        if isinstance(value, list):
            if match.value not in value:
                return False
        elif value != match.value:
            return False
    bounds = getattr(condition, "range", None)
    if bounds is not None:
        if bounds.gte is not None and value < bounds.gte:
            return False
        if bounds.lte is not None and value > bounds.lte:
            return False
    return True

def test_index_setup_runs_once_per_collection():
    class IndexedQdrant(FakeQdrant):
        def __init__(self):
            super().__init__()
            self.indexes = []

        def create_payload_index(self, **kwargs):
            self.indexes.append(kwargs.get("field_name"))

    fake = IndexedQdrant()
    searcher = QdrantPointSearcher(client_factory=lambda url, api_key: fake)
    arguments = dict(
        url="http://127.0.0.1:6333",
        api_key="",
        collection="documents",
        vector=[0.1, 0.2, 0.3],
        limit=1,
        offset=0,
        filters=[],
        score_threshold=None,
        using="dense",
    )
    searcher.query_dense(**arguments)
    first = len(fake.indexes)
    searcher.query_dense(**arguments)
    assert first > 0
    assert len(fake.indexes) == first
    searcher.query_dense(**{**arguments, "collection": "notes"})
    assert len(fake.indexes) == first * 2

def test_searcher_sends_dense_query_shape():
    fake = FakeQdrant(named="dense")
    opened = []

    def factory(url, api_key):
        opened.append((url, api_key))
        return fake

    searcher = QdrantPointSearcher(client_factory=factory)
    layout = searcher.describe(url="http://127.0.0.1:6333", api_key="", collection="documents")
    assert layout.vector_size == 3
    assert layout.using == "dense"
    hits = searcher.query_dense(
        url="http://127.0.0.1:6333",
        api_key="",
        collection="documents",
        vector=[0.1, 0.2, 0.3],
        limit=5,
        offset=15,
        filters=[PayloadFilter(key="source", match="paper.pdf")],
        score_threshold=0.2,
        using=layout.using,
    )
    assert hits[0].id == "p1"
    assert hits[0].score == 0.91
    assert hits[0].payload["text"] == "Revenue grew."
    call = fake.query_calls[0]
    assert call["collection_name"] == "documents"
    assert call["query"] == [0.1, 0.2, 0.3]
    assert call["using"] == "dense"
    assert call["limit"] == 5
    assert call["offset"] == 15
    assert call["with_payload"] is True
    assert call["with_vectors"] is False
    assert call["score_threshold"] == 0.2
    assert call["query_filter"].must[0].key == "source"
    assert opened == [
        ("http://127.0.0.1:6333", ""),
        ("http://127.0.0.1:6333", ""),
    ]
    assert fake.closed == 2

def test_unnamed_vector_omits_using_name():
    fake = FakeQdrant(named=None)
    searcher = QdrantPointSearcher(client_factory=lambda url, api_key: fake)
    layout = searcher.describe(url="http://127.0.0.1:6333", api_key="", collection="documents")
    assert layout.using is None
    assert layout.vector_size == 3

def test_search_embeds_then_queries_mock_qdrant(tmp_settings, monkeypatch):
    seen = _install_embed_mock(monkeypatch)
    fake = FakeQdrant()
    opened = []
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, opened) as client:
        response = client.post(
            "/v1/search",
            json={
                "query": f"  {QUERY}  ",
                "collection": "documents",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": API_KEY,
                "limit": 2,
                "offset": 4,
                "score_threshold": 0.2,
                "filters": [
                    {"key": "source", "match": "paper.pdf"},
                    {"key": "page", "match": 2},
                    {"key": "content_type", "match": "text"},
                ],
            },
        )
        raw = response.text
    assert response.status_code == 200
    body = response.json()
    assert seen[0]["url"] == "http://127.0.0.1:11434/api/embed"
    assert seen[0]["json"]["model"] == "qwen3-embedding"
    assert seen[0]["json"]["input"] == [QUERY]
    assert seen[0]["json"]["keep_alive"] == -1
    call = fake.query_calls[0]
    assert call["limit"] == 2
    assert call["offset"] == 4
    assert call["using"] == "dense"
    assert call["query"] == [0.1, 0.2, 0.3]
    assert [_condition_key(item) for item in call["query_filter"].must] == ["source", "page", "content_type"]
    assert body["limit"] == 2
    assert body["offset"] == 4
    assert body["next_offset"] == 6
    assert body["embedding_model"] == "qwen3-embedding"
    assert body["embedding_backend"] == "ollama"
    assert body["embedding_dim"] == 3
    assert body["collection"] == "documents"
    assert body["results"][0] == {
        "id": "p1",
        "score": 0.91,
        "payload": {"text": "Revenue grew.", "source": "paper.pdf", "page": 2},
    }
    assert opened[0] == ("https://example.cloud.qdrant.io", API_KEY)
    assert API_KEY not in raw
    log_text = (tmp_settings.log_dir / "chunky-worker.log").read_text(encoding="utf-8")
    assert API_KEY not in log_text
    assert "collection=documents" in log_text

def test_expand_section_keeps_rank_documents_and_chunk_order():
    hits = [
        ScoredHit("a1", 0.9, {"text": "A1", "source": "paper.pdf", "headings": ["A"], "page": 1}),
        ScoredHit("doc", 0.8, {"text": "Abstract", "source": "paper.pdf", "record_type": "document"}),
        ScoredHit("b1", 0.7, {"text": "B1", "source": "paper.pdf", "headings": ["B"], "page": 1}),
        ScoredHit("a2", 0.6, {"text": "A2", "source": "paper.pdf", "headings": ["A"], "page": 2}),
    ]
    siblings = [
        {"id": "a1", "text": "A1", "source": "paper.pdf", "headings": ["A"], "page": 1, "chunk_index": 1},
        {"id": "a2", "text": "A2", "source": "paper.pdf", "headings": ["A"], "page": 2, "chunk_index": 1},
        {"id": "a3", "text": "A3", "source": "paper.pdf", "headings": ["A"], "page": 3, "chunk_index": 1},
    ]
    kept = expand_section_hits(hits, siblings, 0.9)
    assert [hit.id for hit in kept] == ["a1", "doc", "b1", "a2"]
    merged = expand_section_hits(hits, siblings, 0.5)
    assert [hit.id for hit in merged] == ["a1", "doc", "b1"]
    assert merged[0].payload["text"] == "A1\n\nA2\n\nA3"
    ordered = expand_section_hits(
        [
            ScoredHit("late", 0.4, {"text": "Late", "source": "p", "headings": ["M"], "page": 2}),
            ScoredHit("early", 0.3, {"text": "Early", "source": "p", "headings": ["M"], "page": 2}),
        ],
        [
            {"id": "late", "text": "Late", "source": "p", "headings": ["M"], "page": 2, "chunk_index": 2},
            {"id": "early", "text": "Early", "source": "p", "headings": ["M"], "page": 2, "chunk_index": 1},
        ],
        0.5,
    )
    assert ordered[0].payload["text"] == "Early\n\nLate"

def test_papers_first_returns_the_document_then_its_chunks(tmp_settings, monkeypatch):
    _install_embed_mock(monkeypatch)

    class Switching(FakeQdrant):
        def query_points(self, **kwargs):
            self.query_calls.append(kwargs)
            query_filter = kwargs.get("query_filter")
            must = list(getattr(query_filter, "must", None) or [])
            keys = [getattr(item, "key", None) for item in must]
            if "record_type" in keys:
                return FakeQueryResponse([
                    FakePoint("doc", 0.9, {"text": "abstract", "source": "paper.pdf", "record_type": "document"})
                ])
            return FakeQueryResponse([
                FakePoint("chunk", 0.4, {"text": "body", "source": "paper.pdf"})
            ])

    fake = Switching()
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "papers_first": True,
                "expand_documents": True,
                "limit": 1,
                "offset": 3,
                "filters": [{"key": "content_type", "match": "text"}, {"key": "year", "gte": 2020}],
            },
        )
    body = response.json()
    assert response.status_code == 200
    assert [item["id"] for item in body["results"]] == ["doc", "chunk"]
    assert body["next_offset"] == 4
    assert len(fake.query_calls) == 2
    paper_keys = [item.key for item in (fake.query_calls[0]["query_filter"].must or [])]
    assert "content_type" not in paper_keys
    assert "year" in paper_keys
    assert fake.query_calls[0]["offset"] == 3
    assert fake.query_calls[1]["offset"] == 0

def test_short_page_has_no_next_offset(tmp_settings, monkeypatch):
    _install_embed_mock(monkeypatch)
    fake = FakeQdrant(points=[FakePoint("only", 0.5, {"text": "one"})])
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={"query": QUERY, "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
    body = response.json()
    assert response.status_code == 200
    assert body["limit"] == 10
    assert body["offset"] == 0
    assert body["next_offset"] is None
    assert len(body["results"]) == 1
    assert fake.query_calls[0]["limit"] == 10
    assert fake.query_calls[0]["offset"] == 0
    query_filter = fake.query_calls[0]["query_filter"]
    assert query_filter.must in (None, [])
    assert query_filter.must_not[0].key == "record_type"
    assert query_filter.must_not[0].match.value == "document"

def test_openai_backend_posts_to_embeddings_endpoint(tmp_settings, monkeypatch):
    seen = _install_embed_mock(monkeypatch, kind="openai", vector=[0.5, 0.25, 0.0])
    fake = FakeQdrant()
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "embedding_backend": "openai",
                "embedding_url": "http://127.0.0.1:8002",
                "embedding_model": "Qwen/Qwen3-Embedding-0.6B",
            },
        )
    assert response.status_code == 200
    assert response.json()["embedding_backend"] == "openai"
    assert response.json()["embedding_model"] == "Qwen/Qwen3-Embedding-0.6B"
    assert seen[0]["url"] == "http://127.0.0.1:8002/v1/embeddings"
    assert seen[0]["json"] == {"model": "Qwen/Qwen3-Embedding-0.6B", "input": [QUERY]}
    assert isinstance(embeddings, OllamaEmbeddingBackend)
    assert OpenAIEmbeddingBackend("http://127.0.0.1:8002").base_url == "http://127.0.0.1:8002"

def test_configured_qdrant_target_is_used_when_the_body_omits_it(tmp_settings, monkeypatch):
    _install_embed_mock(monkeypatch)
    tmp_settings.qdrant_url = "http://10.0.0.8:6333"
    tmp_settings.qdrant_api_key = API_KEY
    fake = FakeQdrant(named=None)
    opened = []
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, opened) as client:
        response = client.post("/v1/search", json={"query": QUERY, "collection": "local"})
    assert response.status_code == 200
    assert API_KEY not in response.text
    assert opened[0] == ("http://10.0.0.8:6333", API_KEY)
    assert fake.query_calls[0]["using"] is None
    assert fake.query_calls[0]["collection_name"] == "local"

def test_configured_key_stays_on_the_configured_url(tmp_settings):
    tmp_settings.qdrant_url = "https://example.cloud.qdrant.io/"
    tmp_settings.qdrant_api_key = API_KEY
    same = SearchRequest.model_validate(
        {"query": QUERY, "collection": "documents", "qdrant_url": "https://Example.Cloud.Qdrant.io"}
    )
    other = SearchRequest.model_validate(
        {"query": QUERY, "collection": "documents", "qdrant_url": "https://attacker.example"}
    )
    explicit = SearchRequest.model_validate(
        {
            "query": QUERY,
            "collection": "documents",
            "qdrant_url": "https://attacker.example",
            "qdrant_api_key": "caller-key",
        }
    )
    assert resolve_target(same, tmp_settings) == ("https://Example.Cloud.Qdrant.io", API_KEY)
    assert resolve_target(other, tmp_settings) == ("https://attacker.example", "")
    assert resolve_target(explicit, tmp_settings) == ("https://attacker.example", "caller-key")

def test_overridden_url_does_not_receive_the_configured_key(tmp_settings, monkeypatch):
    _install_embed_mock(monkeypatch)
    tmp_settings.qdrant_url = "https://example.cloud.qdrant.io"
    tmp_settings.qdrant_api_key = API_KEY
    fake = FakeQdrant()
    opened = []
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, opened) as client:
        response = client.post(
            "/v1/search",
            json={"query": QUERY, "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
    assert response.status_code == 200
    assert opened[0] == ("http://127.0.0.1:6333", "")
    assert API_KEY not in response.text
    log_text = (tmp_settings.log_dir / "chunky-worker.log").read_text(encoding="utf-8")
    assert API_KEY not in log_text

def test_non_numeric_embedding_is_an_embedding_error(tmp_settings, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        request = httpx.Request("POST", url)
        return httpx.Response(200, json={"embeddings": [[0.1, None]]}, request=request)

    monkeypatch.setattr(httpx, "post", fake_post)
    fake = FakeQdrant()
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={"query": QUERY, "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
    assert response.status_code == 502
    assert response.json()["error_type"] == "embedding_error"
    assert "non-numeric" in response.json()["detail"]
    assert fake.query_calls == []

def test_dimension_mismatch_is_refused_before_query(tmp_settings, monkeypatch):
    seen = _install_embed_mock(monkeypatch, vector=[0.1, 0.2, 0.3])
    fake = FakeQdrant(size=1024)
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "qdrant_api_key": API_KEY,
            },
        )
    assert response.status_code == 409
    body = response.json()
    assert body["error_type"] == "dimension_mismatch"
    assert "vector size 1024" in body["detail"]
    assert "size 3" in body["detail"]
    assert API_KEY not in response.text
    assert seen
    assert fake.query_calls == []

def test_missing_collection_is_404_and_does_not_embed(tmp_settings, monkeypatch):
    seen = _install_embed_mock(monkeypatch)
    fake = FakeQdrant(exists=False)
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={"query": QUERY, "collection": "missing", "qdrant_url": "http://127.0.0.1:6333"},
        )
    assert response.status_code == 404
    assert response.json()["error_type"] == "not_found"
    assert seen == []
    assert fake.query_calls == []

def test_qdrant_errors_are_redacted(tmp_settings, monkeypatch):
    _install_embed_mock(monkeypatch)
    fake = FakeQdrant(fail="query")
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "https://example.cloud.qdrant.io",
                "qdrant_api_key": API_KEY,
            },
        )
    assert response.status_code == 502
    assert response.json()["error_type"] == "qdrant_error"
    assert API_KEY not in response.text
    assert "[redacted]" in response.text

def test_embed_server_failure_is_502(tmp_settings, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        request = httpx.Request("POST", url)
        return httpx.Response(503, json={"error": "down"}, request=request)

    monkeypatch.setattr(httpx, "post", fake_post)
    fake = FakeQdrant()
    embeddings = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    with _client(tmp_settings, embeddings, fake, []) as client:
        response = client.post(
            "/v1/search",
            json={"query": QUERY, "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
    assert response.status_code == 502
    assert response.json()["error_type"] == "embedding_error"
    assert fake.query_calls == []

def test_invalid_limit_filter_and_backend_are_400(tmp_settings):
    embeddings = FakeEmbeddings()
    fake = FakeQdrant()
    with _client(tmp_settings, embeddings, fake, []) as client:
        over = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "qdrant_api_key": API_KEY,
                "limit": MAX_LIMIT + 1,
            },
        )
        empty = client.post(
            "/v1/search",
            json={"query": "   ", "collection": "documents", "qdrant_url": "http://127.0.0.1:6333"},
        )
        bad_filter = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "filters": [{"key": "page"}],
            },
        )
        bad_backend = client.post(
            "/v1/search",
            json={
                "query": QUERY,
                "collection": "documents",
                "qdrant_url": "http://127.0.0.1:6333",
                "embedding_backend": "mlx",
            },
        )
        missing_url = client.post("/v1/search", json={"query": QUERY, "collection": "documents"})
    assert over.status_code == 400
    assert API_KEY not in over.text
    assert empty.status_code == 400
    assert bad_filter.status_code == 400
    assert "page" in bad_filter.json()["detail"]
    assert bad_backend.status_code == 400
    assert missing_url.status_code == 400
    assert embeddings.embed_calls == []
    assert fake.query_calls == []

def test_request_model_rejects_a_negative_offset():
    try:
        SearchRequest.model_validate({"query": "q", "collection": "c", "offset": -1})
    except Exception as exc:
        assert "offset" in str(exc)
    else:
        raise AssertionError("negative offset was accepted")

def test_library_filter_is_a_required_or_and_excludes_the_other_library():
    query_filter = build_query_filter([
        PayloadFilter(key="library_id", any=["default"], should=True),
        PayloadFilter(key="library_id", empty=True, should=True),
    ])
    assert query_filter is not None
    assert len(query_filter.must) == 1
    nested = query_filter.must[0]
    assert len(nested.should) == 2
    thesis = build_query_filter([PayloadFilter(key="library_id", match="thesis")])
    assert thesis.must[0].key == "library_id"
    assert thesis.must[0].match.value == "thesis"
