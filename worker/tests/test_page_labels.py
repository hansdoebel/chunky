"""Printed page labels from a PDF number tree or a journal offset."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from page_labels import (  # noqa: E402
    annotate_chunks,
    apply_printed_labels,
    citation_text,
    labels_from_offset,
    labels_from_ranges,
    read_pdf_labels,
    to_roman,
)


def test_roman_and_decimal_ranges():
    labels = labels_from_ranges(
        5,
        [
            {"start": 0, "style": "r", "prefix": "", "first": 1},
            {"start": 2, "style": "D", "prefix": "", "first": 1847},
        ],
    )
    assert labels == ["i", "ii", "1847", "1848", "1849"]
    assert to_roman(4) == "IV"
    assert to_roman(9, upper=False) == "ix"


def test_missing_tree_is_omitted_until_an_offset_is_set(tmp_path):
    from pypdf import PdfWriter

    plain = tmp_path / "plain.pdf"
    writer = PdfWriter()
    writer.add_blank_page(width=72, height=72)
    writer.add_blank_page(width=72, height=72)
    with plain.open("wb") as handle:
        writer.write(handle)
    assert read_pdf_labels(plain) is None

    chunks = [{"text": "a", "page": 1, "page_end": 2}]
    assert apply_printed_labels(chunks, plain, None)[0].get("page_labels") is None

    labeled = apply_printed_labels([{"text": "a", "page": 1}, {"text": "b", "page": 2}], plain, 1847)
    assert labeled[0]["page_labels"] == ["1847"]
    assert labeled[1]["page_labels"] == ["1848"]
    assert labeled[0]["printed_page"] == "p. 1847"
    assert labeled[0]["page_offset"] == 1847
    assert labels_from_offset(3, 10) == ["10", "11", "12"]


def test_pdf_label_tree_and_offset_override(tmp_path):
    from pypdf.constants import PageLabelStyle
    from pypdf import PdfWriter

    path = tmp_path / "journal.pdf"
    writer = PdfWriter()
    for _ in range(4):
        writer.add_blank_page(width=72, height=72)
    writer.set_page_label(0, 1, style=PageLabelStyle.LOWERCASE_ROMAN, start=1)
    writer.set_page_label(2, 3, style=PageLabelStyle.DECIMAL, start=1847)
    with path.open("wb") as handle:
        writer.write(handle)

    labels = read_pdf_labels(path)
    assert labels[:4] == ["i", "ii", "1847", "1848"]

    chunk = {"text": "span", "page": 2, "page_end": 3}
    annotated = annotate_chunks([chunk], labels, None)
    assert annotated[0]["page_labels"] == ["ii", "1847"]
    assert annotated[0]["printed_page"] == "pp. ii–1847"
    assert citation_text(["1847", "1848", "1849"]) == "pp. 1847–1849"

    overridden = apply_printed_labels([{"text": "x", "pages": [1, 4]}], path, 5)
    assert overridden[0]["page_labels"] == ["5", "8"]
    assert overridden[0]["page_offset"] == 5


def test_offset_beats_a_wrong_tree():
    labels = labels_from_ranges(2, [{"start": 0, "style": "D", "prefix": "", "first": 1}])
    chunk = {"text": "body", "pages": [1, 2]}
    annotated = annotate_chunks([dict(chunk)], labels_from_offset(2, 200), 200)
    assert annotated[0]["page_labels"] == ["200", "201"]
    assert annotated[0]["printed_page"] == "pp. 200–201"
