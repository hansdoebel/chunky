"""MLX models never reach Docling on the worker."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from chunky_worker.models import JobSettings
from chunky_worker.pipeline import DoclingPipeline
from chunky_worker.vlm import UnsupportedMLXModel, accelerator_for_worker, model_for_worker


def test_known_mlx_models_map_to_transformers():
    assert model_for_worker("granite-docling-mlx") == "granite-docling-transformers"
    assert model_for_worker("smoldocling-mlx") == "smoldocling-transformers"
    assert model_for_worker("granite-docling-transformers") == "granite-docling-transformers"
    assert model_for_worker("standard") is None
    assert model_for_worker(None) is None


def test_unknown_mlx_model_is_rejected():
    with pytest.raises(UnsupportedMLXModel, match="Apple-only"):
        model_for_worker("custom-mlx")


def test_accelerator_defaults_to_cuda_and_rewrites_mps():
    assert accelerator_for_worker(None) == "cuda"
    assert accelerator_for_worker("") == "cuda"
    assert accelerator_for_worker("mps") == "cuda"
    assert accelerator_for_worker("auto") == "cuda"
    assert accelerator_for_worker("cpu") == "cpu"
    assert accelerator_for_worker("cuda") == "cuda"
    assert JobSettings().accelerator == "cuda"


def test_pipeline_rewrites_mlx_before_convert(tmp_path: Path):
    seen: dict = {}

    def fake_convert(**kwargs):
        seen.update(kwargs)
        return {"success": True, "chunks": []}

    pipeline = DoclingPipeline(tmp_path)
    pipeline._load_convert = lambda: fake_convert  # type: ignore[method-assign]
    pipeline.convert_and_chunk(
        input_path=tmp_path / "in.pdf",
        output_dir=tmp_path,
        settings=JobSettings(vlm_model="granite-docling-mlx", accelerator="mps"),
        on_progress=lambda *_args: None,
        cancel_event=threading.Event(),
    )
    assert seen["vlm_model"] == "granite-docling-transformers"
    assert seen["accelerator"] == "cuda"
    assert seen["vlm_engine"] == "vllm"
    assert seen["vllm_url"] == "http://127.0.0.1:8000"
    assert seen["chart_host"] == "devbox"
