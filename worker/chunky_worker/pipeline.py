"""Document pipeline. Default implementation reuses convert_document."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Callable, Protocol

from chunky_worker.exceptions import JobCanceled
from chunky_worker.models import JobSettings

ProgressFn = Callable[[str, float | None], None]


class DocumentPipeline(Protocol):
    def convert_and_chunk(
        self,
        input_path: Path,
        output_dir: Path,
        settings: JobSettings,
        on_progress: ProgressFn,
        cancel_event,
    ) -> dict:
        """Convert a file and optionally chunk it. Must honor cancel_event."""


class DoclingPipeline:
    """Wraps ``convert_document`` from Chunky/Resources/Scripts/docling_convert.py."""

    def __init__(self, scripts_dir: Path) -> None:
        self.scripts_dir = scripts_dir

    def _load_convert(self):
        scripts = str(self.scripts_dir)
        if scripts not in sys.path:
            sys.path.insert(0, scripts)
        from docling_convert import convert_document  # type: ignore

        return convert_document

    def convert_and_chunk(
        self,
        input_path: Path,
        output_dir: Path,
        settings: JobSettings,
        on_progress: ProgressFn,
        cancel_event,
    ) -> dict:
        if cancel_event.is_set():
            raise JobCanceled()

        convert_document = self._load_convert()

        def hooked(message: str, percent: float | None = None) -> None:
            if cancel_event.is_set():
                raise JobCanceled()
            on_progress(message, percent)

        result = convert_document(
            input_path=str(input_path),
            output_dir=str(output_dir),
            output_format=settings.format,
            max_pages=settings.max_pages,
            enable_ocr=settings.enable_ocr,
            ocr_language=settings.ocr_language,
            table_mode=settings.table_mode,
            no_tables=settings.no_tables,
            report_progress=False,
            accelerator=settings.accelerator,
            vlm_model=settings.vlm_model,
            ollama_url=settings.ollama_url or "http://127.0.0.1:11434",
            generate_images=settings.generate_images,
            image_export_mode=settings.image_export_mode,
            do_formula_enrichment=settings.do_formula_enrichment,
            do_code_enrichment=settings.do_code_enrichment,
            do_chart_extraction=settings.do_chart_extraction,
            do_picture_description=settings.do_picture_description,
            do_picture_classification=settings.do_picture_classification,
            input_format=settings.input_format,
            layout_model=settings.layout_model,
            workers=settings.workers,
            chunk=settings.chunk,
            chunk_max_tokens=settings.chunk_max_tokens,
            chunk_merge_peers=settings.chunk_merge_peers,
            chunk_tokenizer=settings.chunk_tokenizer,
            on_progress=hooked,
        )

        if cancel_event.is_set():
            raise JobCanceled()
        return result
