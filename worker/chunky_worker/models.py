"""Job and settings models shared by the API and the pipeline."""

from __future__ import annotations

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field


class JobMode(str, Enum):
    CHUNK_ONLY = "chunk_only"
    CHUNK_AND_EMBED = "chunk_and_embed"


class IngestTarget(str, Enum):
    """Where embeddings go after the worker finishes.

    ``none`` leaves ingest to the caller (today's chunk-only / return-embeddings path).
    ``qdrant_cloud`` upserts from the worker with credentials supplied on this request.
    ``return_vectors`` puts chunks and vectors on the job result so the Mac can
    write them to a local Qdrant.
    """

    NONE = "none"
    QDRANT_CLOUD = "qdrant_cloud"
    RETURN_VECTORS = "return_vectors"


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
    # ROCm exposes the GPU as torch.cuda. MPS is Mac-only.
    accelerator: str = "cuda"
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
    picture_description_preset: str = ""
    vlm_server_url: str = ""
    input_format: str | None = None
    layout_model: str = "default"
    workers: int = 8
    ocr_batch_size: int = 0
    layout_batch_size: int = 0
    table_batch_size: int = 0
    chunk: bool = True
    chunk_max_tokens: int = 512
    chunk_merge_peers: bool = True
    chunk_tokenizer: str = ""
    ollama_url: str | None = None
    embedding_model: str | None = None
    embedding_backend: str = ""
    embedding_url: str = ""
    ingest_target: IngestTarget = IngestTarget.NONE
    qdrant_url: str | None = None
    # Kept in memory for the duration of the job only. Never logged or returned.
    qdrant_api_key: str | None = Field(default=None, repr=False)
    qdrant_collection: str = "documents"
    qdrant_distance: str = "cosine"
    qdrant_hybrid: bool = False
    qdrant_quantization: str = "none"
    qdrant_on_disk: bool = False
    qdrant_batch_size: int = 250
    # Payload toggles match AppSettings metadata flags (all on by default).
    metadata_include_page: bool = True
    metadata_include_headings: bool = True
    metadata_include_timestamp: bool = True
    metadata_include_doc_title: bool = True
    metadata_include_authors: bool = True
    metadata_include_chunk_index: bool = True
    metadata_include_content_type: bool = True
    metadata_include_section: bool = True
    metadata_include_doi: bool = True
    metadata_include_document_id: bool = True
    metadata_include_url: bool = True
    metadata_include_year: bool = True
    metadata_include_language: bool = True
    metadata_include_content_hash: bool = True

    def public_dict(self) -> dict[str, Any]:
        return self.model_dump(mode="json", exclude={"qdrant_api_key"})


class ProgressEvent(BaseModel):
    type: str = "progress"
    message: str | None = None
    percent: float | None = None
    status: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return self.model_dump(exclude_none=True)


class IngestReceipt(BaseModel):
    target: IngestTarget
    collection: str | None = None
    upserted: int = 0
    vector_size: int | None = None
    distance: str | None = None


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
    ingest: IngestReceipt | None = None


class Job(BaseModel):
    id: str
    status: JobStatus = JobStatus.QUEUED
    filename: str
    settings: JobSettings
    progress: ProgressEvent | None = None
    result: JobResult | None = None
    error: str | None = None
    error_type: str | None = None
