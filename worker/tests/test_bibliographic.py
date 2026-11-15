"""LLM and Crossref metadata stay behind the import source."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from bibliographic import (  # noqa: E402
    crossref_fields,
    enrich_chunks,
    extract_doi,
    open_pdf_url,
    parse_metadata_json,
)


def test_schema_parser_reads_a_fenced_object():
    parsed = parse_metadata_json(
        '```json\n{"doc_title": "Paper", "authors": ["Ada"], "year": "2024", "doi": "10.1000/xyz", "venue": "J", "abstract": "A"}\n```'
    )
    assert parsed["doc_title"] == "Paper"
    assert parsed["authors"] == ["Ada"]
    assert parsed["year"] == 2024
    assert parsed["doi"] == "10.1000/xyz"
    assert extract_doi("see 10.5555/abc.") == "10.5555/abc"


def test_imported_metadata_is_not_overwritten():
    chunks = [{"doc_title": "Imported", "authors": ["Ada"], "year": 1999, "metadata_source": "zotero"}]
    calls = []

    def llm(_prompt):
        calls.append("llm")
        return '{"doc_title": "Other", "authors": ["Bea"], "year": 2020}'

    source = enrich_chunks(chunks, ["first page"], llm=llm, crossref=lambda _doi: {"doc_title": "Cross"})
    assert source == "zotero"
    assert calls == []
    assert chunks[0]["doc_title"] == "Imported"
    assert chunks[0]["year"] == 1999


def test_llm_fills_gaps_and_crossref_wins():
    chunks = [{"text": "body", "doi": None}]
    prompts = []

    def llm(prompt):
        prompts.append(prompt)
        return '{"doc_title": "Draft", "authors": ["Ada"], "year": 2020, "doi": "10.1000/xyz", "venue": "Draft Journal"}'

    def crossref(doi):
        assert doi == "10.1000/xyz"
        return crossref_fields(
            {
                "message": {
                    "title": ["Confirmed"],
                    "author": [{"given": "Ada", "family": "Lovelace"}],
                    "issued": {"date-parts": [[2021]]},
                    "container-title": ["Real Journal"],
                    "DOI": doi,
                }
            }
        )

    source = enrich_chunks(chunks, ["DOI 10.1000/xyz on page one", "last"], llm=llm, crossref=crossref)
    assert source == "crossref"
    assert prompts and "10.1000/xyz" in prompts[0]
    assert chunks[0]["doc_title"] == "Confirmed"
    assert chunks[0]["authors"] == ["Ada Lovelace"]
    assert chunks[0]["year"] == 2021
    assert chunks[0]["venue"] == "Real Journal"
    assert chunks[0]["metadata_source"] == "crossref"


def test_llm_alone_when_crossref_is_absent():
    chunks = [{"text": "body"}]
    source = enrich_chunks(
        chunks,
        ["A paper"],
        llm=lambda _prompt: '{"doc_title": "Only LLM", "authors": ["Bea"], "year": 2019}',
        crossref=None,
    )
    assert source == "llm"
    assert chunks[0]["doc_title"] == "Only LLM"
    assert chunks[0]["metadata_source"] == "llm"


def test_known_document_year_is_kept():
    from bibliographic import seed_document_fields

    chunks = [{"text": "body", "year": None, "doc_title": None}]
    seed_document_fields(chunks, {"year": 1999, "doc_title": "Known"})

    def llm(_prompt):
        return '{"doc_title": "Guess", "authors": ["Bea"], "year": 2020}'

    enrich_chunks(chunks, ["first page"], llm=llm)
    assert chunks[0]["year"] == 1999
    assert chunks[0]["doc_title"] == "Known"
    assert chunks[0]["authors"] == ["Bea"]


def test_reference_doi_does_not_overwrite_the_paper():
    calls = []

    def crossref(doi):
        calls.append(doi)
        return {"doc_title": "Cited Paper", "authors": ["Other"], "year": 2010, "doi": doi}

    def llm(_prompt):
        return '{"doc_title": "This Paper", "authors": ["Ada"], "year": 2024, "doi": "10.1000/cited"}'

    chunks = [{"text": "body"}]
    source = enrich_chunks(
        chunks,
        ["Introduction without a DOI", "References\n10.1000/cited"],
        llm=llm,
        crossref=crossref,
    )
    assert calls == []
    assert source == "llm"
    assert chunks[0]["doc_title"] == "This Paper"
    assert chunks[0]["year"] == 2024
    assert chunks[0].get("doi") in (None, "")


def test_empty_pages_skip_the_llm_and_chunk_text_can_fill_them():
    from bibliographic import pages_for_metadata

    calls = []
    chunks = [{"text": "Scanned title by Ada, 2018"}]
    assert pages_for_metadata(["", ""], chunks) == ["Scanned title by Ada, 2018"]
    enrich_chunks(chunks, ["", ""], llm=lambda _prompt: calls.append("llm") or "{}")
    assert calls == []


def test_chat_payload_without_a_message_is_empty():
    from chunky_worker.jobs import _message_text

    assert _message_text(None) == ""
    assert _message_text([]) == ""
    assert _message_text({"choices": [None]}) == ""
    assert _message_text({"choices": [{"message": {"content": "ok"}}]}) == "ok"


def test_open_pdf_url_requires_an_explicit_pdf_link():
    html_only = {
        "message": {
            "link": [{"URL": "https://publisher.example/article", "content-type": "text/html"}]
        }
    }
    pdf = {
        "message": {
            "link": [
                {"URL": "https://publisher.example/article", "content-type": "text/html"},
                {"URL": "https://publisher.example/paper.pdf", "content-type": "application/pdf"},
            ]
        }
    }
    assert open_pdf_url(html_only) is None
    assert open_pdf_url(pdf) == "https://publisher.example/paper.pdf"
