"""Reference-list parsing and best-effort in-text links."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from typing import Any

from bibliographic import extract_doi

REF_HEADINGS = {"references", "bibliography", "works cited", "literatur"}
STOP_HEADINGS = {"appendix", "acknowledgement", "acknowledgements", "acknowledgments"}
IEEE_RE = re.compile(r"\[(\d+)\]\s*(.*?)(?=\n\s*\[\d+\]|\Z)", re.S)
APA_RE = re.compile(r"^(.+?)\s+\((\d{4})\)\.\s+(.+?)\.\s+(.+?)\.?\s*$", re.M)
CITE_RE = re.compile(r"\[(\d+(?:\s*[-,]\s*\d+)*)\]")


def _heading_names(chunk: dict[str, Any]) -> list[str]:
    names = []
    for heading in chunk.get("headings") or []:
        name = str(heading).strip().lower().rstrip(":")
        if name:
            names.append(name)
    return names


def section_text(chunks: list[dict[str, Any]]) -> str:
    started = False
    parts: list[str] = []
    for chunk in chunks:
        names = _heading_names(chunk)
        if any(name in REF_HEADINGS for name in names):
            started = True
        elif started and any(name in STOP_HEADINGS for name in names):
            break
        if not started:
            continue
        text = str(chunk.get("text") or "").strip()
        if text:
            parts.append(text)
    return "\n".join(parts)


def _authors(value: str) -> list[str]:
    cleaned = value.strip(" ,;")
    if not cleaned:
        return []
    parts = re.split(r"\s+and\s+|;\s*", cleaned)
    return [part.strip(" ,") for part in parts if part.strip(" ,")]


def _record(index: int | None, body: str, *, authors: list[str], title: str | None, year: int | None, venue: str | None) -> dict[str, Any]:
    return {
        "index": index,
        "authors": authors,
        "title": title,
        "year": year,
        "venue": venue,
        "doi": extract_doi(body),
        "raw": " ".join(body.split()),
    }


def _parse_ieee(text: str) -> list[dict[str, Any]]:
    records = []
    for match in IEEE_RE.finditer(text):
        body = " ".join(match.group(2).split())
        if not body:
            continue
        title_match = re.search(r"[\"“](.+?)[\"”]", body)
        year_match = re.search(r"\b(1[89]\d{2}|20\d{2})\b", body)
        title = title_match.group(1).strip(" ,.") if title_match else None
        year = int(year_match.group(1)) if year_match else None
        authors: list[str] = []
        venue = None
        if title_match:
            authors = _authors(body[: title_match.start()])
        if title_match and year_match and title_match.end() < year_match.start():
            venue = body[title_match.end() : year_match.start()].strip(" ,.;")
            venue = re.sub(r"^(vol\.?\s*\d+\s*,?\s*)", "", venue, flags=re.I).strip(" ,.;") or None
        records.append(_record(int(match.group(1)), body, authors=authors, title=title, year=year, venue=venue))
    return records


def _parse_apa(text: str) -> list[dict[str, Any]]:
    records = []
    for index, match in enumerate(APA_RE.finditer(text), start=1):
        authors = _authors(match.group(1).replace("&", " and "))
        title = match.group(3).strip()
        venue = match.group(4).strip(" .")
        body = " ".join(match.group(0).split())
        records.append(
            _record(index, body, authors=authors, title=title or None, year=int(match.group(2)), venue=venue or None)
        )
    return records


def _unparsed(text: str) -> dict[str, Any]:
    collapsed = " ".join(text.split())
    return {
        "index": None,
        "authors": [],
        "title": None,
        "year": None,
        "venue": None,
        "doi": extract_doi(collapsed),
        "raw": collapsed,
    }


def _gaps(text: str, spans: list[tuple[int, int]]) -> list[str]:
    pieces = []
    cursor = 0
    for start, end in spans:
        gap = text[cursor:start].strip()
        if gap:
            pieces.append(gap)
        cursor = end
    tail = text[cursor:].strip()
    if tail:
        pieces.append(tail)
    return pieces


def parse_reference_list(text: str) -> tuple[list[dict[str, Any]], list[str]]:
    raw = (text or "").strip()
    if not raw:
        return [], []
    numbered = list(IEEE_RE.finditer(raw))
    if numbered:
        records = _parse_ieee(raw)
        warnings = ["unparsed reference block" for record in records if not record["title"] and record["year"] is None]
        for gap in _gaps(raw, [match.span() for match in numbered]):
            records.append(_unparsed(gap))
            warnings.append("unparsed reference block")
        return records, warnings
    named = list(APA_RE.finditer(raw))
    if named:
        records = _parse_apa(raw)
        warnings = []
        for gap in _gaps(raw, [match.span() for match in named]):
            records.append(_unparsed(gap))
            warnings.append("unparsed reference block")
        return records, warnings
    return [_unparsed(raw)], ["unparsed reference block"]


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _child_text(node: ET.Element, name: str) -> str | None:
    for child in node.iter():
        if _local(child.tag) == name and child.text and child.text.strip():
            return child.text.strip()
    return None


def references_from_grobid(xml_text: str) -> list[dict[str, Any]]:
    if not xml_text or not str(xml_text).strip():
        return []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []
    records = []
    lists = [node for node in root.iter() if _local(node.tag) == "listBibl"]
    entries = [child for parent in lists for child in parent if _local(child.tag) == "biblStruct"]
    for index, bibl in enumerate(entries, start=1):
        authors = []
        for person in bibl.iter():
            if _local(person.tag) != "persName":
                continue
            given = ""
            family = ""
            for part in person:
                if _local(part.tag) == "forename" and part.text:
                    given = part.text.strip()
                if _local(part.tag) == "surname" and part.text:
                    family = part.text.strip()
            name = " ".join(part for part in (given, family) if part)
            if name:
                authors.append(name)
        analytic = next((node for node in bibl if _local(node.tag) == "analytic"), None)
        monogr = next((node for node in bibl if _local(node.tag) == "monogr"), None)
        title = _child_text(analytic, "title") if analytic is not None else None
        venue = _child_text(monogr, "title") if monogr is not None else None
        if title is None:
            title = venue
            venue = None
        year = None
        for node in bibl.iter():
            if _local(node.tag) != "date":
                continue
            when = node.attrib.get("when") or (node.text or "")
            found = re.search(r"\b(1[89]\d{2}|20\d{2})\b", when)
            if found:
                year = int(found.group(1))
                break
        doi = None
        for node in bibl.iter():
            if _local(node.tag) == "idno" and node.attrib.get("type", "").lower() == "doi" and node.text:
                doi = extract_doi(node.text) or node.text.strip()
        records.append(
            {
                "index": index,
                "authors": authors,
                "title": title,
                "year": year,
                "venue": venue,
                "doi": doi,
                "raw": title or "",
            }
        )
    return records


def resolve_references(section: str, grobid_xml: str | None = None) -> tuple[list[dict[str, Any]], list[str]]:
    if grobid_xml:
        parsed = references_from_grobid(grobid_xml)
        if parsed:
            return parsed, []
    return parse_reference_list(section)


def _last_name(author: str) -> str:
    author = author.strip()
    if not author:
        return ""
    if "," in author:
        return author.split(",", 1)[0].strip()
    parts = author.split()
    return parts[-1] if parts else ""


def _compact(record: dict[str, Any]) -> dict[str, Any]:
    compact = {}
    for key in ("index", "authors", "title", "year", "doi"):
        value = record.get(key)
        if value not in (None, "", []):
            compact[key] = value
    return compact


def cited_in_text(text: str, references: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_index = {record.get("index"): record for record in references if isinstance(record.get("index"), int)}
    known = set(by_index)
    wanted: list[int] = []
    for match in CITE_RE.finditer(text or ""):
        for part in re.split(r"\s*,\s*", match.group(1)):
            ends = [piece.strip() for piece in part.split("-", 1)]
            if len(ends) == 2 and ends[0].isdigit() and ends[1].isdigit():
                start, stop = int(ends[0]), int(ends[1])
                if start > stop:
                    start, stop = stop, start
                wanted.extend(index for index in sorted(known) if start <= index <= stop)
            elif part.strip().isdigit():
                wanted.append(int(part.strip()))
    for record in references:
        authors = record.get("authors") or []
        year = record.get("year")
        index = record.get("index")
        if not authors or year is None or index is None:
            continue
        name = re.escape(_last_name(str(authors[0])))
        if not name:
            continue
        year_text = re.escape(str(year))
        if re.search(rf"\b{name}\s+et\s+al\.?,?\s*{year_text}\b", text or "", re.I) or re.search(
            rf"\b{name},?\s+{year_text}\b", text or "", re.I
        ):
            wanted.append(index)
    seen = set()
    ordered = []
    for index in wanted:
        if index in seen or index not in by_index:
            continue
        seen.add(index)
        ordered.append(_compact(by_index[index]))
    return ordered


def link_citations(chunks: list[dict[str, Any]], references: list[dict[str, Any]]) -> None:
    started = False
    for chunk in chunks:
        names = _heading_names(chunk)
        if any(name in REF_HEADINGS for name in names):
            started = True
        elif started and any(name in STOP_HEADINGS for name in names):
            started = False
        if started:
            chunk["cited_references"] = []
            continue
        chunk["cited_references"] = cited_in_text(str(chunk.get("text") or ""), references)


def attach_references(
    chunks: list[dict[str, Any]],
    section: str,
    grobid_xml: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str]]:
    try:
        references, warnings = resolve_references(section, grobid_xml)
        link_citations(chunks, references)
    except (ValueError, ET.ParseError):
        return chunks, [], ["reference parsing failed"]
    if chunks and references:
        chunks[0]["references"] = references
    return chunks, references, warnings
