"""Per-stage job timings. Resource samples are injected so tests do not touch a GPU."""

from __future__ import annotations

import time
from typing import Any, Callable

from pydantic import BaseModel, Field

from chunky_worker.models import IngestTarget
from chunky_worker.qdrant_ingest import needs_embeddings

STAGE_NAMES = (
    "convert_layout",
    "ocr",
    "table",
    "picture_description",
    "vlm_convert",
    "chunking",
    "embedding",
    "qdrant_upsert",
)


class StageMetric(BaseModel):
    name: str
    duration_ms: float = 0
    status: str = "skipped"
    runtime: str | None = None
    pages: int | None = None
    chunks: int | None = None
    tokens: int | None = None


class ResourceSample(BaseModel):
    gpu_name: str | None = None
    vram_used_mb: float | None = None
    vram_total_mb: float | None = None
    utilization: list[float] = Field(default_factory=list)


class JobMetrics(BaseModel):
    host: str
    wall_ms: float = 0
    pages_per_s: float | None = None
    chunks_per_s: float | None = None
    embeddings_per_s: float | None = None
    stages: list[StageMetric] = Field(default_factory=list)
    resources: ResourceSample = Field(default_factory=ResourceSample)


def stage_enabled(name: str, settings) -> bool:
    if name == "ocr":
        return bool(settings.enable_ocr)
    if name == "table":
        return not bool(settings.no_tables)
    if name == "picture_description":
        return bool(settings.do_picture_description)
    if name == "vlm_convert":
        return bool(settings.vlm_model)
    if name == "embedding":
        return needs_embeddings(settings)
    if name == "qdrant_upsert":
        return settings.ingest_target != IngestTarget.NONE
    return True


def empty_resources() -> dict[str, Any]:
    return {
        "gpu_name": None,
        "vram_used_mb": None,
        "vram_total_mb": None,
        "utilization": [],
    }


def sample_amd_smi() -> dict[str, Any]:
    """Best-effort ROCm sample. Missing amd-smi returns an empty sample."""
    return empty_resources()


class MetricsRecorder:
    def __init__(
        self,
        settings,
        host: str = "devbox",
        resources: Callable[[], dict[str, Any]] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self.settings = settings
        self.host = host
        self.resources = resources or sample_amd_smi
        self.clock = clock or time.perf_counter
        self.started = self.clock()
        self.stages: dict[str, StageMetric] = {
            name: StageMetric(name=name, status="skipped" if not stage_enabled(name, settings) else "ok")
            for name in STAGE_NAMES
        }
        self.events: list[dict[str, Any]] = []

    def time(self, name: str, runtime: str, fn: Callable[[], Any], **counts: int | None) -> Any:
        self.events.append({"type": "stage", "stage": name, "phase": "start", "runtime": runtime})
        started = self.clock()
        status = "ok"
        try:
            return fn()
        except Exception:
            status = "error"
            raise
        finally:
            elapsed = max(0.0, (self.clock() - started) * 1000)
            self.stages[name] = StageMetric(
                name=name,
                duration_ms=elapsed,
                status=status,
                runtime=runtime,
                pages=counts.get("pages"),
                chunks=counts.get("chunks"),
                tokens=counts.get("tokens"),
            )
            self.events.append(
                {"type": "stage", "stage": name, "phase": "end", "runtime": runtime, "status": status, "duration_ms": elapsed}
            )

    def apply_pipeline(self, raw: dict[str, Any], elapsed_ms: float) -> None:
        reported = raw.get("stage_ms") or {}
        statuses = raw.get("stage_status") or {}
        for name, duration in reported.items():
            if name not in self.stages:
                continue
            status = statuses.get(name, "ok")
            self.stages[name] = StageMetric(
                name=name,
                duration_ms=float(duration),
                status=status,
                runtime=raw.get("runtime") or "docling",
                pages=raw.get("page_count") if name in {"convert_layout", "ocr", "vlm_convert"} else None,
                chunks=len(raw.get("chunks") or []) if name == "chunking" else None,
            )
            self.events.append({"type": "stage", "stage": name, "phase": "start", "runtime": self.stages[name].runtime})
            self.events.append(
                {
                    "type": "stage",
                    "stage": name,
                    "phase": "end",
                    "runtime": self.stages[name].runtime,
                    "status": status,
                    "duration_ms": float(duration),
                }
            )
        if not reported and stage_enabled("convert_layout", self.settings):
            self.stages["convert_layout"] = StageMetric(
                name="convert_layout",
                duration_ms=elapsed_ms,
                status="ok" if raw.get("success", True) else "error",
                runtime=raw.get("runtime") or "docling",
                pages=raw.get("page_count"),
            )

    def finish(self, pages: int | None, chunks: int, embeddings: int) -> JobMetrics:
        wall = max(0.0, (self.clock() - self.started) * 1000)
        seconds = wall / 1000 if wall else 0
        return JobMetrics(
            host=self.host,
            wall_ms=wall,
            pages_per_s=(pages / seconds) if pages and seconds else None,
            chunks_per_s=(chunks / seconds) if chunks and seconds else None,
            embeddings_per_s=(embeddings / seconds) if embeddings and seconds else None,
            stages=[self.stages[name] for name in STAGE_NAMES],
            resources=ResourceSample.model_validate(self.resources()),
        )
