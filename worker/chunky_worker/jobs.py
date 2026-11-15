"""In-memory job store, runner, and cancellation."""

from __future__ import annotations

import logging
import threading
import uuid
from pathlib import Path
from typing import Any

from chunky_worker.embeddings import DimensionCache, EmbeddingBackend
from chunky_worker.exceptions import JobCanceled
from chunky_worker.qdrant_ingest import (
    DimensionMismatch,
    IngestError,
    QdrantCloudIngestor,
    QdrantIngestor,
    build_points,
    needs_embeddings,
    normalize_distance,
    redact,
)
from chunky_worker.models import (
    IngestReceipt,
    IngestTarget,
    Job,
    JobResult,
    JobSettings,
    JobStatus,
    ProgressEvent,
)
from chunky_worker.pipeline import DocumentPipeline
from chunky_worker.settings import Settings

log = logging.getLogger(__name__)

TERMINAL = {JobStatus.SUCCEEDED, JobStatus.FAILED, JobStatus.CANCELED}


class JobStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, Job] = {}
        self._events: dict[str, list[dict[str, Any]]] = {}
        self._cancels: dict[str, threading.Event] = {}
        self._changed: dict[str, threading.Event] = {}

    def create(self, filename: str, settings: JobSettings) -> Job:
        job_id = str(uuid.uuid4())
        job = Job(id=job_id, filename=filename, settings=settings)
        with self._lock:
            self._jobs[job_id] = job
            self._events[job_id] = []
            self._cancels[job_id] = threading.Event()
            self._changed[job_id] = threading.Event()
        return job

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return job.model_copy(deep=True) if job else None

    def cancel_event(self, job_id: str) -> threading.Event | None:
        with self._lock:
            return self._cancels.get(job_id)

    def request_cancel(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            if job.status in TERMINAL:
                return job.model_copy(deep=True)
            self._cancels[job_id].set()
            if job.status == JobStatus.QUEUED:
                job.status = JobStatus.CANCELED
                job.error = "canceled"
                event = {"type": "canceled", "message": "Job canceled", "status": "canceled"}
                self._events[job_id].append(event)
                job.progress = ProgressEvent(**event)
                self._changed[job_id].set()
            return job.model_copy(deep=True)

    def forget_api_key(self, job_id: str) -> None:
        """Drop the Qdrant API key so it is not retained after the job attempt."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is not None and job.settings.qdrant_api_key:
                job.settings.qdrant_api_key = None

    def append_event(self, job_id: str, event: dict[str, Any]) -> None:
        with self._lock:
            self._events[job_id].append(event)
            job = self._jobs[job_id]
            job.progress = ProgressEvent(
                type=event.get("type", "progress"),
                message=event.get("message"),
                percent=event.get("percent"),
                status=event.get("status"),
            )
            self._changed[job_id].set()

    def set_status(self, job_id: str, status: JobStatus, **updates: Any) -> Job:
        with self._lock:
            job = self._jobs[job_id]
            job.status = status
            for key, value in updates.items():
                setattr(job, key, value)
            self._changed[job_id].set()
            return job.model_copy(deep=True)

    def events_since(self, job_id: str, index: int) -> tuple[list[dict[str, Any]], bool]:
        with self._lock:
            events = self._events[job_id][index:]
            job = self._jobs[job_id]
            done = job.status in TERMINAL
            return events, done

    def wait_for_events(self, job_id: str, timeout: float = 0.25) -> None:
        with self._lock:
            changed = self._changed.get(job_id)
        if changed is None:
            return
        changed.wait(timeout=timeout)
        changed.clear()


class JobRunner:
    def __init__(
        self,
        store: JobStore,
        settings: Settings,
        pipeline: DocumentPipeline,
        embeddings: EmbeddingBackend,
        ingestor: QdrantIngestor | None = None,
    ) -> None:
        self.store = store
        self.settings = settings
        self.pipeline = pipeline
        self.embeddings = embeddings
        self.ingestor = ingestor or QdrantCloudIngestor()
        self.dimensions = DimensionCache()

    def backend_for(self, job_settings) -> EmbeddingBackend:
        kind = (job_settings.embedding_backend or "").strip()
        url = (job_settings.embedding_url or "").strip()
        if not kind and not url:
            return self.embeddings
        from chunky_worker.embeddings import make_embedding_backend

        resolved = kind or self.settings.embedding_backend
        if not url:
            url = self.settings.embedding_url or self.settings.ollama_url
        return make_embedding_backend(resolved, url)

    def start(self, job_id: str, input_path: Path) -> None:
        thread = threading.Thread(
            target=self._run,
            args=(job_id, input_path),
            name=f"chunky-job-{job_id[:8]}",
            daemon=True,
        )
        thread.start()

    def _emit(self, job_id: str, message: str, percent: float | None = None, type: str = "progress") -> None:
        event: dict[str, Any] = {"type": type, "message": message}
        if percent is not None:
            event["percent"] = percent
        self.store.append_event(job_id, event)

    def _apply_ingest(
        self,
        job_id: str,
        job: Job,
        result: JobResult,
        chunks: list[dict[str, Any]],
        vectors: list[list[float]],
        model: str,
        cancel_event: threading.Event,
    ) -> None:
        target = job.settings.ingest_target
        if target == IngestTarget.NONE:
            result.embeddings = vectors
            return

        if target == IngestTarget.RETURN_VECTORS:
            result.embeddings = vectors
            result.ingest = IngestReceipt(
                target=target,
                vector_size=result.embedding_dim,
            )
            return

        if cancel_event.is_set():
            raise JobCanceled()
        distance = normalize_distance(job.settings.qdrant_distance)
        points = build_points(
            chunks,
            vectors,
            source=job.filename,
            settings=job.settings,
            embedding_model=model,
            doc_title=result.doc_title,
            authors=result.authors,
            language=result.language,
            year=result.year,
        )
        self._emit(job_id, f"Upserting {len(points)} points", 97)

        def on_batch(done: int, total: int) -> None:
            self._emit(job_id, f"Upserted {done}/{total}", 98)

        upserted = self.ingestor.upsert_cloud(
            url=job.settings.qdrant_url or "",
            api_key=job.settings.qdrant_api_key or "",
            collection=job.settings.qdrant_collection,
            points=points,
            vector_size=result.embedding_dim or len(points[0].vector),
            distance=distance,
            batch_size=job.settings.qdrant_batch_size,
            hybrid=job.settings.qdrant_hybrid,
            quantization=job.settings.qdrant_quantization,
            on_disk=job.settings.qdrant_on_disk,
            on_progress=on_batch,
        )
        # Cloud path stores the vectors in Qdrant. Do not echo them back.
        result.embeddings = None
        result.ingest = IngestReceipt(
            target=IngestTarget.QDRANT_CLOUD,
            collection=job.settings.qdrant_collection,
            upserted=upserted,
            vector_size=result.embedding_dim,
            distance=distance,
        )

    def _run(self, job_id: str, input_path: Path) -> None:
        job = self.store.get(job_id)
        if job is None:
            return
        cancel_event = self.store.cancel_event(job_id)
        assert cancel_event is not None
        output_dir = self.settings.work_dir / job_id / "out"
        output_dir.mkdir(parents=True, exist_ok=True)
        secret = job.settings.qdrant_api_key

        try:
            if cancel_event.is_set():
                raise JobCanceled()
            self.store.set_status(job_id, JobStatus.RUNNING)
            self._emit(job_id, "Job started", 0)

            def on_progress(message: str, percent: float | None = None) -> None:
                self._emit(job_id, message, percent)

            raw = self.pipeline.convert_and_chunk(
                input_path=input_path,
                output_dir=output_dir,
                settings=job.settings,
                on_progress=on_progress,
                cancel_event=cancel_event,
            )
            if cancel_event.is_set():
                raise JobCanceled()

            if not raw.get("success", False):
                self.store.set_status(
                    job_id,
                    JobStatus.FAILED,
                    error=raw.get("error") or "conversion failed",
                    error_type=raw.get("error_type"),
                )
                self.store.append_event(
                    job_id,
                    {
                        "type": "error",
                        "message": raw.get("error") or "conversion failed",
                        "status": "failed",
                    },
                )
                return

            chunks = list(raw.get("chunks") or [])
            result = JobResult(
                mode=job.settings.mode,
                success=True,
                input_filename=job.filename,
                output_file=raw.get("output_file"),
                output_format=raw.get("output_format"),
                page_count=raw.get("page_count"),
                text_items_count=raw.get("text_items_count"),
                table_count=raw.get("table_count"),
                doc_title=raw.get("doc_title"),
                authors=raw.get("authors"),
                language=raw.get("language"),
                year=raw.get("year"),
                chunks=chunks,
            )

            if needs_embeddings(job.settings):
                if cancel_event.is_set():
                    raise JobCanceled()
                model = job.settings.embedding_model or self.settings.embedding_model
                backend = self.backend_for(job.settings)
                kind = (job.settings.embedding_backend or self.settings.embedding_backend or "ollama").strip()
                url = (job.settings.embedding_url or self.settings.embedding_url or self.settings.ollama_url).strip()
                probed = self.dimensions.dimension(backend, model, cache_key=f"{kind}|{url}|{model}")
                if job.settings.ingest_target == IngestTarget.QDRANT_CLOUD:
                    existing = self.ingestor.collection_vector_size(
                        url=job.settings.qdrant_url or "",
                        api_key=job.settings.qdrant_api_key or "",
                        collection=job.settings.qdrant_collection,
                    )
                    if existing is not None and existing != probed:
                        raise DimensionMismatch(
                            f"Collection {job.settings.qdrant_collection!r} has vector size {existing}, "
                            f"but {model} produces vectors of size {probed}. Refusing to upsert."
                        )
                self._emit(job_id, f"Embedding {len(chunks)} chunks with {model}", 94)
                texts = [
                    chunk.get("embedding_text") or chunk.get("text") or ""
                    for chunk in chunks
                ]
                vectors = backend.embed(texts, model)
                actual = len(vectors[0]) if vectors else 0
                if vectors and actual != probed:
                    raise DimensionMismatch(
                        f"Embedding probe for {model} returned size {probed}, "
                        f"but the batch returned size {actual}."
                    )
                result.embedding_model = model
                result.embedding_dim = probed if vectors else 0
                self._apply_ingest(
                    job_id,
                    job,
                    result,
                    chunks,
                    vectors,
                    model,
                    cancel_event,
                )

            if cancel_event.is_set():
                raise JobCanceled()

            self.store.set_status(job_id, JobStatus.SUCCEEDED, result=result, error=None)
            self.store.append_event(
                job_id,
                {"type": "complete", "message": "Job complete", "percent": 100, "status": "succeeded"},
            )
        except JobCanceled:
            log.info("Job %s canceled", job_id)
            self.store.set_status(job_id, JobStatus.CANCELED, error="canceled")
            self.store.append_event(
                job_id,
                {"type": "canceled", "message": "Job canceled", "status": "canceled"},
            )
        except IngestError as exc:
            message = redact(str(exc), secret)
            log.error("Job %s ingest failed: %s", job_id, message)
            self.store.set_status(
                job_id,
                JobStatus.FAILED,
                error=message,
                error_type=exc.error_type,
            )
            self.store.append_event(
                job_id,
                {"type": "error", "message": message, "status": "failed"},
            )
        except Exception as exc:  # noqa: BLE001 — surface any pipeline failure on the job
            message = redact(str(exc), secret)
            if secret:
                log.error("Job %s failed: %s", job_id, message)
            else:
                log.exception("Job %s failed", job_id)
            self.store.set_status(
                job_id,
                JobStatus.FAILED,
                error=message,
                error_type="exception",
            )
            self.store.append_event(
                job_id,
                {"type": "error", "message": message, "status": "failed"},
            )
        finally:
            self.store.forget_api_key(job_id)
