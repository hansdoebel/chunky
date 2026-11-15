"""CLI entry point: ``python -m chunky_worker`` or ``chunky-worker``."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import uvicorn

from chunky_worker.app import create_app
from chunky_worker.auth import generate_token, write_token_file
from chunky_worker.logging_config import configure_logging
from chunky_worker.settings import Settings


def main() -> None:
    parser = argparse.ArgumentParser(description="Chunky document-processing worker")
    parser.add_argument("--host", default=os.environ.get("CHUNKY_WORKER_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CHUNKY_WORKER_PORT", "8080")))
    parser.add_argument(
        "--generate-token",
        action="store_true",
        help="Print a new bearer token and exit. Does not start the server.",
    )
    parser.add_argument(
        "--token-file",
        type=Path,
        default=None,
        help="With --generate-token, write the token to this path (mode 0600) as well as stdout.",
    )
    args = parser.parse_args()

    if args.generate_token:
        if args.token_file is not None:
            token = write_token_file(args.token_file)
            print(f"Wrote token to {args.token_file} (mode 0600)", file=sys.stderr)
        else:
            token = generate_token()
        # stdout is the copy-once channel for the operator. The logging module is not used.
        print(token)
        return

    settings = Settings.from_env()
    settings.host = args.host
    settings.port = args.port
    configure_logging(settings.log_dir)
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
