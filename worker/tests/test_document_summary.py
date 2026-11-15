import uuid

from chunky_worker.document_summary import resolve_summary, summary_payload


def test_abstract_is_preferred_over_a_generated_summary():
    text, kind = resolve_summary(
        [
            {"text": "We study revenue.", "headings": ["Abstract"], "page": 1},
            {"text": "Later.", "headings": ["Methods"], "page": 3},
        ],
        "Revenue",
        generated="LLM",
    )
    assert kind == "abstract"
    assert text == "We study revenue."


def test_generated_summary_is_used_when_there_is_no_abstract():
    text, kind = resolve_summary(
        [{"text": "Opening paragraph.", "headings": ["Introduction"], "page": 1}],
        "Revenue",
        generated="A short generated abstract.",
    )
    assert kind == "generated"
    assert text == "A short generated abstract."


def test_extract_uses_the_title_and_opening_pages():
    text, kind = resolve_summary(
        [
            {"text": "Opening paragraph.", "headings": ["Introduction"], "page": 1},
            {"text": "Much later.", "headings": ["Appendix"], "page": 9},
        ],
        "Revenue",
        generated="  ",
    )
    assert kind == "extract"
    assert "Revenue" in text
    assert "Opening paragraph." in text
    assert "Much later." not in text


def test_summary_id_is_stable_and_disabled_metadata_is_omitted():
    point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "chunky-summary:paper.pdf"))
    assert point_id == "bdefd408-de82-54f7-b74f-8478d8f689e9"
    payload = summary_payload(
        text="Abstract",
        kind="abstract",
        source="paper.pdf",
        doc_title=None,
        authors=None,
        year=None,
        document_id=None,
    )
    assert "doc_title" not in payload
    assert "authors" not in payload
    assert "year" not in payload
    assert payload["record_type"] == "document"
