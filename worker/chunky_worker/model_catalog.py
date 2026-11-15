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
    granite_engine: str = "transformers",
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
        engine = spec["engine"]
        if name == "granite-docling-transformers" and granite_engine:
            engine = granite_engine
        report.append(
            {
                "name": name,
                "available": available,
                "engine": engine,
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

def fetch_vllm_models(url: str) -> list[str]:
    if not url:
        return []
    try:
        import httpx
    except ImportError:
        return []
    try:
        response = httpx.get(f"{url.rstrip('/')}/v1/models", timeout=0.5)
        response.raise_for_status()
        return parse_openai_models(response.json())
    except Exception:
        return []

def fetch_ollama_tags(url: str) -> tuple[list[dict[str, Any]], str | None]:
    if not url:
        return [], "ollama url is empty"
    try:
        import httpx
    except ImportError as exc:
        return [], str(exc)
    try:
        response = httpx.get(f"{url.rstrip('/')}/api/tags", timeout=0.5)
        response.raise_for_status()
        return parse_ollama_tags(response.json()), None
    except Exception as exc:
        return [], str(exc)

def ollama_pull_runner(base_url: str, model: str, on_progress: ProgressCallback, cancel_event) -> None:
    import httpx

    on_progress(None, "pulling")
    with httpx.stream(
        "POST",
        f"{base_url.rstrip('/')}/api/pull",
        json={"name": model, "stream": True},
        timeout=None,
    ) as response:
        response.raise_for_status()
        for line in response.iter_lines():
            if cancel_event.is_set():
                return
            event = parse_pull_event(line)
            if event is None:
                continue
            on_progress(event["percent"], event["status"] or "pulling")

def snapshot_download_runner(repo_id: str, revision: str | None, on_progress: ProgressCallback, cancel_event) -> None:
    import subprocess
    import sys
    import time

    if cancel_event.is_set():
        return
    on_progress(None, "downloading")
    script = (
        "from huggingface_hub import snapshot_download\n"
        "import sys\n"
        "revision = sys.argv[2] or None\n"
        "snapshot_download(sys.argv[1], revision=revision)\n"
    )
    process = subprocess.Popen(
        [sys.executable, "-c", script, repo_id, revision or ""],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    while process.poll() is None:
        if cancel_event.is_set():
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            return
        time.sleep(0.2)
    if process.returncode != 0:
        error = ""
        if process.stderr is not None:
            error = process.stderr.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(error or f"snapshot_download exited {process.returncode}")
    on_progress(100, "done")

class DownloadBusy(Exception):
    pass

class DownloadManager:
    def __init__(self, download: Callable[..., None] | None = None, ollama_url: str = "http://127.0.0.1:11434") -> None:
        import threading

        self._download = download
        self._ollama_url = ollama_url
        self._jobs: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    def start(self, repo_id: str, revision: str | None = None, kind: str = "huggingface") -> str:
        import threading
        import time
        import uuid

        target = (kind, repo_id, revision or "")
        with self._lock:
            self._expire_locked()
            for record in self._jobs.values():
                if record["target"] == target and record["status"] in {"running", "canceling"}:
                    return record["id"]
            active = sum(1 for record in self._jobs.values() if record["status"] in {"running", "canceling"})
            if active >= 2:
                raise DownloadBusy("Two downloads are already running")
            job_id = uuid.uuid4().hex
            cancel = threading.Event()
            record = {
                "id": job_id,
                "repo_id": repo_id,
                "revision": revision,
                "kind": kind,
                "target": target,
                "status": "running",
                "percent": None,
                "message": "starting",
                "cancel": cancel,
                "updated": time.time(),
            }
            self._jobs[job_id] = record

        def run() -> None:
            try:
                def on_progress(percent: float | None, message: str) -> None:
                    record["percent"] = percent
                    record["message"] = message
                    record["updated"] = time.time()

                self._run_one(repo_id, revision, on_progress, cancel, kind)
                if cancel.is_set():
                    record["status"] = "canceled"
                    record["message"] = "canceled"
                else:
                    record["status"] = "succeeded"
                    record["percent"] = 100
                    record["message"] = "done"
            except Exception as exc:
                if cancel.is_set():
                    record["status"] = "canceled"
                    record["message"] = "canceled"
                else:
                    record["status"] = "failed"
                    record["message"] = str(exc)
            record["updated"] = time.time()

        threading.Thread(target=run, name=f"chunky-download-{job_id[:8]}", daemon=True).start()
        return job_id

    def _run_one(self, repo_id: str, revision: str | None, on_progress: ProgressCallback, cancel_event, kind: str) -> None:
        if self._download is not None:
            self._download(repo_id, revision, on_progress, cancel_event)
            return
        if kind == "ollama":
            ollama_pull_runner(self._ollama_url, repo_id, on_progress, cancel_event)
            return
        snapshot_download_runner(repo_id, revision, on_progress, cancel_event)

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._jobs.get(job_id)
        if record is None:
            return None
        return {key: value for key, value in record.items() if key not in {"cancel", "target"}}

    def cancel(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            record = self._jobs.get(job_id)
        if record is None:
            return None
        record["cancel"].set()
        if record["status"] == "running":
            record["status"] = "canceling"
            record["message"] = "canceling"
        return self.get(job_id)

    def _expire_locked(self) -> None:
        import time

        now = time.time()
        finished = [
            (record["updated"], job_id)
            for job_id, record in self._jobs.items()
            if record["status"] in {"succeeded", "failed", "canceled"}
        ]
        for updated, job_id in finished:
            if now - updated > 3600:
                self._jobs.pop(job_id, None)
        finished = [
            (record["updated"], job_id)
            for job_id, record in self._jobs.items()
            if record["status"] in {"succeeded", "failed", "canceled"}
        ]
        if len(finished) > 20:
            for _, job_id in sorted(finished)[: len(finished) - 20]:
                self._jobs.pop(job_id, None)
