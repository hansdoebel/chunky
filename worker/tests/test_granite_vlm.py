"""Granite-docling uses the DocTags preset. The worker never imports MLX."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from chunky_worker.models import JobSettings
from chunky_worker.pipeline import DoclingPipeline
from chunky_worker.vlm import (
    build_granite_pipeline_options,
    chat_completions_url,
    granite_engine_for,
    granite_plan,
    normalize_vlm_engine,
)

def test_vllm_plan_uses_doctags_preset_and_leaves_flash_attention_off():
    plan = granite_plan("vllm", "http://127.0.0.1:8000", "mps")
    assert plan["preset"] == "granite_docling"
    assert plan["engine"] == "vllm"
    assert plan["repo_id"] == "ibm-granite/granite-docling-258M"
    assert plan["device"] == "cuda"
    assert plan["cuda_use_flash_attention2"] is False
    assert plan["url"] == "http://127.0.0.1:8000/v1/chat/completions"
    assert plan["params"]["model"] == "ibm-granite/granite-docling-258M"
    assert plan["params"]["skip_special_tokens"] is False
    assert plan["page_batch_size"] >= plan["concurrency"]
    assert chat_completions_url("http://127.0.0.1:8000/v1") == plan["url"]
    assert chat_completions_url(plan["url"]) == plan["url"]

def test_transformers_fallback_is_cuda_without_flash_attention():
    plan = granite_plan("transformers", "http://127.0.0.1:8000", "cuda")
    assert plan["engine"] == "transformers"
    assert plan["device"] == "cuda"
    assert plan["cuda_use_flash_attention2"] is False
    assert "url" not in plan
    cpu = granite_plan("transformers", "http://127.0.0.1:8000", "cpu")
    assert cpu["device"] == "cpu"
    assert cpu["cuda_use_flash_attention2"] is False

def test_mlx_granite_selects_the_configured_engine_and_other_models_do_not():
    assert granite_engine_for("granite-docling-mlx", "vllm") == "vllm"
    assert granite_engine_for("granite-docling-transformers", "transformers") == "transformers"
    assert granite_engine_for("smoldocling-mlx", "vllm") is None
    assert granite_engine_for("standard", "vllm") is None
    with pytest.raises(ValueError, match="vllm"):
        normalize_vlm_engine("mlx")

def test_preset_builder_calls_from_preset_and_pins_the_accelerator():
    plan = granite_plan("vllm", "http://127.0.0.1:8000/", "auto")
    seen: dict = {}

    class Api:
        def __init__(self, **kwargs):
            seen["api"] = kwargs

    class Convert:
        @staticmethod
        def from_preset(preset, engine_options=None):
            seen["preset"] = preset
            seen["engine"] = engine_options
            return {"preset": preset}

    class Pipeline:
        def __init__(self, **kwargs):
            seen["pipeline"] = kwargs

    class Accel:
        def __init__(self, **kwargs):
            seen["accel"] = kwargs

    build_granite_pipeline_options(
        plan,
        factories={
            "ApiVlmEngineOptions": Api,
            "TransformersVlmEngineOptions": Api,
            "VlmConvertOptions": Convert,
            "VlmPipelineOptions": Pipeline,
            "AcceleratorOptions": Accel,
            "GRANITEDOCLING_TRANSFORMERS": "GRANITEDOCLING_TRANSFORMERS",
        },
    )
    assert seen["preset"] == "granite_docling"
    assert seen["api"]["url"].endswith("/v1/chat/completions")
    assert seen["api"]["params"]["skip_special_tokens"] is False
    assert seen["accel"] == {"device": "cuda", "cuda_use_flash_attention2": False}
    assert seen["pipeline"]["enable_remote_services"] is True

def test_transformers_falls_back_to_the_spec_when_the_preset_api_is_missing():
    plan = granite_plan("transformers", "http://127.0.0.1:8000", "cuda")
    seen: dict = {}

    class Convert:
        @staticmethod
        def from_preset(*_args, **_kwargs):
            raise ImportError("VlmConvertOptions.from_preset is unavailable")

    class Pipeline:
        def __init__(self, **kwargs):
            seen["pipeline"] = kwargs

    class Accel:
        def __init__(self, **kwargs):
            seen["accel"] = kwargs

    build_granite_pipeline_options(
        plan,
        factories={
            "ApiVlmEngineOptions": Accel,
            "TransformersVlmEngineOptions": Accel,
            "VlmConvertOptions": Convert,
            "VlmPipelineOptions": Pipeline,
            "AcceleratorOptions": Accel,
            "GRANITEDOCLING_TRANSFORMERS": "GRANITEDOCLING_TRANSFORMERS",
        },
    )
    assert seen["pipeline"]["vlm_options"] == "GRANITEDOCLING_TRANSFORMERS"
    assert seen["pipeline"]["enable_remote_services"] is False
    assert seen["accel"]["cuda_use_flash_attention2"] is False

def test_vllm_does_not_hide_a_missing_preset_api():
    plan = granite_plan("vllm", "http://127.0.0.1:8000", "cuda")

    class Convert:
        @staticmethod
        def from_preset(*_args, **_kwargs):
            raise ImportError("missing")

    class Unused:
        def __init__(self, **_kwargs):
            return None

    with pytest.raises(ImportError):
        build_granite_pipeline_options(
            plan,
            factories={
                "ApiVlmEngineOptions": Unused,
                "TransformersVlmEngineOptions": Unused,
                "VlmConvertOptions": Convert,
                "VlmPipelineOptions": Unused,
                "AcceleratorOptions": Unused,
                "GRANITEDOCLING_TRANSFORMERS": "GRANITEDOCLING_TRANSFORMERS",
            },
        )

def test_non_granite_jobs_do_not_select_the_vllm_preset(tmp_path: Path):
    seen: dict = {}

    def fake_convert(**kwargs):
        seen.update(kwargs)
        return {"success": True, "chunks": []}

    pipeline = DoclingPipeline(tmp_path, vlm_engine="vllm", vllm_url="http://127.0.0.1:8000")
    pipeline._load_convert = lambda: fake_convert  # type: ignore[method-assign]
    pipeline.convert_and_chunk(
        input_path=tmp_path / "in.pdf",
        output_dir=tmp_path,
        settings=JobSettings(vlm_model="smoldocling-mlx", accelerator="mps"),
        on_progress=lambda *_args: None,
        cancel_event=threading.Event(),
    )
    assert seen["vlm_model"] == "smoldocling-transformers"
    assert seen["vlm_engine"] is None
    assert seen["chart_engine"] == "vllm"
    assert seen["chart_vllm_url"] == ""
    assert seen["accelerator"] == "cuda"
