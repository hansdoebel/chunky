"""Chunk records keep raw text, serialized text, and picture or table fields."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from chunk_fields import record_from_chunk, visual_fields  # noqa: E402

class Tokenizer:
    def count_tokens(self, text: str) -> int:
        return len(text.split())

class Chunker:
    tokenizer = Tokenizer()

    def serialize(self, chunk) -> str:
        return chunk.serialized

def _chunk(text, serialized, items, headings=None):
    return SimpleNamespace(
        text=text,
        serialized=serialized,
        meta=SimpleNamespace(doc_items=items, headings=headings or []),
    )

def test_plain_text_has_no_visual_fields():
    item = SimpleNamespace(label="text", prov=[SimpleNamespace(page_no=2)], annotations=[])
    record = record_from_chunk(_chunk("Hello", "Hello", [item], ["Intro"]), 0, Chunker())
    assert record["text"] == "Hello"
    assert record["embedding_text"] == "Hello"
    assert record["content_type"] == "text"
    assert record["page"] == 2
    assert record["page_end"] == 2
    assert record["pages"] == [2]
    assert record["headings"] == ["Intro"]
    assert "picture_description" not in record
    assert "table_markdown" not in record

def test_span_keeps_every_page_box_and_printed_label():
    first = SimpleNamespace(
        label="text",
        prov=[
            SimpleNamespace(page_no=3, page_label="12", bbox=SimpleNamespace(l=1, t=2, r=3, b=4)),
            SimpleNamespace(page_no=4, page_label=None, bbox=SimpleNamespace(l=0, t=10, r=20, b=0)),
        ],
        annotations=[],
    )
    record = record_from_chunk(_chunk("Across", "Across", [first], ["Methods", "Setup"]), 2, Chunker())
    assert record["page"] == 3
    assert record["page_end"] == 4
    assert record["pages"] == [3, 4]
    assert record["page_labels"] == ["12"]
    assert record["bboxes"] == [
        {"l": 1.0, "t": 2.0, "r": 3.0, "b": 4.0, "page": 3},
        {"l": 0.0, "t": 10.0, "r": 20.0, "b": 0.0, "page": 4},
    ]
    assert record["headings"] == ["Methods", "Setup"]


def test_document_identity_is_copied_onto_the_chunk():
    item = SimpleNamespace(label="text", prov=[SimpleNamespace(page_no=1)], annotations=[])
    doc = SimpleNamespace(
        name="Fallback",
        description=SimpleNamespace(title="Paper", authors=["Ada"], doi="10.1/abc"),
        origin=SimpleNamespace(filename="paper.pdf"),
    )
    record = record_from_chunk(_chunk("Hello", "Hello", [item]), 0, Chunker(), doc)
    assert record["doc_title"] == "Paper"
    assert record["authors"] == ["Ada"]
    assert record["doi"] == "10.1/abc"
    assert record["source"] == "paper.pdf"
    assert record["year"] is None


def test_picture_keeps_description_and_class():
    annotation = SimpleNamespace(
        text="A bar chart of revenue.",
        predicted_classes=[
            SimpleNamespace(class_name="line_chart", confidence=0.2),
            SimpleNamespace(class_name="bar_chart", confidence=0.9),
        ],
    )
    item = SimpleNamespace(label=SimpleNamespace(value="picture"), prov=None, annotations=[annotation])
    record = record_from_chunk(
        _chunk("Figure 1", "Figure 1\nA bar chart of revenue.", [item]),
        1,
        Chunker(),
    )
    assert record["content_type"] == "picture"
    assert record["text"] == "Figure 1"
    assert record["embedding_text"] == "Figure 1\nA bar chart of revenue."
    assert record["picture_description"] == "A bar chart of revenue."
    assert record["picture_class"] == "bar_chart"
    assert "table_markdown" not in record

def test_table_markdown_comes_from_the_grid_or_exporter():
    grid = [[{"text": "Year"}, {"text": "Revenue"}], [{"text": "2024"}, {"text": "10"}]]
    item = SimpleNamespace(label="table", prov=None, annotations=[], data=SimpleNamespace(grid=grid))
    fields = visual_fields([item])
    assert fields["table_markdown"] == "| Year | Revenue |\n| --- | --- |\n| 2024 | 10 |"

    exported = SimpleNamespace(
        label="table",
        export_to_markdown=lambda doc: "| A | B |",
    )
    assert visual_fields([exported], doc=object())["table_markdown"] == "| A | B |"
