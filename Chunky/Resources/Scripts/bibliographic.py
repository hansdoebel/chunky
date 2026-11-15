"""Bibliographic metadata from a stubbed LLM and an optional Crossref lookup."""

from __future__ import annotations

import json
import re
from typing import Any, Callable

FIELDS = ("doc_title", "authors", "year", "doi", "venue", "abstract")
PROTECTED = {"zotero", "bibtex"}
DOI_RE = re.compile(r"\b(10\.\d{4,9}/[-._;()/:A-Z0-9]+)\b", re.IGNORECASE)


def extract_doi(text: str) -> str | None:
    match = DOI_RE.search(text or "")
    if not match:
        return None
    return match.group(1).rstrip(".,)")


def parse_metadata_json(text: str) -> dict[str, Any]:
    raw = (text or "").strip()
    if not raw:
        return {}
    start = raw.find("{")
    end = raw.rfind("}")
    if start < 0 or end < start:
        return {}
    try:
        body = json.loads(raw[start : end + 1])
    except json.JSONDecodeError:
        return {}
    if not isinstance(body, dict):
        return {}
    return normalize_metadata(body)


def normalize_metadata(body: dict[str, Any]) -> dict[str, Any]:
    authors = body.get("authors")
    if isinstance(authors, str):
        authors = [part.strip() for part in authors.split(";") if part.strip()]
    elif isinstance(authors, list):
        authors = [str(item).strip() for item in authors if str(item).strip()]
    else:
        authors = []
    year = body.get("year")
    if isinstance(year, str) and year.isdigit():
        year = int(year)
    if not isinstance(year, int) or isinstance(year, bool):
        year = None
    doi = body.get("doi") or body.get("DOI")
    return {
        "doc_title": _text(body.get("doc_title") or body.get("title")),
        "authors": authors,
        "year": year,
        "doi": _text(doi),
        "venue": _text(body.get("venue") or body.get("container_title")),
        "abstract": _text(body.get("abstract")),
    }


def crossref_fields(payload: dict[str, Any]) -> dict[str, Any]:
    message = payload.get("message") if isinstance(payload.get("message"), dict) else payload
    title = message.get("title")
    if isinstance(title, list):
        title = title[0] if title else None
    authors = []
    for person in message.get("author") or []:
        if not isinstance(person, dict):
            continue
        name = " ".join(part for part in (person.get("given"), person.get("family")) if part)
        if name.strip():
            authors.append(name.strip())
    year = None
    issued = message.get("issued") or {}
    parts = issued.get("date-parts") if isinstance(issued, dict) else None
    if isinstance(parts, list) and parts and isinstance(parts[0], list) and parts[0]:
        if isinstance(parts[0][0], int):
            year = parts[0][0]
    container = message.get("container-title")
    if isinstance(container, list):
        container = container[0] if container else None
    return normalize_metadata(
        {
            "title": title,
            "authors": authors,
            "year": year,
            "doi": message.get("DOI"),
            "venue": container,
            "abstract": message.get("abstract"),
        }
    )


def missing_required(fields: dict[str, Any]) -> bool:
    if not fields.get("doc_title"):
        return True
    if not fields.get("authors"):
        return True
    return fields.get("year") is None


def current_fields(chunks: list[dict]) -> dict[str, Any]:
    first = chunks[0] if chunks else {}
    return normalize_metadata(
        {
            "doc_title": first.get("doc_title"),
            "authors": first.get("authors"),
            "year": first.get("year"),
            "doi": first.get("doi"),
            "venue": first.get("venue"),
            "abstract": first.get("abstract"),
        }
    )


def merge_fields(base: dict[str, Any], incoming: dict[str, Any], *, overwrite: bool) -> dict[str, Any]:
    merged = dict(base)
    for key in FIELDS:
        value = incoming.get(key)
        if value in (None, "", []):
            continue
        if overwrite or merged.get(key) in (None, "", []):
            merged[key] = value
    return merged


def apply_fields(chunks: list[dict], fields: dict[str, Any], source: str) -> None:
    for chunk in chunks:
        for key in FIELDS:
            value = fields.get(key)
            if value not in (None, "", []):
                chunk[key] = value
        chunk["metadata_source"] = source


def pages_for_metadata(pages: list[str], chunks: list[dict]) -> list[str]:
    if any(page and str(page).strip() for page in pages):
        return list(pages)
    texts = [str(chunk.get("text") or "").strip() for chunk in chunks]
    texts = [text for text in texts if text]
    if not texts:
        return []
    chosen = texts[:2]
    if len(texts) > 2:
        chosen.append(texts[-1])
    return chosen


def seed_document_fields(chunks: list[dict], document: dict[str, Any]) -> list[dict]:
    for chunk in chunks:
        for key in ("doc_title", "authors", "year", "doi"):
            if chunk.get(key) not in (None, "", []):
                continue
            value = document.get(key)
            if value in (None, "", []):
                continue
            chunk[key] = value
    return chunks


def front_matter(pages: list[str]) -> str:
    headings = {"references", "bibliography", "works cited", "literatur"}
    kept = []
    for page in pages[:2]:
        if not page:
            continue
        lines = []
        for line in str(page).splitlines():
            if line.strip().lower().rstrip(":") in headings:
                break
            lines.append(line)
        if lines:
            kept.append("\n".join(lines))
    return "\n".join(kept)


def document_doi(existing: Any, front_text: str, suggested: Any = None) -> str | None:
    if existing not in (None, "", []):
        return _text(existing)
    found = extract_doi(front_text)
    if found:
        return found
    suggested_text = _text(suggested)
    if suggested_text and suggested_text.lower() in (front_text or "").lower():
        return suggested_text
    return None


def prompt_for(pages: list[str], doi: str | None) -> str:
    sample = "\n\n".join(page.strip() for page in pages[:2] if page and page.strip())
    if len(pages) > 2 and pages[-1].strip():
        sample = f"{sample}\n\n{pages[-1].strip()}"
    return (
        "Return only JSON with keys doc_title, authors, year, doi, venue, abstract. "
        f"DOI hint: {doi or ''}\n\n{sample}"
    )


def enrich_chunks(
    chunks: list[dict],
    pages: list[str],
    *,
    llm: Callable[[str], str] | None = None,
    crossref: Callable[[str], dict[str, Any] | None] | None = None,
    imported_source: str | None = None,
) -> str:
    source = (imported_source or (chunks[0].get("metadata_source") if chunks else None) or "").strip().lower()
    if source in PROTECTED:
        apply_fields(chunks, current_fields(chunks), source)
        return source
    fields = current_fields(chunks)
    front = front_matter(pages)
    doi = document_doi(fields.get("doi"), front)
    if doi and not fields.get("doi"):
        fields["doi"] = doi
    chosen = "docling" if not missing_required(fields) else "pdf"
    visible = "\n".join(page.strip() for page in pages if page and str(page).strip())
    if llm is not None and missing_required(fields) and visible:
        parsed = parse_metadata_json(llm(prompt_for(pages, doi)))
        doi = document_doi(doi, front, parsed.get("doi"))
        if parsed.get("doi") and (doi is None or str(parsed.get("doi")).lower() != doi.lower()):
            parsed = dict(parsed)
            parsed["doi"] = None
        elif doi and not fields.get("doi"):
            parsed = dict(parsed)
            parsed["doi"] = doi
        fields = merge_fields(fields, parsed, overwrite=False)
        if not missing_required(fields) or any(parsed.get(key) for key in FIELDS):
            chosen = "llm"
    if crossref is not None and doi:
        confirmed = crossref(doi)
        if confirmed:
            fields = merge_fields(fields, confirmed, overwrite=True)
            chosen = "crossref"
    apply_fields(chunks, fields, chosen)
    return chosen


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
