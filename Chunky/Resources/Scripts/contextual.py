"""Short per-chunk prefixes for embedding and BM25, cached with the chunk cache key."""

from __future__ import annotations

from typing import Any, Callable

PROMPT_VERSION = "v1"
PREFIX_TOKENS = 100


def cache_options(base: str, model: str, prompt_version: str | None = None) -> str:
    version = (prompt_version or PROMPT_VERSION).strip() or PROMPT_VERSION
    lines = [line.strip() for line in (base or "").splitlines() if line.strip()]
    lines.append(f"contextModel={(model or '').strip()}")
    lines.append(f"contextPrompt={version}")
    return "\n".join(lines)


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


def clip_prefix(text: str, limit: int = PREFIX_TOKENS) -> str:
    words = (text or "").split()
    if len(words) > limit:
        words = words[:limit]
    return " ".join(words)


def apply_prefixes(chunks: list[dict[str, Any]], llm: Callable[[str], str]) -> list[dict[str, Any]]:
    for chunk in chunks:
        prefix = clip_prefix(llm(prompt_for(chunk)))
        if not prefix:
            continue
        base = chunk.get("embedding_text") or chunk.get("text") or ""
        chunk["embedding_text"] = f"{prefix}\n\n{base}" if base else prefix
    return chunks


def _saved_prefixes(chunks: list[dict[str, Any]], cached: list[dict[str, Any]]) -> bool:
    if len(chunks) != len(cached):
        return False
    for chunk, saved in zip(chunks, cached):
        if (saved.get("text") or "") != (chunk.get("text") or ""):
            return False
        if not saved.get("embedding_text"):
            return False
    return True


def load_or_enrich(
    cache: Any,
    key: dict[str, Any] | None,
    chunks: list[dict[str, Any]],
    llm: Callable[[str], str] | None,
    *,
    enabled: bool = True,
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
        return chunks
    if llm is None:
        return chunks
    apply_prefixes(chunks, llm)
    if cache is not None and key is not None and chunks:
        try:
            cache.store(key, {"source": "contextual"}, chunks)
        except (OSError, ValueError):
            return chunks
    return chunks
