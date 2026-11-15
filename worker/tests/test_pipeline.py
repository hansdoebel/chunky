"""Unit tests for DoclingPipeline wiring (convert_document is mocked)."""

from __future__ import annotations

import sys
import threading
from pathlib import Path

from chunky_worker.exceptions import JobCanceled
from chunky_worker.models import JobSettings
from chunky_worker.pipeline import DoclingPipeline

def test_docling_pipeline_calls_convert_document(tmp_path, monkeypatch):
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    seen = {}

    def fake_convert_document(**kwargs):
        seen.update(kwargs)
        if kwargs.get("on_progress"):
            kwargs["on_progress"]("Converting document...", 10)
        return {"success": True, "chunks": [], "output_file": str(tmp_path / "out.json")}

    module = type(sys)("docling_convert")
    module.convert_document = fake_convert_document
    monkeypatch.setitem(sys.modules, "docling_convert", module)

    pipeline = DoclingPipeline(scripts)
    settings = JobSettings(accelerator="cpu", chunk_max_tokens=128)
    progress = []
    result = pipeline.convert_and_chunk(
        input_path=tmp_path / "doc.pdf",
        output_dir=tmp_path / "out",
        settings=settings,
        on_progress=lambda message, percent=None: progress.append((message, percent)),
        cancel_event=threading.Event(),
    )
    assert result["success"] is True
    assert seen["input_path"] == str(tmp_path / "doc.pdf")
    assert seen["accelerator"] == "cpu"
    assert seen["chunk"] is True
    assert seen["chunk_max_tokens"] == 128
    assert seen["on_progress"] is not None
    assert progress == [("Converting document...", 10)]

def test_docling_pipeline_honors_pre_cancel(tmp_path):
    pipeline = DoclingPipeline(tmp_path)
    cancel = threading.Event()
    cancel.set()
    try:
        pipeline.convert_and_chunk(
            input_path=tmp_path / "doc.pdf",
            output_dir=tmp_path / "out",
            settings=JobSettings(),
            on_progress=lambda *_: None,
            cancel_event=cancel,
        )
        raised = False
    except JobCanceled:
        raised = True
    assert raised
