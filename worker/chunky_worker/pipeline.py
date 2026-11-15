"""Document pipeline. Default implementation reuses convert_document."""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Callable, Protocol

from chunky_worker.exceptions import JobCanceled
from chunky_worker.models import JobSettings
from chunky_worker.vlm import accelerator_for_worker, granite_engine_for, granite_plan, model_for_worker

log = logging.getLogger(__name__)

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

    def __init__(
        self,
        scripts_dir: Path,
        vlm_engine: str = "vllm",
        vllm_url: str = "http://127.0.0.1:8000",
    ) -> None:
        self.scripts_dir = scripts_dir
        self.vlm_engine = vlm_engine
        self.vllm_url = vllm_url

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
        vlm_model = model_for_worker(settings.vlm_model)
        accelerator = accelerator_for_worker(settings.accelerator)
        vlm_engine = granite_engine_for(settings.vlm_model, self.vlm_engine)
        if vlm_engine is not None:
            plan = granite_plan(vlm_engine, self.vllm_url, accelerator)
            log.info(
                "granite-docling preset=%s engine=%s device=%s flash_attention2=%s target=%s",
                plan["preset"],
                plan["engine"],
                plan["device"],
                plan["cuda_use_flash_attention2"],
                plan.get("url", "in-process"),
            )

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
            accelerator=accelerator,
            vlm_model=vlm_model,
            ollama_url=settings.ollama_url or "http://127.0.0.1:11434",
            vlm_engine=vlm_engine,
            vllm_url=self.vllm_url,
            chart_host="devbox",
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
