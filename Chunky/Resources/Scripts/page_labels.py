"""Printed page labels from a PDF /PageLabels tree or a journal offset."""

from __future__ import annotations

from pathlib import Path


_ROMAN = (
    (1000, "M"),
    (900, "CM"),
    (500, "D"),
    (400, "CD"),
    (100, "C"),
    (90, "XC"),
    (50, "L"),
    (40, "XL"),
    (10, "X"),
    (9, "IX"),
    (5, "V"),
    (4, "IV"),
    (1, "I"),
)


def to_roman(number: int, upper: bool = True) -> str:
    value = max(1, int(number))
    parts: list[str] = []
    for weight, glyph in _ROMAN:
        while value >= weight:
            parts.append(glyph)
            value -= weight
    text = "".join(parts)
    return text if upper else text.lower()


def to_alpha(number: int, upper: bool = True) -> str:
    value = max(1, int(number))
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" if upper else "abcdefghijklmnopqrstuvwxyz"
    index = (value - 1) % 26
    repeats = (value - 1) // 26 + 1
    return letters[index] * repeats


def format_label(number: int, style: str | None, prefix: str = "") -> str:
    kind = style or "D"
    if kind == "R":
        body = to_roman(number, upper=True)
    elif kind == "r":
        body = to_roman(number, upper=False)
    elif kind == "A":
        body = to_alpha(number, upper=True)
    elif kind == "a":
        body = to_alpha(number, upper=False)
    else:
        body = str(max(1, int(number)))
    return f"{prefix}{body}"


def labels_from_ranges(page_count: int, ranges: list[dict]) -> list[str]:
    ordered = sorted(ranges, key=lambda item: int(item.get("start") or 0))
    labels: list[str] = []
    for index in range(max(0, page_count)):
        chosen = None
        for item in ordered:
            if int(item.get("start") or 0) <= index:
                chosen = item
            else:
                break
        if chosen is None:
            labels.append(str(index + 1))
            continue
        start = int(chosen.get("start") or 0)
        first = int(chosen.get("first") or 1)
        labels.append(format_label(first + (index - start), chosen.get("style"), str(chosen.get("prefix") or "")))
    return labels


def labels_from_offset(page_count: int, first_printed: int) -> list[str]:
    start = int(first_printed)
    return [str(start + index) for index in range(max(0, page_count))]


def read_pdf_labels(path: str | Path) -> list[str] | None:
    try:
        from pypdf import PdfReader
    except ImportError:
        return None
    reader = PdfReader(str(path))
    root = reader.root_object
    if root is None or "/PageLabels" not in root:
        return None
    labels = list(reader.page_labels)
    return labels or None


def resolve_labels(path: str | Path | None, page_count: int, page_offset: int | None) -> list[str] | None:
    if page_offset is not None:
        return labels_from_offset(page_count, page_offset)
    if path is None:
        return None
    pdf = Path(path)
    if pdf.suffix.lower() != ".pdf" or not pdf.is_file():
        return None
    return read_pdf_labels(pdf)


def citation_text(labels: list[str]) -> str | None:
    cleaned = [str(item) for item in labels if str(item).strip()]
    if not cleaned:
        return None
    if len(cleaned) == 1:
        return f"p. {cleaned[0]}"
    return f"pp. {cleaned[0]}–{cleaned[-1]}"


def chunk_pages(chunk: dict) -> list[int]:
    pages = [page for page in chunk.get("pages") or [] if isinstance(page, int) and page >= 1]
    if pages:
        return pages
    page = chunk.get("page")
    page_end = chunk.get("page_end")
    if isinstance(page, int) and page >= 1:
        end = page_end if isinstance(page_end, int) and page_end >= page else page
        return list(range(page, end + 1))
    return []


def annotate_chunks(chunks: list[dict], labels: list[str] | None, page_offset: int | None = None) -> list[dict]:
    if not labels:
        return chunks
    for chunk in chunks:
        chosen = []
        for page in chunk_pages(chunk):
            if page <= len(labels):
                chosen.append(labels[page - 1])
        if chosen:
            chunk["page_labels"] = chosen
            printed = citation_text(chosen)
            if printed:
                chunk["printed_page"] = printed
        if page_offset is not None:
            chunk["page_offset"] = int(page_offset)
    return chunks


def apply_printed_labels(chunks: list[dict], pdf_path: str | Path | None, page_offset: int | None) -> list[dict]:
    if not chunks:
        return chunks
    highest = 0
    for chunk in chunks:
        for page in chunk_pages(chunk):
            highest = max(highest, page)
    count = highest
    if pdf_path is not None and page_offset is None:
        try:
            from pypdf import PdfReader

            count = max(count, len(PdfReader(str(pdf_path)).pages))
        except Exception:
            pass
    labels = resolve_labels(pdf_path, count, page_offset)
    return annotate_chunks(chunks, labels, page_offset)
