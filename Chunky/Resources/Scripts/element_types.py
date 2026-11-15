"""Canonical chunk element types shared by conversion and retrieval filters."""

from __future__ import annotations

from typing import Any

CANONICAL = ("text", "table", "formula", "figure", "code")
ALIASES = {
    "paragraph": "text",
    "section": "text",
    "list": "text",
    "title": "text",
    "caption": "text",
    "narrative": "text",
    "narrativetext": "text",
    "picture": "figure",
    "image": "figure",
    "chart": "figure",
    "equation": "formula",
}
PRIORITY = ("formula", "table", "figure", "code", "text")


def canonical_type(label: str | None) -> str | None:
    if label is None:
        return None
    name = str(label).strip().lower()
    if not name or name == "document":
        return None
    if name in CANONICAL:
        return name
    if name in ALIASES:
        return ALIASES[name]
    if name.endswith("picture") or name.endswith("figure"):
        return "figure"
    if name.endswith("table"):
        return "table"
    if name.endswith("formula") or name.endswith("equation"):
        return "formula"
    if name.endswith("code"):
        return "code"
    return "text"


def classify(labels: list[str] | None, existing: str | None = None) -> tuple[str, list[str]] | None:
    found: list[str] = []
    for label in labels or []:
        kind = canonical_type(label)
        if kind and kind not in found:
            found.append(kind)
    if not found:
        kind = canonical_type(existing)
        if kind is None:
            return None
        found = [kind]
    primary = next((kind for kind in PRIORITY if kind in found), found[0])
    ordered = [primary, *[kind for kind in found if kind != primary]]
    return primary, ordered


def element_filter_kind(value: str) -> str | None:
    name = str(value or "").strip().lower()
    if name in CANONICAL or name in ALIASES:
        return canonical_type(name)
    return None


def stored_values(kind: str) -> list[str]:
    canonical = canonical_type(kind) or kind
    values = [canonical]
    if canonical == "figure":
        values.append("picture")
    return values


def formula_source(item: Any) -> str | None:
    for name in ("latex", "text", "orig", "code"):
        value = getattr(item, name, None)
        if value is None and isinstance(item, dict):
            value = item.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    exporter = getattr(item, "export_to_doctags", None)
    if callable(exporter):
        try:
            rendered = exporter()
        except Exception:
            rendered = None
        if isinstance(rendered, str) and rendered.strip():
            return rendered.strip()
    return None


def embedding_fallback(text: str, embedding: str, items: list[Any], primary: str) -> str:
    if embedding.strip() or primary != "formula":
        return embedding
    for item in items:
        label = getattr(item, "label", None)
        if isinstance(label, dict):
            label = label.get("value")
        else:
            label = getattr(label, "value", label)
        kind = canonical_type(str(label) if label is not None else None)
        if kind != "formula":
            continue
        source = formula_source(item)
        if source:
            return source
    if text.strip():
        return text
    return embedding
