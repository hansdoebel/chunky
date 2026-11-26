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

def default_cache_dir() -> Path:
    override = os.environ.get("CHUNKY_WORKER_CACHE_DIR")
    if override:
        return Path(override)
    return default_state_dir() / "chunky" / "cache"


def default_cache_limit_bytes() -> int:
    raw = os.environ.get("CHUNKY_WORKER_CACHE_LIMIT_BYTES", "").strip()
    if not raw:
        return 0
    try:
        return max(0, int(raw))
    except ValueError:
        return 0


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

def is_loopback_host(host: str) -> bool:
    value = host.lower().strip().strip("[]")
    return value in {"127.0.0.1", "localhost", "::1"}

def is_loopback_url(url: str) -> bool:
    return is_loopback_host(urlparse(url).hostname or "")

class BindWithoutTokenError(RuntimeError):
    pass

def require_token_when_exposed(settings: "Settings") -> None:
    if is_loopback_host(settings.host):
        return
    if settings.token:
        return
    raise BindWithoutTokenError(
        f"Refusing to bind {settings.host}:{settings.port} without a bearer token. "
        "Set CHUNKY_WORKER_TOKEN or CHUNKY_WORKER_TOKEN_FILE. "
        "Loopback (127.0.0.1, localhost, ::1) may start without one."
    )

def _vector_store_from_env() -> str:
    from chunky_worker.vector_store import StoreError, configured_store

    try:
        return configured_store(os.environ.get("CHUNKY_VECTOR_STORE", ""))
    except StoreError as exc:
        raise ValueError(str(exc)) from exc


def default_scripts_dir() -> Path:
    override = os.environ.get("CHUNKY_SCRIPTS_DIR")
    if override:
        return Path(override)

    repo_root = Path(__file__).resolve().parents[2]
    return repo_root / "Chunky" / "Resources" / "Scripts"

@dataclass
class Settings:
    host: str = "127.0.0.1"
    port: int = 8080
    log_dir: Path = field(default_factory=default_log_dir)
    work_dir: Path = field(default_factory=default_work_dir)
    cache_dir: Path = field(default_factory=default_cache_dir)
    cache_limit_bytes: int = 0
    scripts_dir: Path = field(default_factory=default_scripts_dir)
    ollama_url: str = "http://127.0.0.1:11434"
    vllm_url: str = "http://127.0.0.1:8000"

    chart_vllm_url: str = ""

    vlm_engine: str = "vllm"
    embedding_model: str = "qwen3-embedding:0.6b"
    embedding_backend: str = "ollama"
    embedding_url: str = ""
    qdrant_url: str = ""
    qdrant_api_key: str = field(default="", repr=False)
    vector_store: str = "qdrant"
    vector_store_url: str = ""
    vector_store_api_key: str = field(default="", repr=False)

    token: str | None = None

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            host=os.environ.get("CHUNKY_WORKER_HOST", "127.0.0.1"),
            port=int(os.environ.get("CHUNKY_WORKER_PORT", "8080")),
            log_dir=default_log_dir(),
            work_dir=default_work_dir(),
            cache_dir=default_cache_dir(),
            cache_limit_bytes=default_cache_limit_bytes(),
            scripts_dir=default_scripts_dir(),
            ollama_url=os.environ.get("CHUNKY_OLLAMA_URL", "http://127.0.0.1:11434"),
            vllm_url=os.environ.get("CHUNKY_VLLM_URL", "http://127.0.0.1:8000"),
            chart_vllm_url=os.environ.get("CHUNKY_CHART_VLLM_URL", "").strip(),
            vlm_engine=normalize_vlm_engine(os.environ.get("CHUNKY_VLM_ENGINE", "vllm")),
            embedding_model=os.environ.get("CHUNKY_EMBEDDING_MODEL", "qwen3-embedding:0.6b"),
            embedding_backend=os.environ.get("CHUNKY_EMBEDDING_BACKEND", "ollama").strip().lower() or "ollama",
            embedding_url=os.environ.get("CHUNKY_EMBEDDING_URL", "").strip(),
            qdrant_url=os.environ.get("CHUNKY_QDRANT_URL", "").strip(),
            qdrant_api_key=os.environ.get("CHUNKY_QDRANT_API_KEY", "").strip(),
            vector_store=_vector_store_from_env(),
            vector_store_url=os.environ.get("CHUNKY_VECTOR_STORE_URL", "").strip(),
            vector_store_api_key=os.environ.get("CHUNKY_VECTOR_STORE_API_KEY", "").strip(),
            token=load_token(),
        )
