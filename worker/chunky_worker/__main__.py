"""CLI entry point: ``python -m chunky_worker`` or ``chunky-worker``."""

from __future__ import annotations

import argparse
import os

import uvicorn

from chunky_worker.app import create_app
from chunky_worker.logging_config import configure_logging
from chunky_worker.settings import Settings


def main() -> None:
    parser = argparse.ArgumentParser(description="Chunky document-processing worker")
    parser.add_argument("--host", default=os.environ.get("CHUNKY_WORKER_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CHUNKY_WORKER_PORT", "8080")))
    args = parser.parse_args()

    settings = Settings.from_env()
    settings.host = args.host
    settings.port = args.port
    configure_logging(settings.log_dir)
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
