"""Worker process settings from the environment."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

from chunky_worker.vlm import normalize_vlm_engine


def default_state_dir() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME")
    if xdg:
        return Path(xdg)
    return Path.home() / ".local" / "state"


def default_log_dir() -> Path:
    override = os.environ.get("CHUNKY_LOG_DIR")
    if override:
        return Path(override)
    return default_state_dir() / "chunky" / "logs"


def default_work_dir() -> Path:
    override = os.environ.get("CHUNKY_WORK_DIR")
    if override:
        return Path(override)
    return default_state_dir() / "chunky" / "work"


def default_config_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg)
    return Path.home() / ".config"


def default_token_file() -> Path:
    override = os.environ.get("CHUNKY_WORKER_TOKEN_FILE")
    if override:
        return Path(override)
    return default_config_dir() / "chunky" / "worker.token"


def load_token() -> str | None:
    """Load the bearer token. Env wins over a file. Never logs the value.

    ``CHUNKY_WORKER_TOKEN`` set to a non-empty string is used as-is (stripped).
    An explicitly empty env value disables the file fallback.
    ``CHUNKY_WORKER_TOKEN_FILE`` is required to exist when set.
    Otherwise ``$XDG_CONFIG_HOME/chunky/worker.token`` (default
    ``~/.config/chunky/worker.token``) is used when that file exists.
    """
    if "CHUNKY_WORKER_TOKEN" in os.environ:
        value = os.environ.get("CHUNKY_WORKER_TOKEN", "").strip()
        return value or None

    path = default_token_file()
    explicit_file = "CHUNKY_WORKER_TOKEN_FILE" in os.environ
    if not path.is_file():
        if explicit_file:
            raise FileNotFoundError(f"CHUNKY_WORKER_TOKEN_FILE does not exist: {path}")
        return None
    value = path.read_text(encoding="utf-8").strip()
    return value or None


def is_loopback_url(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower().strip("[]")
    return host in {"127.0.0.1", "localhost", "::1"}


def default_scripts_dir() -> Path:
    override = os.environ.get("CHUNKY_SCRIPTS_DIR")
    if override:
        return Path(override)
    # worker/chunky_worker/settings.py -> repo root / Chunky/Resources/Scripts
    repo_root = Path(__file__).resolve().parents[2]
    return repo_root / "Chunky" / "Resources" / "Scripts"


@dataclass
class Settings:
    host: str = "127.0.0.1"
    port: int = 8080
    log_dir: Path = field(default_factory=default_log_dir)
    work_dir: Path = field(default_factory=default_work_dir)
    scripts_dir: Path = field(default_factory=default_scripts_dir)
    ollama_url: str = "http://127.0.0.1:11434"
    vllm_url: str = "http://127.0.0.1:8000"
    # Empty keeps chart extraction on Transformers. The document vLLM server
    # only serves granite-docling.
    chart_vllm_url: str = ""
    # vllm calls the granite_docling preset. transformers is the in-process fallback.
    vlm_engine: str = "vllm"
    embedding_model: str = "qwen3-embedding"
    embedding_backend: str = "ollama"
    embedding_url: str = ""
    qdrant_url: str = ""
    qdrant_api_key: str = field(default="", repr=False)
    # None means protected routes reject every request (fail closed).
    token: str | None = None

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            host=os.environ.get("CHUNKY_WORKER_HOST", "127.0.0.1"),
            port=int(os.environ.get("CHUNKY_WORKER_PORT", "8080")),
            log_dir=default_log_dir(),
            work_dir=default_work_dir(),
            scripts_dir=default_scripts_dir(),
            ollama_url=os.environ.get("CHUNKY_OLLAMA_URL", "http://127.0.0.1:11434"),
            vllm_url=os.environ.get("CHUNKY_VLLM_URL", "http://127.0.0.1:8000"),
            chart_vllm_url=os.environ.get("CHUNKY_CHART_VLLM_URL", "").strip(),
            vlm_engine=normalize_vlm_engine(os.environ.get("CHUNKY_VLM_ENGINE", "vllm")),
            embedding_model=os.environ.get("CHUNKY_EMBEDDING_MODEL", "qwen3-embedding"),
            embedding_backend=os.environ.get("CHUNKY_EMBEDDING_BACKEND", "ollama").strip().lower() or "ollama",
            embedding_url=os.environ.get("CHUNKY_EMBEDDING_URL", "").strip(),
            qdrant_url=os.environ.get("CHUNKY_QDRANT_URL", "").strip(),
            qdrant_api_key=os.environ.get("CHUNKY_QDRANT_API_KEY", "").strip(),
            token=load_token(),
        )
