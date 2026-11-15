"""FastAPI application for the Chunky worker."""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from chunky_worker.embeddings import EmbeddingBackend, OllamaEmbeddingBackend
from chunky_worker.jobs import TERMINAL, JobRunner, JobStore
from chunky_worker.logging_config import configure_logging
from chunky_worker.models import Job, JobSettings, JobStatus
from chunky_worker.pipeline import DoclingPipeline, DocumentPipeline
from chunky_worker.settings import Settings

log = logging.getLogger(__name__)

# Known VLM ids from docling_daemon.LOCAL_VLM_MODELS. MLX cannot run on the worker.
TRANSFORMERS_VLM_MODELS = (
    "granite-docling-transformers",
    "smoldocling-transformers",
)
MLX_VLM_MODELS = (
    "granite-docling-mlx",
    "smoldocling-mlx",
)


def docling_import_status() -> tuple[bool, str | None]:
    try:
        import docling  # noqa: F401
    except ImportError as exc:
        return False, str(exc)
    return True, None


def create_app(
    settings: Settings | None = None,
    pipeline: DocumentPipeline | None = None,
    embeddings: EmbeddingBackend | None = None,
    store: JobStore | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.log_dir.mkdir(parents=True, exist_ok=True)
    settings.work_dir.mkdir(parents=True, exist_ok=True)
    configure_logging(settings.log_dir)

    pipeline = pipeline or DoclingPipeline(settings.scripts_dir)
    embeddings = embeddings or OllamaEmbeddingBackend(settings.ollama_url)
    store = store or JobStore()
    runner = JobRunner(store, settings, pipeline, embeddings)

    app = FastAPI(title="Chunky worker", version="0.1.0")
    app.state.settings = settings
    app.state.pipeline = pipeline
    app.state.embeddings = embeddings
    app.state.store = store
    app.state.runner = runner

    @app.get("/v1/health")
    def health() -> dict:
        docling_ok, docling_error = docling_import_status()
        embed_ok, embed_error = embeddings.health()
        status = "ok" if docling_ok and embed_ok else "degraded"
        return {
            "status": status,
            "docling": {"importable": docling_ok, "error": docling_error},
            "embeddings": {
                "reachable": embed_ok,
                "backend": "ollama",
                "url": settings.ollama_url,
                "error": embed_error,
            },
        }

    @app.get("/v1/models")
    def models() -> dict:
        names, error = embeddings.list_models()
        embedding_models = [{"name": name, "available": True} for name in names]
        vlm = [
            {"name": name, "available": True, "engine": "transformers"}
            for name in TRANSFORMERS_VLM_MODELS
        ] + [
            {
                "name": name,
                "available": False,
                "engine": "mlx",
                "reason": "mlx-vlm is Apple-only and is not installed on the worker",
            }
            for name in MLX_VLM_MODELS
        ]
        return {
            "embeddings": embedding_models,
            "vlm": vlm,
            "embeddings_error": error,
        }

    @app.post("/v1/jobs", status_code=202)
    async def create_job(
        file: Annotated[UploadFile, File()],
        settings_raw: Annotated[str | None, Form(alias="settings")] = None,
    ) -> dict:
        if settings_raw:
            try:
                payload = json.loads(settings_raw)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail=f"Invalid settings JSON: {exc}") from exc
        else:
            payload = {}
        try:
            job_settings = JobSettings.model_validate(payload)
        except Exception as exc:  # pydantic ValidationError
            raise HTTPException(status_code=400, detail=f"Invalid settings: {exc}") from exc

        original_name = file.filename or "upload.bin"
        job = store.create(original_name, job_settings)
        job_dir = settings.work_dir / job.id
        job_dir.mkdir(parents=True, exist_ok=True)
        # Keep a simple basename; job id already isolates the directory.
        safe_name = Path(original_name).name or "upload.bin"
        dest = job_dir / safe_name
        dest.write_bytes(await file.read())

        runner.start(job.id, dest)
        return {"id": job.id, "status": job.status.value}

    @app.get("/v1/jobs/{job_id}")
    def get_job(job_id: str) -> dict:
        job = store.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        return _job_payload(job)

    @app.post("/v1/jobs/{job_id}/cancel")
    def cancel_job(job_id: str) -> JSONResponse:
        job = store.request_cancel(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        if job.status in TERMINAL and job.status != JobStatus.CANCELED:
            return JSONResponse(
                status_code=409,
                content={"id": job.id, "status": job.status.value, "detail": "Job already finished"},
            )
        return JSONResponse(status_code=200, content={"id": job.id, "status": "canceled"})

    @app.get("/v1/jobs/{job_id}/events")
    async def job_events(job_id: str, request: Request) -> StreamingResponse:
        if store.get(job_id) is None:
            raise HTTPException(status_code=404, detail="Job not found")

        async def stream():
            index = 0
            while True:
                if await request.is_disconnected():
                    break
                events, done = store.events_since(job_id, index)
                for event in events:
                    index += 1
                    yield f"data: {json.dumps(event)}\n\n"
                if done:
                    break
                await asyncio.to_thread(store.wait_for_events, job_id, 0.25)

        return StreamingResponse(stream(), media_type="text/event-stream")

    return app


def _job_payload(job: Job) -> dict:
    body = {
        "id": job.id,
        "status": job.status.value,
        "filename": job.filename,
        "settings": job.settings.model_dump(mode="json"),
        "progress": job.progress.as_dict() if job.progress else None,
        "result": job.result.model_dump(mode="json") if job.result else None,
        "error": job.error,
        "error_type": job.error_type,
    }
    return body
