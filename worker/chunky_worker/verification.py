"""Checks that ingested chunks and vectors still match the source PDF.

The report stores statuses, scores, and short spot-check previews. Chunk
bodies stay in the job result or the PDF-hash chunk cache.
"""

from __future__ import annotations

import hashlib
import importlib
import math
import re
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from chunky_worker.qdrant_ingest import content_hash, redact

GREEN_COVERAGE = 0.9
YELLOW_COVERAGE = 0.7
ATTRIBUTION_THRESHOLD = 0.55
VECTOR_GREEN = 0.98
VECTOR_YELLOW = 0.9
PREVIEW_CHARS = 80
VECTOR_SAMPLE = 3
RETRIEVAL_SAMPLE = 3
REQUIRED_PAYLOAD = ("text", "source", "content_hash")
_CACHE_FUNCTIONS = ("chunks_for_pdf_hash", "chunks_for_hash", "load_chunks")
_STATUS_RANK = {"skipped": -1, "green": 0, "yellow": 1, "red": 2}


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stable_chunk_id(pdf_hash: str, chunk: dict[str, Any], index: int) -> str:
    existing = str(chunk.get("id") or "").strip()
    if existing:
        return existing
    index_value = chunk.get("chunk_index", index)
    text = str(chunk.get("text") or "")
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"{pdf_hash}|{index_value}|{text}"))


def ensure_chunk_ids(chunks: list[dict[str, Any]], pdf_hash: str) -> None:
    for index, chunk in enumerate(chunks):
        chunk["id"] = stable_chunk_id(pdf_hash, chunk, index)


def cached_chunks(pdf_hash: str) -> list[dict[str, Any]] | None:
    """Read chunk records from the PDF-hash cache once that module exists."""
    try:
        module = importlib.import_module("chunky_worker.chunk_cache")
    except ImportError:
        return None
    for name in _CACHE_FUNCTIONS:
        finder = getattr(module, name, None)
        if not callable(finder):
            continue
        found = finder(pdf_hash)
        if not found:
            return None
        return [dict(item) for item in found]
    return None


def resolve_chunks(pdf_hash: str, fallback: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], str]:
    cached = cached_chunks(pdf_hash)
    if cached:
        ensure_chunk_ids(cached, pdf_hash)
        return cached, "cache"
    ensure_chunk_ids(fallback, pdf_hash)
    return fallback, "job"


def normalize_text(value: str) -> str:
    text = unicodedata.normalize("NFKC", value).lower().replace("\u00ad", "")
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def _shingles(words: list[str], size: int = 3) -> set[tuple[str, ...]]:
    if not words:
        return set()
    if len(words) < size:
        return {tuple(words)}
    return {tuple(words[index : index + size]) for index in range(len(words) - size + 1)}


def similarity(left: str, right: str) -> float:
    probe = _shingles(normalize_text(left).split())
    if not probe:
        return 1.0
    haystack = _shingles(normalize_text(right).split())
    return len(probe & haystack) / len(probe)


def _shingle_index(chunk_texts: list[str]) -> set[tuple[str, ...]]:
    indexed: set[tuple[str, ...]] = set()
    for text in chunk_texts:
        indexed.update(_shingles(normalize_text(text).split()))
    return indexed


def coverage_ratio(page_text: str, chunk_texts: list[str]) -> float:
    page = _shingles(normalize_text(page_text).split())
    if not page:
        return 1.0
    return len(page & _shingle_index(chunk_texts)) / len(page)


def status_for_coverage(coverage: float, *, green: float = GREEN_COVERAGE, yellow: float = YELLOW_COVERAGE) -> str:
    if coverage >= green:
        return "green"
    if coverage >= yellow:
        return "yellow"
    return "red"


def worst_status(statuses: list[str]) -> str:
    ranked = [status for status in statuses if status != "skipped"]
    if not ranked:
        return "green"
    return max(ranked, key=lambda status: _STATUS_RANK.get(status, 0))


def chunk_text(chunk: dict[str, Any]) -> str:
    embedding = chunk.get("embedding_text")
    if isinstance(embedding, str) and embedding.strip():
        return embedding
    return str(chunk.get("text") or "")


def claimed_pages(chunk: dict[str, Any]) -> list[int]:
    start = _page_number(chunk.get("page"))
    if start is None:
        return []
    end = _page_number(chunk.get("page_end")) or start
    if end < start:
        start, end = end, start
    return list(range(start, end + 1))


def _page_number(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _box_from(raw: dict[str, Any]) -> dict[str, Any] | None:
    try:
        box = {key: float(raw[key]) for key in ("l", "t", "r", "b")}
    except (KeyError, TypeError, ValueError):
        return None
    origin = str(raw.get("origin") or "bottom_left")
    box["origin"] = "top_left" if "top" in origin else "bottom_left"
    page = _page_number(raw.get("page"))
    if page is not None:
        box["page"] = page
    return box


def chunk_bbox(chunk: dict[str, Any], page: int | None = None) -> dict[str, Any] | None:
    raw_boxes: list[dict[str, Any]] = []
    single = chunk.get("bbox")
    if isinstance(single, dict):
        raw_boxes.append(single)
    many = chunk.get("bboxes")
    if isinstance(many, list):
        raw_boxes.extend(item for item in many if isinstance(item, dict))
    boxes = [box for item in raw_boxes if (box := _box_from(item)) is not None]
    if page is not None:
        exact = [box for box in boxes if box.get("page") == page]
        if exact:
            boxes = exact
    if not boxes:
        return None
    chosen = dict(boxes[0])
    chosen.pop("page", None)
    return chosen


def _page_checks(pages: list[str], chunks: list[dict[str, Any]], threshold: float) -> list[dict[str, Any]]:
    indexed = _shingle_index([chunk_text(chunk) for chunk in chunks])
    checks = []
    for number, page in enumerate(pages, start=1):
        flags: list[str] = []
        if not normalize_text(page):
            checks.append({"page": number, "status": "yellow", "coverage": 1.0, "flags": ["no extractable text"]})
            continue
        page_shingles = _shingles(normalize_text(page).split())
        ratio = 1.0 if not page_shingles else len(page_shingles & indexed) / len(page_shingles)
        status = status_for_coverage(ratio, green=threshold)
        if ratio < threshold:
            flags.append(f"coverage {ratio:.0%} is below {threshold:.0%}")
        checks.append({"page": number, "status": status, "coverage": round(ratio, 4), "flags": flags})
    return checks


def _attributions(pages: list[str], chunks: list[dict[str, Any]], threshold: float) -> list[dict[str, Any]]:
    by_number = {number: text for number, text in enumerate(pages, start=1)}
    rows = []
    for chunk in chunks:
        claimed = claimed_pages(chunk)
        claimed_text = " ".join(by_number.get(number, "") for number in claimed)
        score = similarity(chunk_text(chunk), claimed_text) if claimed else 0.0
        best_page = None
        best_score = -1.0
        for number, text in by_number.items():
            page_score = similarity(chunk_text(chunk), text)
            if page_score > best_score:
                best_score = page_score
                best_page = number
        matched = bool(claimed) and score >= threshold
        rows.append(
            {
                "chunk_id": str(chunk.get("id")),
                "page": claimed[0] if claimed else None,
                "page_end": claimed[-1] if claimed else None,
                "similarity": round(score, 4),
                "matched": matched,
                "suggested_page": None if matched or best_page is None else best_page,
            }
        )
    return rows


def _issues_for_point(
    chunk: dict[str, Any],
    point: dict[str, Any] | None,
    *,
    model: str,
    expected_dim: int | None,
) -> list[dict[str, str]]:
    chunk_id = str(chunk.get("id"))
    if point is None:
        return [{"chunk_id": chunk_id, "kind": "missing", "detail": "Chunk id is not in Qdrant"}]
    payload = point.get("payload") or {}
    issues = []
    for field in REQUIRED_PAYLOAD:
        if field not in payload or payload[field] in (None, ""):
            issues.append({"chunk_id": chunk_id, "kind": "payload", "detail": f"Missing payload field {field}"})
    expected_hash = content_hash(chunk_text(chunk), model)
    if payload.get("content_hash") not in (None, "") and payload.get("content_hash") != expected_hash:
        issues.append({"chunk_id": chunk_id, "kind": "content_hash", "detail": "content_hash does not match the chunk"})
    vector = point.get("vector") or []
    if expected_dim is not None and len(vector) != expected_dim:
        issues.append(
            {
                "chunk_id": chunk_id,
                "kind": "dimension",
                "detail": f"Vector length {len(vector)} does not match {expected_dim}",
            }
        )
    page = _page_number(chunk.get("page"))
    if page is not None and "page" in payload and _page_number(payload.get("page")) != page:
        issues.append({"chunk_id": chunk_id, "kind": "payload", "detail": "Payload page does not match the chunk"})
    return issues


def store_check(
    chunks: list[dict[str, Any]],
    points: list[dict[str, Any]] | None,
    *,
    model: str,
    expected_dim: int | None,
) -> dict[str, Any]:
    if points is None:
        return {"status": "skipped", "checked": 0, "issues": []}
    by_id = {str(point.get("id")): point for point in points}
    issues: list[dict[str, str]] = []
    for chunk in chunks:
        issues.extend(
            _issues_for_point(chunk, by_id.get(str(chunk.get("id"))), model=model, expected_dim=expected_dim)
        )
    return {"status": "red" if issues else "green", "checked": len(chunks), "issues": issues}


def cosine(left: list[float], right: list[float]) -> float:
    if not left or len(left) != len(right):
        return 0.0
    dot = sum(a * b for a, b in zip(left, right))
    left_norm = math.sqrt(sum(a * a for a in left))
    right_norm = math.sqrt(sum(b * b for b in right))
    if left_norm == 0 or right_norm == 0:
        return 0.0
    return dot / (left_norm * right_norm)


def _vector_status(score: float) -> str:
    if score >= VECTOR_GREEN:
        return "green"
    if score >= VECTOR_YELLOW:
        return "yellow"
    return "red"


def vector_spot_check(
    chunks: list[dict[str, Any]],
    vectors_by_id: dict[str, list[float]],
    embed: Callable[[list[str]], list[list[float]]] | None,
    *,
    sample: int = VECTOR_SAMPLE,
) -> dict[str, Any]:
    if embed is None or not vectors_by_id:
        return {"status": "skipped", "samples": []}
    chosen = [chunk for chunk in chunks if str(chunk.get("id")) in vectors_by_id][:sample]
    if not chosen:
        return {"status": "skipped", "samples": []}
    fresh = embed([chunk_text(chunk) for chunk in chosen])
    if len(fresh) != len(chosen):
        return {"status": "red", "samples": []}
    samples = []
    for chunk, vector in zip(chosen, fresh):
        stored = vectors_by_id[str(chunk.get("id"))]
        score = cosine(stored, list(vector))
        samples.append({"chunk_id": str(chunk.get("id")), "cosine": round(score, 4), "status": _vector_status(score)})
    return {"status": worst_status([item["status"] for item in samples]), "samples": samples}


def _sentences(page: str) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+", page.strip())
    return [part.strip() for part in parts if 8 <= len(part.split()) <= 30]


def sample_queries(pages: list[str], chunks: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    queries = []
    for number, page in enumerate(pages, start=1):
        for sentence in _sentences(page):
            best = None
            best_score = 0.0
            for chunk in chunks:
                score = similarity(sentence, chunk_text(chunk))
                if score > best_score:
                    best_score = score
                    best = chunk
            if best is None or best_score < 0.8:
                continue
            queries.append(
                {
                    "query": sentence,
                    "expected_chunk_id": str(best.get("id")),
                    "expected_page": number,
                }
            )
            if len(queries) >= limit:
                return queries
    return queries


def retrieval_self_test(
    pages: list[str],
    chunks: list[dict[str, Any]],
    search: Callable[[str], list[dict[str, Any]]] | None,
    *,
    sample: int = RETRIEVAL_SAMPLE,
) -> dict[str, Any]:
    if search is None or not pages:
        return {"status": "skipped", "queries": []}
    queries = []
    for item in sample_queries(pages, chunks, sample):
        hits = search(item["query"]) or []
        top = hits[0] if hits else {}
        top_page = _page_number((top.get("payload") or {}).get("page", top.get("page")))
        expected_id = item["expected_chunk_id"]
        claimed = claimed_pages(next((chunk for chunk in chunks if str(chunk.get("id")) == expected_id), {}))
        same_page = top_page == item["expected_page"]
        spanned = (
            top_page in claimed
            and item["expected_page"] in claimed
            and len(claimed) > 1
        )
        passed = str(top.get("id") or "") == expected_id and (same_page or spanned)
        queries.append(
            {
                **item,
                "top_chunk_id": str(top.get("id") or ""),
                "top_page": top_page,
                "passed": passed,
            }
        )
    if not queries:
        return {"status": "yellow", "queries": []}
    failed = any(not item["passed"] for item in queries)
    return {"status": "red" if failed else "green", "queries": queries}


def _preview(chunk: dict[str, Any]) -> str:
    text = " ".join(chunk_text(chunk).split())
    if len(text) <= PREVIEW_CHARS:
        return text
    return text[: PREVIEW_CHARS - 1].rstrip() + "…"


def _spot_checks(chunks: list[dict[str, Any]], attributions: list[dict[str, Any]], retrieval: dict[str, Any]) -> list[dict[str, Any]]:
    by_id = {str(chunk.get("id")): chunk for chunk in chunks}
    ordered: list[str] = []
    for row in attributions:
        if not row["matched"] and row["chunk_id"] not in ordered:
            ordered.append(row["chunk_id"])
    for query in retrieval.get("queries") or []:
        if not query["passed"] and query["expected_chunk_id"] not in ordered:
            ordered.append(query["expected_chunk_id"])
    if not ordered:
        for chunk in chunks:
            if chunk_bbox(chunk) is not None:
                ordered.append(str(chunk.get("id")))
                break
    checks = []
    for chunk_id in ordered[:3]:
        chunk = by_id.get(chunk_id)
        if chunk is None:
            continue
        claimed = claimed_pages(chunk)
        page = claimed[0] if claimed else None
        checks.append(
            {
                "chunk_id": chunk_id,
                "page": page,
                "bbox": chunk_bbox(chunk, page),
                "preview": _preview(chunk),
            }
        )
    return checks


def build_report(
    *,
    job_id: str | None,
    filename: str,
    pdf_hash: str,
    chunk_source: str,
    pages: list[str] | None,
    text_note: str | None,
    text_failed: bool = False,
    chunks: list[dict[str, Any]],
    points: list[dict[str, Any]] | None,
    vectors_by_id: dict[str, list[float]],
    embed: Callable[[list[str]], list[list[float]]] | None,
    search: Callable[[str], list[dict[str, Any]]] | None,
    model: str,
    expected_dim: int | None,
    page_width: float,
    page_height: float,
    coverage_threshold: float = GREEN_COVERAGE,
    attribution_threshold: float = ATTRIBUTION_THRESHOLD,
    now: str | None = None,
) -> dict[str, Any]:
    page_rows = _page_checks(pages or [], chunks, coverage_threshold) if pages is not None else []
    attributions = _attributions(pages or [], chunks, attribution_threshold) if pages is not None else []
    store = store_check(chunks, points, model=model, expected_dim=expected_dim)
    vectors = vector_spot_check(chunks, vectors_by_id, embed)
    retrieval = retrieval_self_test(pages or [], chunks, search if pages is not None else None)
    if text_failed:
        text_status = "red"
    elif pages is None:
        text_status = "skipped"
    else:
        text_status = worst_status([row["status"] for row in page_rows] or ["green"])
    attribution_status = "skipped" if pages is None else worst_status(
        ["green" if row["matched"] else "red" for row in attributions] or ["green"]
    )
    overall = worst_status([text_status, attribution_status, store["status"], vectors["status"], retrieval["status"]])
    return {
        "job_id": job_id,
        "filename": filename,
        "pdf_hash": pdf_hash,
        "chunk_source": chunk_source,
        "status": overall,
        "generated_at": now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "coverage_threshold": coverage_threshold,
        "page_size": {"width": page_width, "height": page_height},
        "text": {"status": text_status, "note": text_note},
        "pages": page_rows,
        "attributions": attributions,
        "store": store,
        "vector_spot_check": vectors,
        "retrieval": retrieval,
        "spot_checks": _spot_checks(chunks, attributions, retrieval),
    }


def _import_pdfium():
    try:
        import pypdfium2
    except ImportError:
        return None
    return pypdfium2


def _pages_pdfium(path: Path, module) -> list[str]:
    document = module.PdfDocument(str(path))
    try:
        pages = []
        for index in range(len(document)):
            text_page = document[index].get_textpage()
            pages.append(text_page.get_text_bounded() or "")
        return pages
    finally:
        document.close()


def _pages_pypdf(path: Path) -> list[str]:
    from pypdf import PdfReader

    reader = PdfReader(str(path))
    return [page.extract_text() or "" for page in reader.pages]


def extract_pdf_pages(path: Path) -> list[str]:
    """Extract each page on its own with pypdfium2, or pypdf when that is absent."""
    pdfium = _import_pdfium()
    if pdfium is not None:
        return _pages_pdfium(path, pdfium)
    return _pages_pypdf(path)


def pdf_page_size(path: Path) -> tuple[float, float]:
    try:
        from pypdf import PdfReader

        box = PdfReader(str(path)).pages[0].mediabox
        return float(box.width), float(box.height)
    except Exception:
        return 612.0, 792.0


def vector_list(value: Any) -> list[float]:
    if isinstance(value, dict):
        chosen = value.get("dense")
        if chosen is None and value:
            chosen = next(iter(value.values()))
        value = chosen
    if not isinstance(value, (list, tuple)):
        return []
    try:
        return [float(item) for item in value]
    except (TypeError, ValueError):
        return []


def fetch_qdrant_points(
    *,
    url: str,
    api_key: str,
    collection: str,
    ids: list[str],
    client_factory: Callable[..., Any] | None = None,
) -> list[dict[str, Any]]:
    if client_factory is None:
        from qdrant_client import QdrantClient

        client_factory = QdrantClient
    client = client_factory(url=url, api_key=api_key or None)
    try:
        records = client.retrieve(
            collection_name=collection,
            ids=ids,
            with_payload=True,
            with_vectors=True,
        )
    except Exception as exc:
        raise RuntimeError(redact(str(exc), api_key)) from None
    finally:
        close = getattr(client, "close", None)
        if callable(close):
            close()
    points = []
    for record in records:
        payload = getattr(record, "payload", None) or {}
        points.append(
            {
                "id": str(getattr(record, "id")),
                "vector": vector_list(getattr(record, "vector", None)),
                "payload": dict(payload),
            }
        )
    return points


def verify_document(
    *,
    pdf_path: Path | None,
    chunks: list[dict[str, Any]],
    filename: str,
    job_id: str | None = None,
    pdf_hash: str | None = None,
    model: str = "",
    vectors: list[list[float]] | None = None,
    expected_dim: int | None = None,
    points: list[dict[str, Any]] | None = None,
    embed: Callable[[list[str]], list[list[float]]] | None = None,
    search: Callable[[str], list[dict[str, Any]]] | None = None,
    extract_pages: Callable[[Path], list[str]] | None = None,
    now: str | None = None,
) -> dict[str, Any]:
    digest = pdf_hash or (hash_file(pdf_path) if pdf_path is not None else "")
    resolved, source = resolve_chunks(digest, chunks)
    pages = None
    note = None
    text_failed = False
    width, height = 612.0, 792.0
    if pdf_path is None or pdf_path.suffix.lower() != ".pdf":
        note = "not a pdf"
    else:
        width, height = pdf_page_size(pdf_path)
        try:
            pages = (extract_pages or extract_pdf_pages)(pdf_path)
        except Exception as exc:
            note = redact(str(exc), None)[:200]
            text_failed = True
    by_id: dict[str, list[float]] = {}
    if vectors:
        stamped = [dict(chunk) for chunk in chunks]
        ensure_chunk_ids(stamped, digest)
        for chunk, vector in zip(stamped, vectors):
            by_id[str(chunk["id"])] = list(vector)
    return build_report(
        job_id=job_id,
        filename=filename,
        pdf_hash=digest,
        chunk_source=source,
        pages=pages,
        text_note=note,
        text_failed=text_failed,
        chunks=resolved,
        points=points,
        vectors_by_id=by_id,
        embed=embed,
        search=search,
        model=model,
        expected_dim=expected_dim,
        page_width=width,
        page_height=height,
        now=now,
    )
