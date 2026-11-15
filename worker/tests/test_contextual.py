"""Contextual prefixes stay off the citation text and off a matching cache key."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from contextual import (  # noqa: E402
    EnrichmentStopped,
    apply_prefixes,
    cache_options,
    clip_prefix,
    default_tokens,
    load_or_enrich,
    metadata_key,
    prompt_for,
)
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


def test_punctuation_is_clipped_by_tokens_not_words():
    packed = "A," * 80
    prefix = clip_prefix(packed)
    assert len(default_tokens(prefix)) == 100
    assert len(prefix.split()) == 1
    chunk = {"text": "body", "embedding_text": "body"}
    assert apply_prefixes([chunk], lambda _prompt: packed)
    assert chunk["embedding_text"].split("\n\n", 1)[0] == prefix


def test_failed_prefix_is_not_cached(tmp_path):
    cache = ChunkCache(tmp_path)
    key = {**KEY, "options": cache_options("", "stub", "v1")}
    calls = []

    def llm(_prompt):
        calls.append("called")
        return "   "

    load_or_enrich(cache, key, [_chunk()], llm)
    load_or_enrich(cache, key, [_chunk()], llm)
    assert calls == ["called", "called"]


def test_cancel_stops_before_the_next_chunk():
    chunks = [_chunk(), _chunk()]
    seen = []

    def llm(_prompt):
        seen.append("called")
        return "A short situating prefix."

    try:
        apply_prefixes(chunks, llm, should_stop=lambda: len(seen) >= 1)
    except EnrichmentStopped:
        stopped = True
    else:
        stopped = False
    assert stopped
    assert seen == ["called"]


def test_metadata_changes_the_cache_key_and_citation_stays_raw():
    first = cache_options("", "stub", "v1", metadata_key(_chunk()))
    other = dict(_chunk(), year=1999)
    second = cache_options("", "stub", "v1", metadata_key(other))
    assert entry_id("abc", "2.64.0", "standard", "", 512, first) != entry_id(
        "abc", "2.64.0", "standard", "", 512, second
    )
    from chunky_worker.models import JobSettings
    from chunky_worker.qdrant_ingest import build_points

    chunk = _chunk()
    apply_prefixes([chunk], lambda _prompt: "Ada reported this result.")
    payload = build_points(
        [chunk],
        [[0.1, 0.2]],
        source="paper.pdf",
        settings=JobSettings(),
        embedding_model="qwen3-embedding",
    )[0].payload
    assert payload["text"] == "this result shows the effect"
    assert payload["embedding_text"].startswith("Ada reported")
