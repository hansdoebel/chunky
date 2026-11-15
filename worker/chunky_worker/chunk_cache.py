"""On-disk cache of a Docling document, its chunk records, and optional vectors."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA = 1


class ChunkCacheError(ValueError):
    def __init__(self, message: str, error_type: str = "invalid_cache") -> None:
        super().__init__(message)
        self.error_type = error_type


def canonical_key(
    content_sha256: str,
    docling_version: str,
    pipeline: str,
    tokenizer: str,
    max_tokens: int,
    options: str = "",
) -> str:
    return "\n".join(
        [
            content_sha256.strip().lower(),
            docling_version.strip(),
            pipeline.strip(),
            tokenizer.strip(),
            str(int(max_tokens)),
            options.strip(),
        ]
    )


def entry_id(
    content_sha256: str,
    docling_version: str,
    pipeline: str,
    tokenizer: str,
    max_tokens: int,
    options: str = "",
) -> str:
    digest = hashlib.sha256(
        canonical_key(content_sha256, docling_version, pipeline, tokenizer, max_tokens, options).encode("utf-8")
    )
    return digest.hexdigest()


def _text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _float(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _strings(value: Any) -> list[str]:
    if isinstance(value, str):
        text = value.strip()
        return [text] if text else []
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if _text(item)]


def normalize_chunk(raw: dict[str, Any]) -> dict[str, Any]:
    """Full citation record. Missing geometry stays empty rather than being invented."""
    pages = [page for page in (_int(item) for item in raw.get("pages") or []) if page is not None]
    page = _int(raw.get("page"))
    if page is None and pages:
        page = pages[0]
    if page is not None and page not in pages:
        pages = [page, *pages]
    page_end = _int(raw.get("page_end"))
    if page_end is None and pages:
        page_end = pages[-1]
    boxes = []
    for item in raw.get("bboxes") or []:
        if not isinstance(item, dict):
            continue
        origin = item.get("coord_origin")
        boxes.append(
            {
                "page": _int(item.get("page")),
                "l": _float(item.get("l")),
                "t": _float(item.get("t")),
                "r": _float(item.get("r")),
                "b": _float(item.get("b")),
                "coord_origin": origin if isinstance(origin, str) and origin else None,
            }
        )
    record = {
        "text": str(raw.get("text") or ""),
        "embedding_text": str(raw.get("embedding_text") or raw.get("text") or ""),
        "page": page,
        "page_end": page_end,
        "pages": pages,
        "page_labels": _strings(raw.get("page_labels")),
        "headings": _strings(raw.get("headings")),
        "bboxes": boxes,
        "doc_title": _text(raw.get("doc_title")),
        "authors": _strings(raw.get("authors")),
        "year": _int(raw.get("year")),
        "doi": _text(raw.get("doi")),
        "source": _text(raw.get("source")) or "",
        "url": _text(raw.get("url")),
        "language": _text(raw.get("language")),
        "content_type": _text(raw.get("content_type")) or "text",
        "chunk_index": _int(raw.get("chunk_index")) or 0,
        "token_count": _int(raw.get("token_count")) or 0,
        "picture_description": _text(raw.get("picture_description")),
        "picture_class": _text(raw.get("picture_class")),
        "table_markdown": _text(raw.get("table_markdown")),
    }
    prefix = _text(raw.get("context_prefix"))
    if prefix:
        record["context_prefix"] = prefix
    return record


def apply_identity(chunks: list[dict[str, Any]], identity: dict[str, Any]) -> list[dict[str, Any]]:
    filled = []
    for raw in chunks:
        chunk = dict(raw)
        for key in ("doc_title", "doi", "source", "year"):
            if chunk.get(key) in (None, "") and identity.get(key) not in (None, ""):
                chunk[key] = identity[key]
        if not chunk.get("authors") and identity.get("authors"):
            chunk["authors"] = identity["authors"]
        filled.append(normalize_chunk(chunk))
    return filled


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
    tmp = Path(name)
    try:
        os.write(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(tmp, path)
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp.exists():
            tmp.unlink()


def _dump(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class ChunkCache:
    def __init__(self, root: Path, limit_bytes: int = 0) -> None:
        self.root = Path(root)
        self.limit_bytes = max(0, int(limit_bytes))
        self._lock = threading.Lock()

    def stats(self) -> dict[str, Any]:
        with self._lock:
            manifest = self._load_manifest()
            return {
                "schema": SCHEMA,
                "entries": len(manifest["entries"]),
                "bytes": sum(int(row.get("bytes") or 0) for row in manifest["entries"]),
                "limit_bytes": self.limit_bytes,
            }

    def lookup(
        self,
        key: dict[str, Any],
        embedding_model: str | None = None,
        embedding_dim: int | None = None,
        include_document: bool = False,
    ) -> dict[str, Any] | None:
        with self._lock:
            manifest = self._load_manifest()
            ident = self._id(key)
            row = next((item for item in manifest["entries"] if item["id"] == ident), None)
            chunks_path = self._entry_dir(ident) / "chunks.json"
            if row is None or not chunks_path.is_file():
                return None
            chunks = json.loads(chunks_path.read_text(encoding="utf-8"))
            row["last_used_at"] = _now()
            self._write_manifest(manifest)
            payload: dict[str, Any] = {
                "hit": True,
                "id": ident,
                "chunks": chunks,
                "vector_hit": False,
                "vectors": None,
            }
            if include_document:
                document_path = self._entry_dir(ident) / "document.json"
                payload["document"] = json.loads(document_path.read_text(encoding="utf-8")) if document_path.is_file() else None
            if embedding_model and embedding_dim:
                vectors = self._read_vectors(ident, embedding_model, int(embedding_dim))
                payload["vector_hit"] = vectors is not None
                payload["vectors"] = vectors
            return payload

    def store(
        self,
        key: dict[str, Any],
        document: Any,
        chunks: list[dict[str, Any]],
        identity: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if not isinstance(document, dict):
            raise ChunkCacheError("document must be a JSON object", "invalid_document")
        if not isinstance(chunks, list) or not chunks:
            raise ChunkCacheError("chunks must be a non-empty list", "invalid_chunks")
        normalized = apply_identity(chunks, identity or {})
        with self._lock:
            ident = self._id(key)
            directory = self._entry_dir(ident)
            directory.mkdir(parents=True, exist_ok=True)
            vectors_dir = directory / "vectors"
            if vectors_dir.exists():
                self._remove_tree(vectors_dir)
            atomic_write(directory / "document.json", _dump(document))
            atomic_write(directory / "chunks.json", _dump(normalized))
            manifest = self._load_manifest()
            row = self._row(ident, key, [])
            manifest["entries"] = [item for item in manifest["entries"] if item["id"] != ident]
            manifest["entries"].append(row)
            self._evict(manifest, protect=ident)
            self._write_manifest(manifest)
            return {"id": ident, "bytes": row["bytes"], "chunks": len(normalized)}

    def store_vectors(
        self,
        key: dict[str, Any],
        model: str,
        dimension: int,
        vectors: list[list[float]],
    ) -> dict[str, Any]:
        model = model.strip()
        dimension = int(dimension)
        if not model or dimension < 1:
            raise ChunkCacheError("vectors need a model id and a positive dimension", "invalid_vectors")
        if not vectors or any(len(row) != dimension for row in vectors):
            raise ChunkCacheError("every vector must match the declared dimension", "invalid_vectors")
        with self._lock:
            ident = self._id(key)
            chunks_path = self._entry_dir(ident) / "chunks.json"
            if not chunks_path.is_file():
                raise ChunkCacheError("store chunks before vectors", "missing_chunks")
            saved_chunks = json.loads(chunks_path.read_text(encoding="utf-8"))
            if len(vectors) != len(saved_chunks):
                raise ChunkCacheError("vector count must match the saved chunks", "invalid_vectors")
            body = {"model": model, "dimension": dimension, "vectors": vectors}
            path = self._vector_path(ident, model, dimension)
            atomic_write(path, _dump(body))
            manifest = self._load_manifest()
            row = next((item for item in manifest["entries"] if item["id"] == ident), None)
            if row is None:
                row = self._row(ident, key, [])
                manifest["entries"].append(row)
            kept = [item for item in row.get("vectors") or [] if not (item.get("model") == model and item.get("dimension") == dimension)]
            kept.append({"model": model, "dimension": dimension, "bytes": path.stat().st_size})
            row["vectors"] = kept
            row["bytes"] = self._entry_bytes(ident)
            row["last_used_at"] = _now()
            self._evict(manifest, protect=ident)
            self._write_manifest(manifest)
            return {"id": ident, "model": model, "dimension": dimension, "count": len(vectors)}

    def clear(self) -> None:
        with self._lock:
            entries = self.root / "entries"
            if entries.exists():
                for child in entries.iterdir():
                    self._remove_tree(child)
            self._write_manifest({"schema": SCHEMA, "entries": []})

    def _id(self, key: dict[str, Any]) -> str:
        return entry_id(
            str(key["content_sha256"]),
            str(key["docling_version"]),
            str(key["pipeline"]),
            str(key.get("tokenizer") or ""),
            int(key["max_tokens"]),
            str(key.get("options") or ""),
        )

    def _entry_dir(self, ident: str) -> Path:
        return self.root / "entries" / ident

    def _vector_path(self, ident: str, model: str, dimension: int) -> Path:
        digest = hashlib.sha256(f"{model}\n{dimension}".encode("utf-8")).hexdigest()[:16]
        return self._entry_dir(ident) / "vectors" / f"{digest}.json"

    def _read_vectors(self, ident: str, model: str, dimension: int) -> list[list[float]] | None:
        path = self._vector_path(ident, model, dimension)
        if not path.is_file():
            return None
        body = json.loads(path.read_text(encoding="utf-8"))
        if body.get("model") != model or body.get("dimension") != dimension:
            return None
        return body.get("vectors")

    def _row(self, ident: str, key: dict[str, Any], vectors: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "id": ident,
            "content_sha256": str(key["content_sha256"]).strip().lower(),
            "docling_version": str(key["docling_version"]).strip(),
            "pipeline": str(key["pipeline"]).strip(),
            "tokenizer": str(key.get("tokenizer") or "").strip(),
            "max_tokens": int(key["max_tokens"]),
            "options": str(key.get("options") or "").strip(),
            "bytes": self._entry_bytes(ident),
            "last_used_at": _now(),
            "vectors": vectors,
        }

    def _entry_bytes(self, ident: str) -> int:
        directory = self._entry_dir(ident)
        if not directory.exists():
            return 0
        total = 0
        for path in directory.rglob("*"):
            if path.is_file() and not path.name.startswith(".tmp-"):
                total += path.stat().st_size
        return total

    def _manifest_path(self) -> Path:
        return self.root / "manifest.json"

    def _load_manifest(self) -> dict[str, Any]:
        path = self._manifest_path()
        if not path.is_file():
            return {"schema": SCHEMA, "entries": []}
        try:
            body = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ChunkCacheError("cache manifest is not JSON", "corrupt_manifest") from exc
        if not isinstance(body, dict) or not isinstance(body.get("entries"), list):
            raise ChunkCacheError("cache manifest is missing entries", "corrupt_manifest")
        return body

    def _write_manifest(self, manifest: dict[str, Any]) -> None:
        atomic_write(self._manifest_path(), _dump(manifest))

    def _evict(self, manifest: dict[str, Any], protect: str) -> None:
        if self.limit_bytes <= 0:
            return
        def total() -> int:
            return sum(int(row.get("bytes") or 0) for row in manifest["entries"])

        ordered = sorted(manifest["entries"], key=lambda row: row.get("last_used_at") or "")
        for row in ordered:
            if total() <= self.limit_bytes:
                break
            if row["id"] == protect and len(manifest["entries"]) == 1:
                break
            if row["id"] == protect:
                continue
            self._remove_tree(self._entry_dir(row["id"]))
            manifest["entries"] = [item for item in manifest["entries"] if item["id"] != row["id"]]

    def _remove_tree(self, path: Path) -> None:
        if not path.exists():
            return
        for child in sorted(path.rglob("*"), reverse=True):
            if child.is_file() or child.is_symlink():
                child.unlink()
            else:
                child.rmdir()
        if path.exists():
            path.rmdir()
