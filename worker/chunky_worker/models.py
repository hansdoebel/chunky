"""Job and settings models shared by the API and the pipeline."""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class JobMode(str, Enum):
    CHUNK_ONLY = "chunk_only"
    CHUNK_AND_EMBED = "chunk_and_embed"


class JobStatus(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELED = "canceled"


class JobSettings(BaseModel):
    """Subset of the docling_daemon convert-command schema plus worker mode."""

    mode: JobMode = JobMode.CHUNK_ONLY
    format: str = "json"
    vlm_model: str | None = None
    accelerator: str = "cpu"
    enable_ocr: bool = False
    ocr_language: str | None = None
    table_mode: str = "fast"
    no_tables: bool = False
    max_pages: int | None = None
    generate_images: bool = False
    image_export_mode: str = "embedded"
    do_formula_enrichment: bool = False
    do_code_enrichment: bool = False
    do_chart_extraction: bool = False
    do_picture_description: bool = False
    do_picture_classification: bool = False
    input_format: str | None = None
    layout_model: str = "default"
    workers: int = 2
    chunk: bool = True
    chunk_max_tokens: int = 512
    chunk_merge_peers: bool = True
    chunk_tokenizer: str = ""
    ollama_url: str | None = None
    embedding_model: str | None = None


class ProgressEvent(BaseModel):
    type: str = "progress"
    message: str | None = None
    percent: float | None = None
    status: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return self.model_dump(exclude_none=True)


class JobResult(BaseModel):
    mode: JobMode
    success: bool = True
    input_filename: str | None = None
    output_file: str | None = None
    output_format: str | None = None
    page_count: int | None = None
    text_items_count: int | None = None
    table_count: int | None = None
    doc_title: str | None = None
    authors: Any = None
    language: str | None = None
    year: int | None = None
    chunks: list[dict[str, Any]] = Field(default_factory=list)
    embeddings: list[list[float]] | None = None
    embedding_model: str | None = None
    embedding_dim: int | None = None


class Job(BaseModel):
    id: str
    status: JobStatus = JobStatus.QUEUED
    filename: str
    settings: JobSettings
    progress: ProgressEvent | None = None
    result: JobResult | None = None
    error: str | None = None
    error_type: str | None = None
