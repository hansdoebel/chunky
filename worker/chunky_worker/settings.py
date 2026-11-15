"""Worker process settings from the environment."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


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
    embedding_model: str = "qwen3-embedding"

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            host=os.environ.get("CHUNKY_WORKER_HOST", "127.0.0.1"),
            port=int(os.environ.get("CHUNKY_WORKER_PORT", "8080")),
            log_dir=default_log_dir(),
            work_dir=default_work_dir(),
            scripts_dir=default_scripts_dir(),
            ollama_url=os.environ.get("CHUNKY_OLLAMA_URL", "http://127.0.0.1:11434"),
            embedding_model=os.environ.get("CHUNKY_EMBEDDING_MODEL", "qwen3-embedding"),
        )
