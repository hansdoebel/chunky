from chunky_worker.document_summary import resolve_summary


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
