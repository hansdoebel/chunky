"""Chunk cache keys, citation records, atomic files, and LRU eviction."""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from chunky_worker.app import create_app
from chunky_worker.chunk_cache import ChunkCache, ChunkCacheError, entry_id, normalize_chunk
from chunky_worker.jobs import JobStore
from tests.conftest import FakeEmbeddings, FakePipeline, auth_headers


KEY = {
    "content_sha256": "abc",
    "docling_version": "2.64.0",
    "pipeline": "standard",
    "tokenizer": "",
    "max_tokens": 512,
}


def test_entry_id_is_stable():
    assert entry_id("abc", "2.64.0", "standard", "", 512) == (
        "3636fff3a40669cb435b521f6960f2888b9555317a5077458119ae261d853611"
    )
    assert entry_id("ABC", "2.64.0", "standard", "", 512) == entry_id("abc", "2.64.0", "standard", "", 512)


def test_normalize_keeps_the_full_citation_payload():
    record = normalize_chunk(
        {
            "text": "Hello",
            "page": 2,
            "page_labels": ["ii"],
            "headings": ["Intro"],
            "bboxes": [{"page": 2, "l": 0, "t": 3, "r": 2, "b": 1}],
            "doc_title": "Paper",
            "authors": ["Ada"],
            "year": 2024,
            "doi": "10.1/abc",
            "source": "paper.pdf",
        }
    )
    assert record["embedding_text"] == "Hello"
    assert record["page"] == 2
    assert record["page_end"] == 2
    assert record["pages"] == [2]
    assert record["page_labels"] == ["ii"]
    assert record["bboxes"][0]["coord_origin"] is None
    assert record["doc_title"] == "Paper"
    assert record["authors"] == ["Ada"]
    assert record["year"] == 2024
    assert record["doi"] == "10.1/abc"
    assert record["source"] == "paper.pdf"


def test_store_lookup_vectors_and_lru(tmp_path):
    cache = ChunkCache(tmp_path / "cache", limit_bytes=0)
    stored = cache.store(
        KEY,
        {"schema": "docling", "name": "paper.pdf"},
        [{"text": "Hello", "page": 2, "headings": ["Intro"]}],
        {"source": "paper.pdf", "doc_title": "Paper", "authors": ["Ada"], "year": 2024, "doi": "10.1/abc"},
    )
    assert stored["chunks"] == 1
    directory = tmp_path / "cache" / "entries" / stored["id"]
    assert (directory / "document.json").is_file()
    assert (directory / "chunks.json").is_file()
    assert not list((tmp_path / "cache").glob(".tmp-*"))

    chunks_only = cache.lookup(KEY, embedding_model="qwen3-embedding", embedding_dim=4)
    assert chunks_only["hit"] is True
    assert chunks_only["vector_hit"] is False
    assert chunks_only["vectors"] is None
    assert chunks_only["chunks"][0]["source"] == "paper.pdf"
    assert chunks_only["chunks"][0]["doc_title"] == "Paper"

    cache.store_vectors(KEY, "qwen3-embedding", 4, [[0.1, 0.2, 0.3, 0.4]])
    with_vectors = cache.lookup(KEY, embedding_model="qwen3-embedding", embedding_dim=4, include_document=True)
    assert with_vectors["vector_hit"] is True
    assert with_vectors["vectors"] == [[0.1, 0.2, 0.3, 0.4]]
    assert with_vectors["document"]["name"] == "paper.pdf"
    other_model = cache.lookup(KEY, embedding_model="other", embedding_dim=4)
    assert other_model["hit"] is True
    assert other_model["vector_hit"] is False

    small = ChunkCache(tmp_path / "small", limit_bytes=1)
    first = {**KEY, "content_sha256": "a" * 64}
    second = {**KEY, "content_sha256": "b" * 64}
    small.store(first, {"n": 1}, [{"text": "one"}])
    small.store(second, {"n": 2}, [{"text": "two"}])
    assert small.lookup(first) is None
    assert small.lookup(second)["chunks"][0]["text"] == "two"
    assert small.stats()["entries"] == 1

    small.clear()
    assert small.stats() == {"schema": 1, "entries": 0, "bytes": 0, "limit_bytes": 1}


def test_corrupt_manifest_is_rejected(tmp_path):
    root = tmp_path / "cache"
    root.mkdir()
    (root / "manifest.json").write_text("{", encoding="utf-8")
    cache = ChunkCache(root)
    with pytest.raises(ChunkCacheError) as caught:
        cache.stats()
    assert caught.value.error_type == "corrupt_manifest"


def test_http_cache_requires_a_token_and_round_trips(tmp_path, tmp_settings):
    tmp_settings.cache_dir = tmp_path / "http-cache"
    app = create_app(
        settings=tmp_settings,
        pipeline=FakePipeline(),
        embeddings=FakeEmbeddings(),
        store=JobStore(),
        model_cache=lambda: ([], None),
        model_server=lambda: [],
        ollama_tags=lambda: ([], None),
    )
    body = {
        **KEY,
        "content_sha256": "ab" * 32,
        "document": {"name": "paper.pdf"},
        "chunks": [{"text": "Hello", "page": 1, "bboxes": [{"l": 0, "t": 1, "r": 2, "b": 3, "page": 1}]}],
        "source": "paper.pdf",
        "doc_title": "Paper",
    }
    with TestClient(app) as client:
        assert client.post("/v1/cache/lookup", json=body).status_code == 401
    with TestClient(app, headers=auth_headers()) as client:
        stored = client.put("/v1/cache", json=body)
        assert stored.status_code == 200
        missing = client.post("/v1/cache/lookup", json={**body, "embedding_model": "qwen3-embedding", "embedding_dim": 2})
        assert missing.status_code == 200
        found = missing.json()
        assert found["hit"] is True
        assert found["vector_hit"] is False
        assert found["chunks"][0]["source"] == "paper.pdf"
        assert found["chunks"][0]["bboxes"][0]["l"] == 0
        vectors = client.put(
            "/v1/cache/vectors",
            json={**body, "embedding_model": "qwen3-embedding", "embedding_dim": 2, "vectors": [[0.5, 0.25]]},
        )
        assert vectors.status_code == 200
        hit = client.post(
            "/v1/cache/lookup",
            json={**body, "embedding_model": "qwen3-embedding", "embedding_dim": 2},
        ).json()
        assert hit["vector_hit"] is True
        assert hit["vectors"] == [[0.5, 0.25]]
        assert client.get("/v1/cache").json()["entries"] == 1
        assert client.delete("/v1/cache").json()["cleared"] is True
        assert client.post("/v1/cache/lookup", json=body).json()["hit"] is False


def test_replacing_chunks_drops_stale_vectors_and_counts_must_match(tmp_path):
    cache = ChunkCache(tmp_path)
    cache.store(KEY, {"name": "a"}, [{"text": "one"}, {"text": "two"}])
    cache.store_vectors(KEY, "qwen3-embedding", 2, [[0.1, 0.2], [0.3, 0.4]])
    with pytest.raises(ChunkCacheError) as caught:
        cache.store_vectors(KEY, "qwen3-embedding", 2, [[0.1, 0.2]])
    assert caught.value.error_type == "invalid_vectors"
    cache.store(KEY, {"name": "b"}, [{"text": "only"}])
    refreshed = cache.lookup(KEY, embedding_model="qwen3-embedding", embedding_dim=2)
    assert refreshed["hit"] is True
    assert refreshed["vector_hit"] is False
    assert refreshed["chunks"][0]["text"] == "only"
    first = cache.lookup(KEY)
    other = {**KEY, "content_sha256": "ccc"}
    cache.store(other, {"name": "c"}, [{"text": "c"}])
    assert first["id"] != cache.lookup(other)["id"]
    assert cache.lookup(KEY)["id"] == first["id"]


def test_lookup_of_an_unknown_key_is_a_miss(tmp_path):
    cache = ChunkCache(tmp_path)
    assert cache.lookup(KEY) is None
    raw = json.dumps({"text": "x"})
    assert "page" not in json.loads(raw)
