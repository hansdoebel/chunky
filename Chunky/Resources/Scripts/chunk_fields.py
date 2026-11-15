"""Fields copied from a Docling chunk into the JSON the Mac and worker share."""

from __future__ import annotations

PICTURE_LABELS = {"picture", "figure", "chart"}
TABLE_LABELS = {"table"}

def _label(item) -> str:
    label = getattr(item, "label", "")
    value = getattr(label, "value", label)
    return str(value or "").strip().lower()

def _text(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None

def _class_name(entry) -> tuple[str | None, float | None]:
    if isinstance(entry, dict):
        name = _text(entry.get("class_name") or entry.get("class"))
        score = entry.get("confidence")
    else:
        name = _text(getattr(entry, "class_name", None) or getattr(entry, "class", None))
        score = getattr(entry, "confidence", None)
    if not isinstance(score, (int, float)):
        score = None
    return name, score

def _best_class(classes) -> str | None:
    best_name = None
    best_score = None
    for entry in classes or []:
        name, score = _class_name(entry)
        if name is None:
            continue
        if best_name is None or (score is not None and (best_score is None or score > best_score)):
            best_name = name
            best_score = score
    return best_name

def _picture_fields(item) -> tuple[str | None, str | None]:
    description = None
    classification = None
    for annotation in getattr(item, "annotations", None) or []:
        if description is None:
            description = _text(getattr(annotation, "text", None))
            if description is None and isinstance(annotation, dict):
                description = _text(annotation.get("text"))
        if classification is None:
            classes = getattr(annotation, "predicted_classes", None)
            if classes is None and isinstance(annotation, dict):
                classes = annotation.get("predicted_classes")
            classification = _best_class(classes)
            if classification is None:
                classification = _text(getattr(annotation, "class_name", None))
    if description is None:
        captions = []
        for caption in getattr(item, "captions", None) or []:
            if isinstance(caption, str):
                text = _text(caption)
            else:
                text = _text(getattr(caption, "text", None))
            if text:
                captions.append(text)
        if captions:
            description = "\n".join(captions)
    return description, classification

def _markdown_cell(cell) -> str:
    if isinstance(cell, dict):
        text = cell.get("text")
    else:
        text = getattr(cell, "text", "")
    return str(text or "").replace("\n", " ").replace("|", "\\|").strip()

def _markdown_from_grid(grid) -> str | None:
    rows = []
    for row in grid or []:
        cells = [_markdown_cell(cell) for cell in row]
        if any(cells):
            rows.append("| " + " | ".join(cells) + " |")
    if not rows:
        return None
    columns = max(row.count("|") - 1 for row in rows)
    separator = "| " + " | ".join(["---"] * max(columns, 1)) + " |"
    return "\n".join([rows[0], separator, *rows[1:]])

def _table_markdown(item, doc) -> str | None:
    exporter = getattr(item, "export_to_markdown", None)
    if callable(exporter):
        for args in ((doc,), tuple()):
            try:
                rendered = exporter(*args)
            except TypeError:
                continue
            except Exception:
                rendered = None
            text = _text(rendered)
            if text:
                return text
    data = getattr(item, "data", None)
    grid = getattr(data, "grid", None) if data is not None else None
    if grid is None and isinstance(data, dict):
        grid = data.get("grid")
    if grid is None and isinstance(item, dict):
        grid = item.get("grid") or (item.get("data") or {}).get("grid")
    return _markdown_from_grid(grid)

def visual_fields(doc_items, doc=None) -> dict[str, str]:
    """Picture description, picture class, and table markdown for one chunk."""
    description = None
    classification = None
    tables: list[str] = []
    for item in doc_items or []:
        label = _label(item)
        if label in PICTURE_LABELS or label.endswith("picture"):
            found_description, found_class = _picture_fields(item)
            if description is None and found_description:
                description = found_description
            if classification is None and found_class:
                classification = found_class
        if label in TABLE_LABELS or label.endswith("table"):
            markdown = _table_markdown(item, doc)
            if markdown:
                tables.append(markdown)
    fields: dict[str, str] = {}
    if description:
        fields["picture_description"] = description
    if classification:
        fields["picture_class"] = classification
    if tables:
        fields["table_markdown"] = "\n\n".join(tables)
    return fields

def _prov_entries(item) -> list:
    prov = getattr(item, "prov", None)
    if isinstance(item, dict) and prov is None:
        prov = item.get("prov")
    if not prov:
        return []
    if isinstance(prov, list):
        return prov
    return [prov]


def _page_number_of(entry) -> int | None:
    page = getattr(entry, "page_no", None)
    if page is None and isinstance(entry, dict):
        page = entry.get("page_no")
    if isinstance(page, bool):
        return None
    if isinstance(page, int):
        return page
    if isinstance(page, float) and page.is_integer():
        return int(page)
    return None


def _page_label_of(entry) -> str | None:
    label = getattr(entry, "page_label", None)
    if label is None and isinstance(entry, dict):
        label = entry.get("page_label")
    return _text(label)


def _bbox_of(entry) -> dict[str, float] | None:
    box = getattr(entry, "bbox", None)
    if box is None and isinstance(entry, dict):
        box = entry.get("bbox")
    if box is None:
        return None

    def coord(name: str):
        value = box.get(name) if isinstance(box, dict) else getattr(box, name, None)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)

    coords = {name: coord(name) for name in ("l", "t", "r", "b")}
    if any(value is None for value in coords.values()):
        return None
    return coords


def provenance(doc_items) -> dict:
    """Page span, printed labels when present, and boxes from Docling provenance."""
    pages: list[int] = []
    labels: list[str] = []
    boxes: list[dict] = []
    for item in doc_items or []:
        for entry in _prov_entries(item):
            page = _page_number_of(entry)
            if page is not None and page not in pages:
                pages.append(page)
            label = _page_label_of(entry)
            if label and label not in labels:
                labels.append(label)
            box = _bbox_of(entry)
            if box is not None:
                recorded = dict(box)
                if page is not None:
                    recorded["page"] = page
                boxes.append(recorded)
    pages = sorted(pages)
    fields: dict = {}
    if pages:
        fields["page"] = pages[0]
        fields["page_end"] = pages[-1]
        fields["pages"] = pages
    if labels:
        fields["page_labels"] = labels
    if boxes:
        fields["bboxes"] = boxes
    return fields

def document_identity(doc) -> dict:
    description = getattr(doc, "description", None) if doc is not None else None
    origin = getattr(doc, "origin", None) if doc is not None else None
    title = _text(getattr(description, "title", None) if description is not None else None)
    if title is None and doc is not None:
        title = _text(getattr(doc, "name", None))
    authors = getattr(description, "authors", None) if description is not None else None
    if not isinstance(authors, list):
        authors = []
    else:
        authors = [str(author) for author in authors if _text(author)]
    return {
        "doc_title": title,
        "authors": authors,
        "year": None,
        "doi": _text(getattr(description, "doi", None) if description is not None else None),
        "source": _text(getattr(origin, "filename", None) if origin is not None else None) or "",
    }


def record_from_chunk(chunk, index: int, chunker, doc=None) -> dict:
    """One chunk dict. ``text`` stays raw. ``embedding_text`` is the serialized form."""
    contextualized = chunker.serialize(chunk)
    items = []
    meta = getattr(chunk, "meta", None)
    if meta is not None and getattr(meta, "doc_items", None):
        items = list(meta.doc_items)
    content_type = "text"
    if items:
        label = _label(items[0])
        if label:
            content_type = label
    headings = []
    if meta is not None and getattr(meta, "headings", None):
        headings = [str(heading) for heading in meta.headings]
    token_count = chunker.tokenizer.count_tokens(chunk.text)
    located = provenance(items)
    record = {
        "text": chunk.text,
        "embedding_text": contextualized,
        "page": located.get("page"),
        "headings": headings,
        "content_type": content_type,
        "chunk_index": index,
        "token_count": token_count,
    }
    for key in ("page_end", "pages", "page_labels", "bboxes"):
        if key in located:
            record[key] = located[key]
    record.update(document_identity(doc))
    record.update(visual_fields(items, doc))
    return record
