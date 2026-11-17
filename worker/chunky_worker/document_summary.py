"""Document-level summary text for a paper, stored as its own point."""

from __future__ import annotations

import uuid
from typing import Any

ABSTRACT_HEADINGS = {"abstract", "summary", "zusammenfassung"}
DOCUMENT_RECORD = "document"


def _heading_names(chunk: dict[str, Any]) -> list[str]:
    headings = chunk.get("headings") or []
    return [str(item).strip().lower() for item in headings if str(item).strip()]


def abstract_text(chunks: list[dict[str, Any]]) -> str | None:
    parts: list[str] = []
    for chunk in chunks:
        if not any(name in ABSTRACT_HEADINGS for name in _heading_names(chunk)):
            continue
        text = str(chunk.get("text") or "").strip()
        if text:
            parts.append(text)
    if not parts:
        return None
    return "\n\n".join(parts)


def fallback_source(chunks: list[dict[str, Any]], title: str | None) -> str:
    headings: list[str] = []
    pages: list[str] = []
    for chunk in chunks:
        for heading in chunk.get("headings") or []:
            label = str(heading).strip()
            if label and label not in headings:
                headings.append(label)
        page = chunk.get("page")
        if not isinstance(page, int) or page <= 2:
            text = str(chunk.get("text") or "").strip()
            if text:
                pages.append(text)
    lines: list[str] = []
    trimmed = (title or "").strip()
    if trimmed:
        lines.append(trimmed)
    if headings:
        lines.append("Sections: " + " > ".join(headings[:12]))
    body = "\n".join(pages)
    if body:
        lines.append(body[:4000])
    return "\n".join(lines).strip()


def resolve_summary(
    chunks: list[dict[str, Any]],
    title: str | None,
    generated: str | None = None,
) -> tuple[str, str]:
    material = fallback_source(chunks, title)
    abstract = abstract_text(chunks)
    if abstract:
        return abstract, "abstract"
    written = (generated or "").strip()
    if written:
        return written, "generated"
    return material, "extract"


def summary_point_id(source: str, library_id: str = "default") -> str:
    library = (library_id or "default").strip() or "default"
    name = f"chunky-summary:{source}" if library == "default" else f"chunky-summary:{library}:{source}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, name))


def summary_payload(
    *,
    text: str,
    kind: str,
    source: str,
    doc_title: str | None,
    authors: Any,
    year: int | None,
    document_id: str | None,
    doi: str | None = None,
    source_path: str | None = None,
    library_id: str = "default",
) -> dict[str, Any]:
    library = (library_id or "default").strip() or "default"
    payload: dict[str, Any] = {
        "text": text,
        "embedding_text": text,
        "source": source,
        "record_type": DOCUMENT_RECORD,
        "summary_kind": kind,
        "summary_metadata_version": 1,
        "content_type": "document",
        "library_id": library,
    }
    if doc_title:
        payload["doc_title"] = doc_title
    if isinstance(authors, list):
        joined = "; ".join(str(item) for item in authors if item)
        if joined:
            payload["authors"] = joined
    elif isinstance(authors, str) and authors.strip():
        payload["authors"] = authors.strip()
    if year is not None:
        payload["year"] = int(year)
    if document_id:
        payload["document_id"] = document_id
    if doi:
        payload["doi"] = doi
    if source_path:
        payload["source_path"] = source_path
    return payload
