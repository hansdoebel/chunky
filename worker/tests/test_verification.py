"""Unit tests for ingest verification. PDF text, Qdrant, and embeddings are injected."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from chunky_worker.qdrant_ingest import content_hash
from chunky_worker.verification import (
    cached_chunks,
    cosine,
    coverage_ratio,
    extract_pdf_pages,
    fetch_qdrant_points,
    normalize_text,
    resolve_chunks,
    stable_chunk_id,
    verify_document,
)


PAGE_ONE = "The revenue grew sharply in the first quarter of the year."
PAGE_TWO = "The appendix lists every supplier and the signed contract date."
LONG_TAIL = "UNIQUE_TAIL_TOKEN " * 40


def _chunk(text: str, page: int, chunk_id: str | None = None, **extra):
    row = {
        "text": text,
        "embedding_text": text,
        "page": page,
        "chunk_index": page - 1,
    }
    if chunk_id:
        row["id"] = chunk_id
    row.update(extra)
    return row


def _pdf(path: Path) -> None:
    stream = b"BT /F1 24 Tf 72 720 Td (Hello page) Tj ET"
    offsets = [0]
    body = b"%PDF-1.4\n"
    objects = [
        b"1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n",
        b"2 0 obj << /Type /Pages /Count 1 /Kids [3 0 R] >> endobj\n",
        b"3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj\n",
        b"4 0 obj << /Length " + str(len(stream)).encode("ascii") + b" >> stream\n" + stream + b"\nendstream endobj\n",
        b"5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n",
    ]
    for item in objects:
        offsets.append(len(body))
        body += item
    xref = len(body)
    body += f"xref\n0 6\n0000000000 65535 f \n".encode("ascii")
    for offset in offsets[1:]:
        body += f"{offset:010d} 00000 n \n".encode("ascii")
    body += b"trailer << /Size 6 /Root 1 0 R >>\nstartxref\n" + str(xref).encode("ascii") + b"\n%%EOF\n"
    path.write_bytes(body)


def test_normalize_collapses_case_and_punctuation():
    assert normalize_text("  Revenue, GREW.\n") == "revenue grew"


def test_page_coverage_and_attribution(tmp_path: Path):
    pdf = tmp_path / "paper.pdf"
    pdf.write_bytes(b"%PDF")
    missing = "Nothing in the chunks mentions glaciers or the alpine survey."
    chunks = [
        _chunk(PAGE_ONE, 1, "c1"),
        _chunk(PAGE_TWO, 1, "c2"),
    ]
    report = verify_document(
        pdf_path=pdf,
        pdf_hash="hash-1",
        filename="paper.pdf",
        chunks=chunks,
        model="qwen3-embedding",
        now="2026-11-15T00:00:00Z",
        extract_pages=lambda _path: [PAGE_ONE, missing, PAGE_TWO],
    )
    assert [row["status"] for row in report["pages"]] == ["green", "red", "green"]
    assert report["pages"][1]["flags"]
    mismatch = next(row for row in report["attributions"] if row["chunk_id"] == "c2")
    assert mismatch["matched"] is False
    assert mismatch["suggested_page"] == 3
    assert report["pages"][0]["coverage"] == pytest.approx(1.0)
    assert coverage_ratio(PAGE_ONE, [PAGE_ONE]) == pytest.approx(1.0)


def test_store_check_flags_missing_hash_dimension_and_payload():
    text = "Hello world"
    model = "qwen3-embedding"
    chunks = [_chunk(text, 3, "ok"), _chunk("Missing point", 3, "gone"), _chunk("Bad hash", 4, "bad")]
    points = [
        {
            "id": "ok",
            "vector": [0.1, 0.2, 0.3],
            "payload": {
                "text": text,
                "source": "paper.pdf",
                "content_hash": content_hash(text, model),
                "page": 3,
            },
        },
        {
            "id": "bad",
            "vector": [0.1, 0.2],
            "payload": {"text": "Bad hash", "source": "paper.pdf", "content_hash": "nope", "page": 9},
        },
    ]
    report = verify_document(
        pdf_path=None,
        pdf_hash="hash",
        filename="paper.pdf",
        chunks=chunks,
        model=model,
        expected_dim=3,
        points=points,
        now="2026-11-15T00:00:00Z",
    )
    kinds = {issue["kind"] for issue in report["store"]["issues"]}
    assert report["store"]["status"] == "red"
    assert "missing" in kinds
    assert "content_hash" in kinds
    assert "dimension" in kinds
    assert any(issue["chunk_id"] == "bad" and "page" in issue["detail"] for issue in report["store"]["issues"])


def test_vector_spot_check_and_retrieval_rank():
    chunks = [_chunk(PAGE_ONE, 1, "c1"), _chunk(PAGE_TWO, 2, "c2")]
    stored = {"c1": [1.0, 0.0], "c2": [0.0, 1.0]}

    def embed(texts):
        return [stored["c1"] if PAGE_ONE in text else [0.2, 0.2] for text in texts]

    def search(query):
        if "revenue" in query:
            return [{"id": "c1", "page": 1, "score": 0.9}]
        return [{"id": "c1", "page": 1, "score": 0.2}]

    report = verify_document(
        pdf_path=Path("paper.pdf"),
        pdf_hash="hash",
        filename="paper.pdf",
        chunks=chunks,
        model="qwen3-embedding",
        vectors=[stored["c1"], stored["c2"]],
        expected_dim=2,
        embed=embed,
        search=search,
        extract_pages=lambda _path: [PAGE_ONE, PAGE_TWO],
        now="2026-11-15T00:00:00Z",
    )
    samples = {item["chunk_id"]: item for item in report["vector_spot_check"]["samples"]}
    assert samples["c1"]["status"] == "green"
    assert samples["c2"]["status"] == "red"
    assert cosine([1.0, 0.0], [0.0, 1.0]) == 0.0
    queries = report["retrieval"]["queries"]
    assert queries[0]["passed"] is True
    assert queries[1]["passed"] is False
    assert queries[1]["top_chunk_id"] == "c1"
    assert report["status"] == "red"


def test_report_keeps_scores_not_chunk_bodies_or_secrets(tmp_path: Path):
    pdf = tmp_path / "paper.pdf"
    pdf.write_bytes(b"%PDF")
    body = PAGE_ONE + " " + ("pad " * 30) + LONG_TAIL
    chunks = [_chunk(body, 1, "c1", bbox={"l": 72, "t": 700, "r": 400, "b": 640, "origin": "BOTTOMLEFT"})]
    report = verify_document(
        pdf_path=pdf,
        pdf_hash="hash",
        filename="paper.pdf",
        chunks=chunks,
        model="qwen3-embedding",
        vectors=[[1.0, 0.0, 0.0]],
        embed=lambda texts: [[1.0, 0.0, 0.0] for _ in texts],
        search=lambda _query: [{"id": "c1", "page": 1}],
        extract_pages=lambda _path: [PAGE_ONE],
        now="2026-11-15T00:00:00Z",
    )
    raw = json.dumps(report)
    assert "UNIQUE_TAIL_TOKEN" not in raw
    assert "embedding_text" not in raw
    assert "super-secret" not in raw
    assert report["spot_checks"][0]["bbox"]["origin"] == "bottom_left"
    assert len(report["spot_checks"][0]["preview"]) <= 80
    assert report["chunk_source"] == "job"


def test_cache_records_are_reused_and_not_rewritten(monkeypatch, tmp_path: Path):
    pdf = tmp_path / "paper.pdf"
    pdf.write_bytes(b"%PDF")
    cached = [_chunk(PAGE_ONE, 1, "cached")]
    module = SimpleNamespace(chunks_for_pdf_hash=lambda digest: cached if digest == "pdf-hash" else None)
    monkeypatch.setitem(sys.modules, "chunky_worker.chunk_cache", module)
    fallback = [_chunk("this fallback body should not be stored in the report " + LONG_TAIL, 1, "job")]
    report = verify_document(
        pdf_path=pdf,
        pdf_hash="pdf-hash",
        filename="paper.pdf",
        chunks=fallback,
        model="qwen3-embedding",
        extract_pages=lambda _path: [PAGE_ONE],
        now="2026-11-15T00:00:00Z",
    )
    assert report["chunk_source"] == "cache"
    assert report["attributions"][0]["chunk_id"] == "cached"
    assert "fallback body" not in json.dumps(report)
    assert cached_chunks("missing") is None
    assert resolve_chunks("pdf-hash", fallback)[1] == "cache"


def test_stable_ids_follow_the_pdf_hash_and_text():
    first = stable_chunk_id("hash", {"text": "Hello", "chunk_index": 0}, 0)
    assert first == stable_chunk_id("hash", {"text": "Hello", "chunk_index": 0}, 0)
    assert first != stable_chunk_id("other", {"text": "Hello", "chunk_index": 0}, 0)
    assert stable_chunk_id("hash", {"id": "kept", "text": "Hello"}, 0) == "kept"


def test_pdfium_is_preferred_and_pypdf_reads_each_page(monkeypatch, tmp_path: Path):
    seen = {}

    class Document:
        def __len__(self):
            return 2

        def __getitem__(self, index):
            seen["index"] = index
            return self

        def get_textpage(self):
            return self

        def get_text_bounded(self):
            return f"page-{seen['index']}"

        def close(self):
            seen["closed"] = True

    class FakePdfium:
        def PdfDocument(self, path):
            seen["path"] = path
            return Document()

    monkeypatch.setattr("chunky_worker.verification._import_pdfium", lambda: FakePdfium())
    assert extract_pdf_pages(tmp_path / "a.pdf") == ["page-0", "page-1"]
    assert seen["closed"] is True

    monkeypatch.setattr("chunky_worker.verification._import_pdfium", lambda: None)
    pdf = tmp_path / "hello.pdf"
    _pdf(pdf)
    pages = extract_pdf_pages(pdf)
    assert len(pages) == 1
    assert "Hello page" in pages[0]


def test_fetch_redacts_the_api_key_and_reads_named_vectors():
    secret = "super-secret-cloud-key"

    class Record:
        id = "c1"
        vector = {"dense": [0.25, 0.5]}
        payload = {"text": "Hello", "content_hash": "abc"}

    class Client:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

        def retrieve(self, **kwargs):
            raise RuntimeError(f"denied {secret}")

        def close(self):
            pass

    with pytest.raises(RuntimeError, match=r"\[redacted\]") as caught:
        fetch_qdrant_points(
            url="https://example.cloud.qdrant.io",
            api_key=secret,
            collection="documents",
            ids=["c1"],
            client_factory=lambda **kwargs: Client(**kwargs),
        )
    assert secret not in str(caught.value)

    class Ok(Client):
        def retrieve(self, **kwargs):
            assert kwargs["ids"] == ["c1"]
            assert kwargs["with_vectors"] is True
            return [Record()]

    points = fetch_qdrant_points(
        url="https://example.cloud.qdrant.io",
        api_key=secret,
        collection="documents",
        ids=["c1"],
        client_factory=lambda **kwargs: Ok(**kwargs),
    )
    assert points == [{"id": "c1", "vector": [0.25, 0.5], "payload": {"text": "Hello", "content_hash": "abc"}}]
