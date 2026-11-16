"""FastAPI application for the Chunky worker."""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from chunky_worker.auth import require_bearer
from chunky_worker.chunk_cache import ChunkCache, ChunkCacheError
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
from chunky_worker.models import IngestTarget, Job, JobMode, JobSettings, JobStatus
from chunky_worker.verification import hash_file, write_report
from chunky_worker.pipeline import DoclingPipeline, DocumentPipeline
from chunky_worker.search import QdrantPointSearcher, SearchError, parse_scroll_offset, parse_search_request, run_search, worker_read_target
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


def docling_version() -> str | None:
    try:
        import docling
    except ImportError:
        return None
    version = getattr(docling, "__version__", None)
    if not isinstance(version, str):
        return None
    version = version.strip()
    return version or None

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
    chunk_cache: ChunkCache | None = None,
    web_dist: Path | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    require_token_when_exposed(settings)
    settings.log_dir.mkdir(parents=True, exist_ok=True)
    settings.work_dir.mkdir(parents=True, exist_ok=True)
    settings.cache_dir.mkdir(parents=True, exist_ok=True)
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
    chunk_cache = chunk_cache or ChunkCache(settings.cache_dir, settings.cache_limit_bytes)
    runner = JobRunner(store, settings, pipeline, embeddings, ingestor=ingestor, chunk_cache=chunk_cache)
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
            "docling": {"importable": docling_ok, "error": docling_error, "version": docling_version()},
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
        if request.use_worker_qdrant:
            _reject_secret(payload, settings.qdrant_api_key)
        return JSONResponse(status_code=200, content=payload)

    @api.get("/v1/collections")
    def collections() -> JSONResponse:
        try:
            url, key = worker_read_target(settings)
            payload = searcher.list_collections(url=url, api_key=key)
            _reject_secret(payload, key)
            return JSONResponse(content=payload)
        except SearchError as exc:
            return JSONResponse(status_code=exc.status_code, content={"detail": str(exc), "error_type": exc.error_type})

    @api.get("/v1/collections/{collection}/points")
    def collection_points(collection: str, limit: int = 50, offset: str | None = None) -> JSONResponse:
        try:
            if not 1 <= limit <= 100:
                raise SearchError("limit must be 1–100", status_code=422, error_type="invalid_limit")
            cursor = parse_scroll_offset(offset)
            url, key = worker_read_target(settings)
            payload = searcher.scroll_points(url=url, api_key=key, collection=collection, limit=limit, offset=cursor)
            _reject_secret(payload, key)
            return JSONResponse(content=payload)
        except SearchError as exc:
            return JSONResponse(status_code=exc.status_code, content={"detail": str(exc), "error_type": exc.error_type})

    @api.get("/v1/ui/config")
    def ui_config() -> dict:
        return {
            "embedding_backend": settings.embedding_backend,
            "embedding_model": settings.embedding_model,
            "qdrant_available": _worker_qdrant_available(settings),
            "qdrant_read_available": _worker_qdrant_read_available(settings),
            "qdrant_label": "Worker Qdrant",
            "vlm_models": ["standard", *TRANSFORMERS_VLM_MODELS],
        }

    @api.get("/v1/jobs")
    def list_jobs(limit: int = 50, offset: int = 0) -> dict:
        if not 1 <= limit <= 100 or offset < 0:
            raise HTTPException(status_code=422, detail="limit must be 1–100 and offset nonnegative")
        jobs, total = store.page(limit, offset)
        summaries = []
        for job in jobs:
            body = _job_payload(job)
            summaries.append({key: body[key] for key in ("id", "status", "filename", "progress", "error", "error_type")})
        return {"jobs": summaries, "total": total, "limit": limit, "offset": offset}

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

        if job_settings.use_worker_qdrant:
            if job_settings.mode != JobMode.CHUNK_AND_EMBED or job_settings.ingest_target != IngestTarget.QDRANT_CLOUD:
                raise HTTPException(status_code=400, detail="Worker Qdrant requires full processing and qdrant_cloud ingestion")
            if job_settings.qdrant_url or job_settings.qdrant_api_key:
                raise HTTPException(status_code=400, detail="Worker Qdrant does not accept client credentials or URLs")
            if not _worker_qdrant_available(settings):
                raise HTTPException(status_code=400, detail="Worker Qdrant is not configured with a safe URL and API key")
            job_settings.qdrant_url = settings.qdrant_url
            job_settings.qdrant_api_key = settings.qdrant_api_key

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
    def get_job(job_id: str, include_embeddings: bool = True) -> dict:
        job = store.get(job_id, include_embeddings=include_embeddings)
        if job is None:
            raise HTTPException(status_code=404, detail="Job not found")
        return _job_payload(job, include_embeddings=include_embeddings)

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

    def cache_key(body: dict) -> dict:
        missing = [
            name
            for name in ("content_sha256", "docling_version", "pipeline", "max_tokens")
            if body.get(name) in (None, "")
        ]
        if "tokenizer" not in body:
            missing.append("tokenizer")
        if missing:
            raise HTTPException(status_code=400, detail={"error_type": "invalid_cache_key", "missing": missing})
        digest = str(body["content_sha256"]).strip().lower()
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise HTTPException(status_code=400, detail={"error_type": "invalid_cache_key", "missing": ["content_sha256"]})
        try:
            max_tokens = int(body["max_tokens"])
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail={"error_type": "invalid_cache_key", "missing": ["max_tokens"]}) from None
        if max_tokens < 1:
            raise HTTPException(status_code=400, detail={"error_type": "invalid_cache_key", "missing": ["max_tokens"]})
        return {
            "content_sha256": digest,
            "docling_version": str(body["docling_version"]).strip(),
            "pipeline": str(body["pipeline"]).strip(),
            "tokenizer": str(body.get("tokenizer") or ""),
            "max_tokens": max_tokens,
            "options": str(body.get("options") or ""),
        }

    def cache_error(exc: ChunkCacheError) -> HTTPException:
        status = 400 if exc.error_type != "corrupt_manifest" else 500
        return HTTPException(status_code=status, detail={"error_type": exc.error_type, "detail": str(exc)})

    @api.get("/v1/cache")
    def cache_stats() -> dict:
        try:
            return chunk_cache.stats()
        except ChunkCacheError as exc:
            raise cache_error(exc) from exc

    @api.delete("/v1/cache")
    def cache_clear() -> dict:
        chunk_cache.clear()
        return {"cleared": True}

    @api.post("/v1/cache/lookup")
    def cache_lookup(body: dict) -> dict:
        key = cache_key(body)
        model = str(body.get("embedding_model") or "").strip() or None
        dimension = body.get("embedding_dim")
        try:
            found = chunk_cache.lookup(
                key,
                embedding_model=model,
                embedding_dim=int(dimension) if dimension not in (None, "") else None,
                include_document=bool(body.get("include_document")),
            )
        except ChunkCacheError as exc:
            raise cache_error(exc) from exc
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail={"error_type": "invalid_vectors", "detail": "embedding_dim must be an integer"}) from None
        if found is None:
            return {"hit": False, "chunks": [], "vector_hit": False, "vectors": None}
        return found

    @api.put("/v1/cache")
    def cache_store(body: dict) -> dict:
        key = cache_key(body)
        identity = {
            "doc_title": body.get("doc_title"),
            "authors": body.get("authors"),
            "year": body.get("year"),
            "doi": body.get("doi"),
            "source": body.get("source"),
        }
        try:
            stored = chunk_cache.store(key, body.get("document"), body.get("chunks") or [], identity)
        except ChunkCacheError as exc:
            raise cache_error(exc) from exc
        return stored

    @api.put("/v1/cache/vectors")
    def cache_store_vectors(body: dict) -> dict:
        key = cache_key(body)
        try:
            stored = chunk_cache.store_vectors(
                key,
                str(body.get("embedding_model") or ""),
                int(body.get("embedding_dim") or 0),
                body.get("vectors") or [],
            )
        except ChunkCacheError as exc:
            raise cache_error(exc) from exc
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail={"error_type": "invalid_vectors", "detail": "embedding_dim must be an integer"}) from None
        return stored

    app.include_router(api)
    assets = web_dist if web_dist is not None else Path(__file__).parent / "web_dist"

    @app.middleware("http")
    async def response_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        if request.url.path == "/" or request.url.path.startswith("/assets/"):
            response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        return response

    @app.get("/", include_in_schema=False)
    def web_shell():
        index = assets / "index.html"
        if not index.is_file():
            return JSONResponse(status_code=503, content={"detail": "Web UI assets are missing. Build worker/web with bun install --frozen-lockfile && bun run build."})
        return FileResponse(index)

    if assets.is_dir():
        app.mount("/assets", StaticFiles(directory=assets / "assets", check_dir=False), name="web-assets")
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
    def sanitized(value):
        if isinstance(value, str):
            return value.replace(secret, "[redacted]")
        if isinstance(value, dict):
            return {key: sanitized(item) for key, item in value.items()}
        if isinstance(value, list):
            return [sanitized(item) for item in value]
        return value

    for key, value in report.items():
        report[key] = sanitized(value)


def _log_startup(settings: Settings) -> None:
    if settings.token:
        log.info("Bearer auth enabled for /v1 routes except /v1/health")
    else:
        log.warning("No worker token configured; protected /v1 routes will return 401")
    log.info("Bind host %s port %s", settings.host, settings.port)
    if settings.host in {"0.0.0.0", "::"}:
        log.warning(
            "Worker is bound to every interface. Prefer CHUNKY_WORKER_HOST set to one address "
            "and a firewall that allows only the app machine."
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

def _worker_qdrant_read_available(settings: Settings) -> bool:
    try:
        worker_read_target(settings)
        return True
    except SearchError:
        return False


def _worker_qdrant_available(settings: Settings) -> bool:
    return _worker_qdrant_read_available(settings) and bool((settings.qdrant_api_key or "").strip())


def _job_payload(job: Job, *, include_embeddings: bool = True) -> dict:
    body = {
        "id": job.id,
        "status": job.status.value,
        "filename": job.filename,
        "settings": job.settings.public_dict(),
        "progress": job.progress.as_dict() if job.progress else None,
        "result": job.result.model_dump(mode="json", exclude=None if include_embeddings else {"embeddings"}) if job.result else None,
        "error": job.error,
        "error_type": job.error_type,
    }
    _reject_secret(body, job.settings.qdrant_api_key)
    if job.settings.use_worker_qdrant:
        body["settings"].pop("qdrant_url", None)
    return body
