"""Unit tests for the Ollama embedding client with httpx mocked."""

from __future__ import annotations

import httpx

from chunky_worker.embeddings import OllamaEmbeddingBackend


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
    assert captured["json"] == {"model": "qwen3-embedding", "input": ["a", "b"]}


def test_ollama_health_false_when_down(monkeypatch):
    def fake_get(url, timeout=None):
        raise httpx.ConnectError("connection refused")

    monkeypatch.setattr(httpx, "get", fake_get)
    ok, err = OllamaEmbeddingBackend().health()
    assert ok is False
    assert err
