"""Installed-model detection. Tests pass parsed payloads; nothing is downloaded here."""

from __future__ import annotations

import json
from typing import Any, Callable

KNOWN_VLM = {
    "granite-docling-transformers": {
        "repo_id": "ibm-granite/granite-docling-258M",
        "engine": "transformers",
        "host": "devbox",
    },
    "smoldocling-transformers": {
        "repo_id": "ds4sd/SmolDocling-256M-preview",
        "engine": "transformers",
        "host": "devbox",
    },
    "granite-docling-mlx": {
        "repo_id": "ibm-granite/granite-docling-258M",
        "engine": "mlx",
        "host": "mac",
    },
    "smoldocling-mlx": {
        "repo_id": "ds4sd/SmolDocling-256M-preview",
        "engine": "mlx",
        "host": "mac",
    },
}

RECOMMENDED = {
    "devbox": [
        "qwen3-embedding",
        "ibm-granite/granite-docling-258M",
        "ibm-granite/granite-vision-3.3-2b",
    ],
    "mac": ["granite-docling-mlx"],
}


def parse_ollama_tags(payload: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for item in payload.get("models") or []:
        details = item.get("details") or {}
        name = item.get("name") or item.get("model") or ""
        if not name:
            continue
        rows.append(
            {
                "name": name,
                "digest": item.get("digest") or "",
                "size": int(item.get("size") or 0),
                "parameter_size": details.get("parameter_size") or "",
                "quantization": details.get("quantization_level") or "",
            }
        )
    return rows


def parse_hf_cache(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for entry in entries:
        repo_id = entry.get("repo_id") or ""
        if not repo_id:
            continue
        rows.append(
            {
                "repo_id": repo_id,
                "revision": entry.get("revision") or "",
                "size": int(entry.get("size") or 0),
            }
        )
    return rows


def parse_openai_models(payload: dict[str, Any]) -> list[str]:
    names: list[str] = []
    for item in payload.get("data") or []:
        name = item.get("id") or item.get("name") or ""
        if name:
            names.append(name)
    return names


def parse_pull_event(line: str) -> dict[str, Any] | None:
    text = line.strip()
    if not text:
        return None
    payload = json.loads(text)
    total = int(payload.get("total") or 0)
    completed = int(payload.get("completed") or 0)
    percent = (completed / total * 100.0) if total else None
    return {
        "status": payload.get("status") or "",
        "completed": completed,
        "total": total,
        "percent": percent,
    }


def scan_hf_cache() -> tuple[list[dict[str, Any]], str | None]:
    try:
        from huggingface_hub import scan_cache_dir
    except ImportError as exc:
        return [], str(exc)
    try:
        cache = scan_cache_dir()
    except Exception as exc:
        return [], str(exc)
    rows: list[dict[str, Any]] = []
    for repo in getattr(cache, "repos", []) or []:
        revision = ""
        revisions = list(getattr(repo, "revisions", []) or [])
        if revisions:
            revision = getattr(revisions[0], "commit_hash", "") or ""
        rows.append(
            {
                "repo_id": getattr(repo, "repo_id", "") or "",
                "revision": revision,
                "size": int(getattr(repo, "size_on_disk", 0) or 0),
            }
        )
    return parse_hf_cache(rows), None


def vlm_report(
    cache_rows: list[dict[str, Any]],
    server_models: list[str] | None = None,
) -> list[dict[str, Any]]:
    cached = {row["repo_id"]: row for row in cache_rows}
    served = set(server_models or [])
    report: list[dict[str, Any]] = []
    for name, spec in KNOWN_VLM.items():
        if spec["engine"] == "mlx":
            report.append(
                {
                    "name": name,
                    "available": False,
                    "engine": "mlx",
                    "repo_id": spec["repo_id"],
                    "revision": None,
                    "size": None,
                    "reason": "mlx-vlm is Apple-only and is not installed on the worker",
                }
            )
            continue
        row = cached.get(spec["repo_id"])
        served_here = name in served or spec["repo_id"] in served
        available = row is not None or served_here
        report.append(
            {
                "name": name,
                "available": available,
                "engine": spec["engine"],
                "repo_id": spec["repo_id"],
                "revision": (row or {}).get("revision") or None,
                "size": (row or {}).get("size"),
                "reason": None if available else "not in the Hugging Face cache or the model server",
            }
        )
    return report


def recommended(host: str) -> list[str]:
    if host == "mac":
        return list(RECOMMENDED["mac"])
    return [name for name in RECOMMENDED["devbox"] if not name.endswith("-mlx")]


ProgressCallback = Callable[[float | None, str], None]


def snapshot_download_runner(repo_id: str, revision: str | None, on_progress: ProgressCallback, cancel_event) -> None:
    if cancel_event.is_set():
        return
    on_progress(0, "starting")
    try:
        from huggingface_hub import snapshot_download
    except ImportError as exc:
        raise RuntimeError("huggingface_hub is not installed") from exc
    if cancel_event.is_set():
        return
    snapshot_download(repo_id, revision=revision)
    on_progress(100, "done")


class DownloadManager:
    def __init__(self, download: Callable[..., None] | None = None) -> None:
        import threading

        self._download = download or snapshot_download_runner
        self._jobs: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def start(self, repo_id: str, revision: str | None = None) -> str:
        import threading
        import uuid

        job_id = uuid.uuid4().hex
        cancel = threading.Event()
        record: dict[str, Any] = {
            "id": job_id,
            "repo_id": repo_id,
            "revision": revision,
            "status": "running",
            "percent": None,
            "message": "starting",
            "cancel": cancel,
        }
        with self._lock:
            self._jobs[job_id] = record

        def run() -> None:
            try:
                def on_progress(percent: float | None, message: str) -> None:
                    record["percent"] = percent
                    record["message"] = message

                self._download(repo_id, revision, on_progress, cancel)
                if cancel.is_set():
                    record["status"] = "canceled"
                else:
                    record["status"] = "succeeded"
                    record["percent"] = 100
                    record["message"] = "done"
            except Exception as exc:
                record["status"] = "failed"
                record["message"] = str(exc)

        threading.Thread(target=run, name=f"chunky-download-{job_id[:8]}", daemon=True).start()
        return job_id

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._jobs.get(job_id)
        if record is None:
            return None
        return {key: value for key, value in record.items() if key != "cancel"}

    def cancel(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._jobs.get(job_id)
        if record is None:
            return None
        record["cancel"].set()
        record["status"] = "canceled"
        record["message"] = "canceled"
        return self.get(job_id)
