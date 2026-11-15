"""FastAPI application for the Chunky worker."""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from chunky_worker.auth import require_bearer
from chunky_worker.embeddings import EmbeddingBackend, make_embedding_backend
from chunky_worker.jobs import TERMINAL, JobRunner, JobStore
from chunky_worker.model_catalog import (
    DownloadBusy,
    DownloadManager,
    fetch_ollama_tags,
    fetch_vllm_models,
    recommended,
    scan_hf_cache,
    vlm_report,
)
from chunky_worker.logging_config import configure_logging
from chunky_worker.models import Job, JobSettings, JobStatus
from chunky_worker.verification import hash_file, write_report
from chunky_worker.pipeline import DoclingPipeline, DocumentPipeline
from chunky_worker.search import QdrantPointSearcher, SearchError, parse_search_request, run_search
from chunky_worker.settings import Settings, is_loopback_url, require_token_when_exposed
from chunky_worker.vlm import GRANITE_PRESET, GRANITE_REPO_ID, gpu_probe

log = logging.getLogger(__name__)

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
    ingestor=None,
    searcher=None,
    model_cache=None,
    model_server=None,
    ollama_tags=None,
    downloader=None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    require_token_when_exposed(settings)
    settings.log_dir.mkdir(parents=True, exist_ok=True)
    settings.work_dir.mkdir(parents=True, exist_ok=True)
    configure_logging(settings.log_dir)

    pipeline = pipeline or DoclingPipeline(
        settings.scripts_dir,
        vlm_engine=settings.vlm_engine,
        vllm_url=settings.vllm_url,
        chart_vllm_url=settings.chart_vllm_url,
        embedding_model=settings.embedding_model,
    )
    embeddings = embeddings or make_embedding_backend(
        settings.embedding_backend,
        settings.embedding_url or settings.ollama_url,
    )
    store = store or JobStore()
    runner = JobRunner(store, settings, pipeline, embeddings, ingestor=ingestor)
    searcher = searcher or QdrantPointSearcher()
    downloads = DownloadManager(downloader, ollama_url=settings.ollama_url)

    app = FastAPI(title="Chunky worker", version="0.1.0")
    app.state.settings = settings
    app.state.pipeline = pipeline
    app.state.embeddings = embeddings
    app.state.store = store
    app.state.runner = runner
    app.state.searcher = searcher
    _log_startup(settings)

    api = APIRouter(dependencies=[Depends(require_bearer)])

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
                "backend": settings.embedding_backend,
                "url": settings.embedding_url or settings.ollama_url
                if settings.embedding_backend == "openai"
                else settings.ollama_url,
                "error": embed_error,
            },
            "vlm": {
                "model": GRANITE_REPO_ID,
                "preset": GRANITE_PRESET,
                "engine": settings.vlm_engine,
                "vllm_url": settings.vllm_url if settings.vlm_engine == "vllm" else None,
                "device": "cuda",
                "flash_attention2": False,
                "mlx": False,
                "gpu": gpu_probe(),
            },
        }

    @api.get("/v1/models")
    def models() -> dict:
        names, error = embeddings.list_models()
        embedding_models = [{"name": name, "available": True} for name in names]
        if model_cache is None:
            cache_rows, cache_error = scan_hf_cache()
        else:
            cache_rows, cache_error = model_cache()
        if model_server is None:
            server_models = fetch_vllm_models(settings.vllm_url) if settings.vlm_engine == "vllm" else []
        else:
            server_models = model_server()
        if ollama_tags is None:
            ollama_rows, ollama_error = fetch_ollama_tags(settings.ollama_url)
        else:
            ollama_rows, ollama_error = ollama_tags()
        vlm = vlm_report(cache_rows, server_models, granite_engine=settings.vlm_engine)
        installed = [
            {"name": row["name"], "size": row["size"], "source": "ollama"}
            for row in ollama_rows
        ]
        for item in vlm:
            if item["available"] and item["repo_id"]:
                installed.append(
                    {"name": item["repo_id"], "size": item["size"], "source": "huggingface"}
                )
        return {
            "embeddings": embedding_models,
            "vlm": vlm,
            "embeddings_error": error,
            "cache_error": cache_error,
            "ollama_error": ollama_error,
            "installed": installed,
            "recommended": {
                "devbox": recommended("devbox"),
                "mac": recommended("mac"),
            },
        }

    @api.post("/v1/models/download", status_code=202)
    def start_download(body: dict) -> dict:
        repo_id = (body.get("repo_id") or "").strip()
        if not repo_id:
            raise HTTPException(status_code=400, detail="repo_id is required")
        kind = (body.get("kind") or "").strip().lower()
        if not kind:
            kind = "ollama" if "/" not in repo_id else "huggingface"
        if kind not in {"ollama", "huggingface"}:
            raise HTTPException(status_code=400, detail="kind must be ollama or huggingface")
        revision = body.get("revision")
        try:
            job_id = downloads.start(repo_id, revision, kind=kind)
        except DownloadBusy as exc:
            raise HTTPException(status_code=429, detail=str(exc)) from exc
        record = downloads.get(job_id) or {}
        return {"id": job_id, "status": record.get("status", "running"), "repo_id": repo_id, "kind": kind}

    @api.get("/v1/models/download/{job_id}")
    def download_status(job_id: str) -> dict:
        record = downloads.get(job_id)
        if record is None:
            raise HTTPException(status_code=404, detail="Download not found")
        return record

    @api.post("/v1/models/download/{job_id}/cancel")
    def cancel_download(job_id: str) -> dict:
        record = downloads.cancel(job_id)
        if record is None:
            raise HTTPException(status_code=404, detail="Download not found")
        return record

    @api.post("/v1/search")
    def search(body: dict) -> JSONResponse:
        try:
            request = parse_search_request(body)
            payload = run_search(
                request,
                settings=settings,
                embeddings=embeddings,
                searcher=searcher,
            )
        except SearchError as exc:
            content: dict = {"detail": str(exc)}
            if exc.error_type:
                content["error_type"] = exc.error_type
            return JSONResponse(status_code=exc.status_code, content=content)
        return JSONResponse(status_code=200, content=payload)

    @api.post("/v1/jobs", status_code=202)
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
        except Exception as exc:
            raise HTTPException(status_code=400, detail=f"Invalid settings: {exc}") from exc

        original_name = file.filename or "upload.bin"
        job = store.create(original_name, job_settings)
        job_dir = settings.work_dir / job.id
        job_dir.mkdir(parents=True, exist_ok=True)

        safe_name = Path(original_name).name or "upload.bin"
        dest = job_dir / safe_name
        dest.write_bytes(await file.read())

        accepted = job.status.value
        runner.start(job.id, dest)
        return {"id": job.id, "status": accepted}

    @api.get("/v1/jobs/{job_id}")
    def get_job(job_id: str) -> dict:
        job = store.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        return _job_payload(job)

    @api.get("/v1/jobs/{job_id}/verification")
    def get_verification(job_id: str) -> dict:
        if store.get(job_id) is None:
            raise HTTPException(status_code=404, detail="Job not found")
        path = settings.work_dir / job_id / "verification.json"
        if not path.is_file():
            raise HTTPException(status_code=404, detail="Verification report not found")
        return json.loads(path.read_text(encoding="utf-8"))

    @api.post("/v1/jobs/{job_id}/verify")
    async def reverify_job(job_id: str, request: Request) -> dict:
        job = store.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        if job.status != JobStatus.SUCCEEDED or job.result is None:
            raise HTTPException(status_code=409, detail="Job is not ready to verify")
        overrides = await _json_object(request)
        source = settings.work_dir / job_id / Path(job.filename).name
        if not source.is_file():
            raise HTTPException(status_code=404, detail="Source file is no longer on the worker")
        secret = _optional_secret(overrides.get("qdrant_api_key"))
        chunks = overrides.get("chunks") if isinstance(overrides.get("chunks"), list) else job.result.chunks
        model = (overrides.get("embedding_model") or job.result.embedding_model or settings.embedding_model)
        report = await asyncio.to_thread(
            runner.produce_report,
            pdf_path=source,
            chunks=chunks,
            filename=job.filename,
            job_id=job.id,
            model=model,
            vectors=job.result.embeddings,
            expected_dim=job.result.embedding_dim,
            qdrant_url=overrides.get("qdrant_url") or job.settings.qdrant_url,
            qdrant_api_key=secret,
            collection=overrides.get("qdrant_collection") or job.settings.qdrant_collection or "documents",
            read_store=bool(overrides.get("qdrant_url") or job.settings.ingest_target == "qdrant_cloud"),
            embeddings=runner.backend_for(job.settings),
        )
        _reject_secret(report, secret)
        write_report(settings.work_dir / job_id / "verification.json", report)
        store.set_verification_status(job_id, report["status"])
        return report

    @api.post("/v1/verify")
    async def verify_upload(
        file: Annotated[UploadFile, File()],
        settings_raw: Annotated[str | None, Form(alias="settings")] = None,
    ) -> dict:
        payload = _settings_object(settings_raw)
        secret = _optional_secret(payload.get("qdrant_api_key"))
        payload.pop("qdrant_api_key", None)
        original_name = file.filename or "upload.bin"
        safe_name = Path(original_name).name or "upload.bin"
        digest_dir = settings.work_dir / "verification-upload"
        digest_dir.mkdir(parents=True, exist_ok=True)
        dest = digest_dir / safe_name
        dest.write_bytes(await file.read())
        try:
            chunks = payload.get("chunks") if isinstance(payload.get("chunks"), list) else []
            if not chunks:
                from chunky_worker.verification import cached_chunks

                cached = cached_chunks(hash_file(dest))
                if not cached:
                    raise HTTPException(status_code=400, detail="No chunk records for this PDF")
                chunks = cached
            model = payload.get("embedding_model") or settings.embedding_model
            from chunky_worker.models import JobSettings

            embed_settings = JobSettings(
                embedding_model=model,
                embedding_backend=str(payload.get("embedding_backend") or ""),
                embedding_url=str(payload.get("embedding_url") or ""),
            )
            collection = payload.get("qdrant_collection") or ("documents" if payload.get("qdrant_url") else None)
            report = await asyncio.to_thread(
                runner.produce_report,
                pdf_path=dest,
                chunks=chunks,
                filename=safe_name,
                job_id=None,
                model=model,
                vectors=payload.get("embeddings") if isinstance(payload.get("embeddings"), list) else None,
                expected_dim=payload.get("embedding_dim"),
                qdrant_url=payload.get("qdrant_url"),
                qdrant_api_key=secret,
                collection=collection,
                read_store=bool(payload.get("qdrant_url")),
                embeddings=runner.backend_for(embed_settings),
            )
        finally:
            dest.unlink(missing_ok=True)
        _reject_secret(report, secret)
        write_report(settings.work_dir / "verification" / f"{report['pdf_hash']}.json", report)
        return report

    @api.post("/v1/jobs/{job_id}/cancel")
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

    @api.get("/v1/jobs/{job_id}/events")
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

    app.include_router(api)
    return app

async def _json_object(request: Request) -> dict:
    raw = await request.body()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid settings JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid verification request")
    return payload


def _settings_object(raw: str | None) -> dict:
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid settings JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid settings JSON")
    return payload


def _optional_secret(value: object) -> str | None:
    if isinstance(value, str) and value.strip():
        return value
    return None


def _reject_secret(report: dict, secret: str | None) -> None:
    if not secret:
        return
    raw = json.dumps(report)
    if secret not in raw:
        return
    report.clear()
    report.update(json.loads(raw.replace(secret, "[redacted]")))


def _log_startup(settings: Settings) -> None:
    if settings.token:
        log.info("Bearer auth enabled for /v1 routes except /v1/health")
    else:
        log.warning("No worker token configured; protected /v1 routes will return 401")
    log.info("Bind host %s port %s", settings.host, settings.port)
    if settings.host in {"0.0.0.0", "::"}:
        log.warning(
            "Worker is bound to every interface. Prefer CHUNKY_WORKER_HOST set to the 10GbE address "
            "and a firewall that allows only the Mac."
        )
    if not is_loopback_url(settings.ollama_url):
        log.warning("Ollama URL is not loopback: %s", settings.ollama_url)
    if not is_loopback_url(settings.vllm_url):
        log.warning("vLLM URL is not loopback: %s", settings.vllm_url)
    gpu = gpu_probe()
    log.info(
        "VLM granite-docling engine=%s device=cuda flash_attention2=false gpu_visible=%s arch=%s",
        settings.vlm_engine,
        gpu["cuda"],
        gpu["arch_list"],
    )

def _job_payload(job: Job) -> dict:
    body = {
        "id": job.id,
        "status": job.status.value,
        "filename": job.filename,
        "settings": job.settings.public_dict(),
        "progress": job.progress.as_dict() if job.progress else None,
        "result": job.result.model_dump(mode="json") if job.result else None,
        "error": job.error,
        "error_type": job.error_type,
    }
    return body
