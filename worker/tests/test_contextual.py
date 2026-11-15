"""Contextual prefixes stay off the citation text and off a matching cache key."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from contextual import apply_prefixes, cache_options, load_or_enrich, prompt_for  # noqa: E402
from chunky_worker.chunk_cache import ChunkCache, entry_id  # noqa: E402
from chunky_worker.qdrant_ingest import stored_chunk_text  # noqa: E402


KEY = {
    "content_sha256": "abc",
    "docling_version": "2.64.0",
    "pipeline": "standard",
    "tokenizer": "",
    "max_tokens": 512,
}


def _chunk() -> dict:
    return {
        "text": "this result shows the effect",
        "embedding_text": "this result shows the effect",
        "doc_title": "Paper",
        "authors": ["Ada"],
        "year": 2020,
        "headings": ["Results"],
    }


def test_setting_off_does_not_call_the_model():
    chunk = _chunk()
    calls = []

    def llm(prompt):
        calls.append(prompt)
        return "A paper by Ada in Results."

    load_or_enrich(None, None, [chunk], llm, enabled=False)
    assert calls == []
    assert chunk["embedding_text"] == chunk["text"]
    assert chunk["text"] == "this result shows the effect"


def test_prefix_is_on_the_embedding_input_only():
    chunk = _chunk()
    long_prefix = " ".join(f"word{i}" for i in range(140))
    seen = []

    def llm(prompt):
        seen.append(prompt)
        return long_prefix

    apply_prefixes([chunk], llm)
    assert "Paper" in seen[0]
    assert "Ada" in seen[0]
    assert "Results" in seen[0]
    assert "2020" in seen[0]
    prefix, body = chunk["embedding_text"].split("\n\n", 1)
    assert len(prefix.split()) == 100
    assert body == "this result shows the effect"
    assert chunk["text"] == "this result shows the effect"
    assert prefix not in chunk["text"]
    assert stored_chunk_text(chunk).startswith("word0")
    assert prompt_for(chunk).count("this result shows") == 1


def test_matching_cache_key_skips_the_llm(tmp_path):
    cache = ChunkCache(tmp_path)
    options = cache_options("pageOffset=", "stub-model", "v1")
    key = {**KEY, "options": options}
    first = _chunk()
    calls = []

    def llm(_prompt):
        calls.append("called")
        return "Ada, 2020, Results: the passage reports the measured effect."

    load_or_enrich(cache, key, [first], llm)
    assert calls == ["called"]
    enriched = first["embedding_text"]

    second = _chunk()

    def again(_prompt):
        calls.append("again")
        return "different"

    load_or_enrich(cache, key, [second], again)
    assert calls == ["called"]
    assert second["embedding_text"] == enriched
    assert second["text"] == "this result shows the effect"
    assert second["doc_title"] == "Paper"


def test_enricher_model_and_prompt_change_the_cache_key():
    base = cache_options("pageOffset=", "stub-model", "v1")
    other_model = cache_options("pageOffset=", "other-model", "v1")
    other_prompt = cache_options("pageOffset=", "stub-model", "v2")
    assert entry_id("abc", "2.64.0", "standard", "", 512, base) != entry_id(
        "abc", "2.64.0", "standard", "", 512, other_model
    )
    assert entry_id("abc", "2.64.0", "standard", "", 512, base) != entry_id(
        "abc", "2.64.0", "standard", "", 512, other_prompt
    )
    assert entry_id("abc", "2.64.0", "standard", "", 512, base) == entry_id(
        "abc", "2.64.0", "standard", "", 512, cache_options("pageOffset=", "stub-model", "v1")
    )
