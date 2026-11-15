"""Short per-chunk prefixes for embedding and BM25, cached with the chunk cache key."""

from __future__ import annotations

import re
from typing import Any, Callable

PROMPT_VERSION = "v1"
PREFIX_TOKENS = 100
_TOKEN = re.compile(r"\w+|[^\w\s]", re.UNICODE)


class EnrichmentStopped(Exception):
    pass


def default_tokens(text: str) -> list[str]:
    return _TOKEN.findall(text or "")


def cache_options(
    base: str,
    model: str,
    prompt_version: str | None = None,
    metadata: str = "",
) -> str:
    version = (prompt_version or PROMPT_VERSION).strip() or PROMPT_VERSION
    lines = [line.strip() for line in (base or "").splitlines() if line.strip()]
    lines.extend(line.strip() for line in (metadata or "").splitlines() if line.strip())
    lines.append(f"contextModel={(model or '').strip()}")
    lines.append(f"contextPrompt={version}")
    return "\n".join(lines)


def metadata_key(chunk: dict[str, Any] | None) -> str:
    chunk = chunk or {}
    authors = chunk.get("authors") or []
    if isinstance(authors, list):
        authors = ", ".join(str(author) for author in authors if str(author).strip())
    year = chunk.get("year")
    return "\n".join(
        [
            f"contextTitle={chunk.get('doc_title') or ''}",
            f"contextAuthors={authors}",
            f"contextYear={'' if year is None else year}",
        ]
    )


def prompt_for(chunk: dict[str, Any]) -> str:
    authors = chunk.get("authors") or []
    if isinstance(authors, list):
        authors = ", ".join(str(author) for author in authors if str(author).strip())
    headings = chunk.get("headings") or []
    if isinstance(headings, list):
        headings = " > ".join(str(heading) for heading in headings if str(heading).strip())
    year = chunk.get("year")
    return (
        "Write a situating prefix of 50 to 100 tokens for this chunk. "
        "Use the title, authors, year, and section. Return only the prefix.\n"
        f"Title: {chunk.get('doc_title') or ''}\n"
        f"Authors: {authors}\n"
        f"Year: {'' if year is None else year}\n"
        f"Section: {headings}\n\n"
        f"{chunk.get('text') or ''}"
    )


def _join_tokens(tokens: list[str]) -> str:
    parts: list[str] = []
    for token in tokens:
        if parts and token[:1].isalnum() and parts[-1][-1:].isalnum():
            parts.append(" ")
        parts.append(token)
    return "".join(parts)


def clip_prefix(
    text: str,
    limit: int = PREFIX_TOKENS,
    tokenize: Callable[[str], list[str]] | None = None,
) -> str:
    tokens = (tokenize or default_tokens)(text or "")
    if len(tokens) <= limit:
        return (text or "").strip()
    return _join_tokens(tokens[:limit])


def apply_prefixes(
    chunks: list[dict[str, Any]],
    llm: Callable[[str], str],
    *,
    tokenize: Callable[[str], list[str]] | None = None,
    should_stop: Callable[[], bool] | None = None,
) -> bool:
    complete = True
    for chunk in chunks:
        if should_stop is not None and should_stop():
            raise EnrichmentStopped()
        prefix = clip_prefix(llm(prompt_for(chunk)), tokenize=tokenize)
        if not prefix:
            complete = False
            continue
        base = chunk.get("embedding_text") or chunk.get("text") or ""
        chunk["context_prefix"] = prefix
        chunk["embedding_text"] = f"{prefix}\n\n{base}" if base else prefix
    return complete


def _same_metadata(chunk: dict[str, Any], saved: dict[str, Any]) -> bool:
    if (saved.get("doc_title") or None) != (chunk.get("doc_title") or None):
        return False
    if saved.get("year") != chunk.get("year"):
        return False
    return list(saved.get("authors") or []) == list(chunk.get("authors") or [])


def _saved_prefixes(chunks: list[dict[str, Any]], cached: list[dict[str, Any]]) -> bool:
    if len(chunks) != len(cached):
        return False
    for chunk, saved in zip(chunks, cached):
        if (saved.get("text") or "") != (chunk.get("text") or ""):
            return False
        if not saved.get("context_prefix") or not saved.get("embedding_text"):
            return False
        if not _same_metadata(chunk, saved):
            return False
    return True


def load_or_enrich(
    cache: Any,
    key: dict[str, Any] | None,
    chunks: list[dict[str, Any]],
    llm: Callable[[str], str] | None,
    *,
    enabled: bool = True,
    tokenize: Callable[[str], list[str]] | None = None,
    should_stop: Callable[[], bool] | None = None,
) -> list[dict[str, Any]]:
    if not enabled:
        return chunks
    cached: list[dict[str, Any]] | None = None
    if cache is not None and key is not None:
        try:
            found = cache.lookup(key)
        except (OSError, ValueError):
            found = None
        if isinstance(found, dict) and isinstance(found.get("chunks"), list):
            cached = found["chunks"]
    if cached is not None and _saved_prefixes(chunks, cached):
        for chunk, saved in zip(chunks, cached):
            chunk["embedding_text"] = saved["embedding_text"]
            chunk["context_prefix"] = saved["context_prefix"]
        return chunks
    if llm is None:
        return chunks
    complete = apply_prefixes(chunks, llm, tokenize=tokenize, should_stop=should_stop)
    if complete and cache is not None and key is not None and chunks:
        try:
            cache.store(key, {"source": "contextual"}, chunks)
        except (OSError, ValueError):
            return chunks
    return chunks
