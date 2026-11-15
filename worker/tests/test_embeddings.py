"""Unit tests for the Ollama embedding client with httpx mocked."""

from __future__ import annotations

import httpx

from chunky_worker.embeddings import (
    DimensionCache,
    OllamaEmbeddingBackend,
    OpenAIEmbeddingBackend,
    PROBE_TEXT,
    tokenizer_for_embedding,
)


def test_ollama_health_and_models(monkeypatch):
    def fake_get(url, timeout=None):
        request = httpx.Request("GET", url)
        return httpx.Response(
            200,
            json={"models": [{"name": "qwen3-embedding:latest"}, {"name": "llama3"}]},
            request=request,
        )

    monkeypatch.setattr(httpx, "get", fake_get)
    backend = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    ok, err = backend.health()
    assert ok and err is None
    names, err = backend.list_models()
    assert err is None
    assert names == ["qwen3-embedding:latest", "llama3"]


def test_ollama_embed_posts_input(monkeypatch):
    captured = {}

    def fake_post(url, json=None, timeout=None):
        captured["url"] = url
        captured["json"] = json
        request = httpx.Request("POST", url)
        return httpx.Response(
            200,
            json={"embeddings": [[0.1, 0.2], [0.3, 0.4]]},
            request=request,
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    backend = OllamaEmbeddingBackend("http://127.0.0.1:11434")
    vectors = backend.embed(["a", "b"], "qwen3-embedding")
    assert vectors == [[0.1, 0.2], [0.3, 0.4]]
    assert captured["url"].endswith("/api/embed")
    assert captured["json"]["model"] == "qwen3-embedding"
    assert captured["json"]["input"] == ["a", "b"]
    assert captured["json"]["keep_alive"] == -1
    assert captured["json"]["options"]["num_ctx"] == 8192


def test_dimension_cache_probes_once_per_model():
    class Counting:
        def __init__(self):
            self.calls = []

        def health(self):
            return True, None

        def list_models(self):
            return [], None

        def embed(self, texts, model):
            self.calls.append((texts, model))
            width = 4 if model == "wide" else 2
            return [[0.0] * width for _ in texts]

    backend = Counting()
    cache = DimensionCache()
    assert cache.dimension(backend, "qwen3-embedding") == 2
    assert cache.dimension(backend, "qwen3-embedding") == 2
    assert cache.dimension(backend, "wide") == 4
    assert backend.calls == [([PROBE_TEXT], "qwen3-embedding"), ([PROBE_TEXT], "wide")]


def test_openai_embeddings_and_health(monkeypatch):
    def fake_get(url, timeout=None):
        request = httpx.Request("GET", url)
        return httpx.Response(
            200,
            json={"data": [{"id": "Qwen/Qwen3-Embedding-0.6B"}]},
            request=request,
        )

    def fake_post(url, json=None, timeout=None):
        assert url.endswith("/v1/embeddings")
        assert json == {"model": "Qwen/Qwen3-Embedding-0.6B", "input": ["chunky"]}
        request = httpx.Request("POST", url)
        return httpx.Response(
            200,
            json={"data": [{"index": 0, "embedding": [0.5, 0.25, 0.0]}]},
            request=request,
        )

    monkeypatch.setattr(httpx, "get", fake_get)
    monkeypatch.setattr(httpx, "post", fake_post)
    backend = OpenAIEmbeddingBackend("http://127.0.0.1:8002")
    ok, err = backend.health()
    assert ok and err is None
    names, err = backend.list_models()
    assert names == ["Qwen/Qwen3-Embedding-0.6B"]
    assert backend.embed(["chunky"], "Qwen/Qwen3-Embedding-0.6B") == [[0.5, 0.25, 0.0]]
    assert DimensionCache().dimension(backend, "Qwen/Qwen3-Embedding-0.6B") == 3


def test_dimension_cache_keeps_endpoints_apart():
    class Counting:
        def __init__(self):
            self.calls = 0

        def embed(self, texts, model):
            self.calls += 1
            return [[0.0] * self.calls]

    backend = Counting()
    cache = DimensionCache()
    first = cache.dimension(backend, "same", cache_key="openai|http://a|same")
    second = cache.dimension(backend, "same", cache_key="openai|http://b|same")
    again = cache.dimension(backend, "same", cache_key="openai|http://a|same")
    assert first == 1
    assert second == 2
    assert again == 1
    assert backend.calls == 2


def test_tokenizer_follows_the_embedding_model():
    assert tokenizer_for_embedding("qwen3-embedding") == "Qwen/Qwen3-Embedding-0.6B"
    assert tokenizer_for_embedding("Qwen/Qwen3-Embedding-0.6B") == "Qwen/Qwen3-Embedding-0.6B"
    assert tokenizer_for_embedding("") == "Qwen/Qwen3-Embedding-0.6B"
    assert "MiniLM" not in tokenizer_for_embedding(None)


def test_ollama_health_false_when_down(monkeypatch):
    def fake_get(url, timeout=None):
        raise httpx.ConnectError("connection refused")

    monkeypatch.setattr(httpx, "get", fake_get)
    ok, err = OllamaEmbeddingBackend().health()
    assert ok is False
    assert err
