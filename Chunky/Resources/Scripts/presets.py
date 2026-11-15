"""Layout and chart-extraction preset ids. Does not import Docling."""

from __future__ import annotations

import sys

LAYOUT_PRESETS = {
    "heron": "layout_heron_default",
    "egret-medium": "layout_egret_medium",
    "egret-large": "layout_egret_large",
    "egret-xlarge": "layout_egret_xlarge",
}

CHART_MLX_PRESET = "granite_vision_v4_mlx"
CHART_TRANSFORMERS_PRESET = "granite_vision_v4"
CHART_REPO_ID = "ibm-granite/granite-vision-4.1-4b"

PICTURE_PRESETS = {
    "smolvlm": {
        "preset": "smolvlm",
        "repo_id": "HuggingFaceTB/SmolVLM-256M-Instruct",
        "name": "SmolVLM-256M",
    },
    "granite_vision": {
        "preset": "granite_vision",
        "repo_id": "ibm-granite/granite-vision-3.3-2b",
        "name": "Granite-Vision-3.3-2B",
    },
    "qwen": {
        "preset": "qwen",
        "repo_id": "Qwen/Qwen2.5-VL-3B-Instruct",
        "name": "Qwen2.5-VL-3B",
    },
}

def layout_preset_id(layout_model: str | None) -> str | None:
    """Docling layout preset for a picker value. ``default`` stays unset."""
    if not layout_model or layout_model == "default":
        return None
    return LAYOUT_PRESETS.get(layout_model)

DOCUMENTED_NVIDIA_VLM_CONCURRENCY = 64

def _is_mac(host: str | None) -> bool:
    return (host or default_chart_host()).strip().lower() in {"mac", "darwin", "local", "localmac"}

def batch_plan(
    *,
    host: str | None = None,
    vlm_resident: bool = False,
    workers: int = 8,
    ocr_batch_size: int = 0,
    layout_batch_size: int = 0,
    table_batch_size: int = 0,
) -> dict:
    """Batch sizes for the standard pipeline.

    A devbox with no vision model resident uses Docling's GPU starting point
    (OCR and layout 64, tables 4). Sharing the GPU uses 8 to 16. The Mac stays
    small and keeps TableFormer on the CPU. Docling's published vLLM
    concurrency of 64 was measured on NVIDIA hardware and is not applied here.
    """
    mac = _is_mac(host)
    if mac:
        plan = {
            "pipeline": "pdf",
            "ocr_batch_size": 2,
            "layout_batch_size": 2,
            "table_batch_size": 1,
            "table_former_device": "cpu",
            "page_batch_size": 2,
            "vlm_concurrency": 1,
            "workers": max(1, min(workers, 4)),
        }
    elif vlm_resident:
        plan = {
            "pipeline": "threaded",
            "ocr_batch_size": 8,
            "layout_batch_size": 16,
            "table_batch_size": 4,
            "table_former_device": "cuda",
            "page_batch_size": 8,
            "vlm_concurrency": 8,
            "workers": max(1, workers),
        }
    else:
        plan = {
            "pipeline": "threaded",
            "ocr_batch_size": 64,
            "layout_batch_size": 64,
            "table_batch_size": 4,
            "table_former_device": "cuda",
            "page_batch_size": 8,
            "vlm_concurrency": 8,
            "workers": max(1, workers),
        }
    if ocr_batch_size > 0:
        plan["ocr_batch_size"] = ocr_batch_size
    if layout_batch_size > 0:
        plan["layout_batch_size"] = layout_batch_size
    if table_batch_size > 0:
        plan["table_batch_size"] = table_batch_size
    if plan["page_batch_size"] < plan["vlm_concurrency"] and not mac:
        plan["page_batch_size"] = plan["vlm_concurrency"]
    plan["vlm_timeout"] = 90
    plan["vlm_max_tokens"] = 4096
    plan["documented_nvidia_vlm_concurrency"] = DOCUMENTED_NVIDIA_VLM_CONCURRENCY
    return plan

def default_chart_host() -> str:
    return "mac" if sys.platform == "darwin" else "devbox"

def chart_extraction_plan(
    *,
    host: str | None = None,
    vlm_engine: str | None = None,
    vllm_url: str | None = None,
) -> dict:
    """Mac uses the MLX Granite Vision 4.1 preset.

    On the devbox, charts use Transformers unless ``vllm_url`` names a server
    that actually serves Granite Vision. The document vLLM process only serves
    granite-docling, so an empty URL stays on Transformers.
    """
    selected = (host or default_chart_host()).strip().lower()
    engine = (vlm_engine or "").strip().lower()
    if selected in {"mac", "darwin", "local", "localmac"}:
        return {"preset": CHART_MLX_PRESET, "engine": "mlx", "repo_id": CHART_REPO_ID}
    chart_url = (vllm_url or "").strip()
    if engine == "vllm" and chart_url:
        base = chart_url.rstrip("/")
        if base.endswith("/chat/completions"):
            url = base
        elif base.endswith("/v1"):
            url = base + "/chat/completions"
        else:
            url = base + "/v1/chat/completions"
        return {
            "preset": CHART_TRANSFORMERS_PRESET,
            "engine": "api",
            "repo_id": CHART_REPO_ID,
            "url": url,
            "params": {"model": CHART_REPO_ID},
        }
    return {"preset": CHART_TRANSFORMERS_PRESET, "engine": "transformers", "repo_id": CHART_REPO_ID}

def apply_chart_extraction(
    options,
    *,
    enabled: bool,
    host: str | None = None,
    vlm_engine: str | None = None,
    vllm_url: str | None = None,
    factories: dict | None = None,
):
    """Set ``chart_extraction_options`` when chart extraction is on and the model has the field."""
    if not enabled:
        return options
    fields = getattr(options, "model_fields", None)
    if isinstance(fields, dict):
        if "chart_extraction_options" not in fields:
            return options
    elif not hasattr(options, "chart_extraction_options"):
        return options

    plan = chart_extraction_plan(host=host, vlm_engine=vlm_engine, vllm_url=vllm_url)
    if factories is None:
        factories = _chart_factories()
    kwargs = {}
    if plan["engine"] == "api":
        kwargs["engine_options"] = factories["ApiVlmEngineOptions"](
            url=plan["url"],
            params=dict(plan["params"]),
        )
    options.chart_extraction_options = factories["ChartExtractionVlmEngineOptions"].from_preset(
        plan["preset"],
        **kwargs,
    )
    return options

def default_picture_preset(host: str | None = None) -> str:
    """SmolVLM on the Mac. Granite Vision 3.3-2B on the devbox."""
    selected = (host or default_chart_host()).strip().lower()
    if selected in {"mac", "darwin", "local", "localmac"}:
        return "smolvlm"
    return "granite_vision"

def qdrant_quality_profile(host: str | None = None) -> dict:
    """Retrieval-quality ingest: describe and classify pictures."""
    return {
        "do_picture_description": True,
        "do_picture_classification": True,
        "picture_description_preset": default_picture_preset(host),
    }

def _chat_url(base: str) -> str:
    trimmed = base.strip().rstrip("/")
    if trimmed.endswith("/chat/completions"):
        return trimmed
    if trimmed.endswith("/v1"):
        return trimmed + "/chat/completions"
    return trimmed + "/v1/chat/completions"

def picture_description_plan(
    preset: str | None = None,
    *,
    host: str | None = None,
    vlm_server_url: str | None = None,
) -> dict:
    """Map a picker value to a Docling picture-description preset.

    ``api`` keeps the host's model and sends it to the VLM server URL.
    That URL is not the embedding Ollama URL.
    """
    chosen = (preset or "").strip().lower() or default_picture_preset(host)
    if chosen == "api":
        model_key = default_picture_preset(host)
        spec = dict(PICTURE_PRESETS[model_key])
        url = (vlm_server_url or "").strip()
        spec.update(
            {
                "engine": "api",
                "picker": "api",
                "url": _chat_url(url) if url else "",
                "params": {"model": spec["repo_id"]},
            }
        )
        return spec
    if chosen not in PICTURE_PRESETS:
        raise ValueError(f"Unknown picture description preset: {chosen}")
    spec = dict(PICTURE_PRESETS[chosen])
    spec.update({"engine": "inline", "picker": chosen})
    return spec

def apply_picture_description(
    options,
    *,
    enabled: bool,
    preset: str | None = None,
    host: str | None = None,
    vlm_server_url: str | None = None,
    factories: dict | None = None,
):
    if not enabled:
        return options
    fields = getattr(options, "model_fields", None)
    if isinstance(fields, dict):
        if "picture_description_options" not in fields:
            return options
    elif not hasattr(options, "picture_description_options"):
        return options
    plan = picture_description_plan(preset, host=host, vlm_server_url=vlm_server_url)
    if plan["engine"] == "api" and not plan["url"]:
        raise ValueError("The API picture preset needs a VLM server URL")
    if factories is None:
        factories = _picture_factories()
    kwargs = {}
    if plan["engine"] == "api":
        kwargs["engine_options"] = factories["ApiVlmEngineOptions"](
            url=plan["url"],
            params=dict(plan["params"]),
        )
    options.picture_description_options = factories["PictureDescriptionVlmEngineOptions"].from_preset(
        plan["preset"],
        **kwargs,
    )
    return options

def _picture_factories() -> dict:
    from docling.datamodel.pipeline_options import PictureDescriptionVlmEngineOptions
    from docling.datamodel.vlm_engine_options import ApiVlmEngineOptions

    return {
        "PictureDescriptionVlmEngineOptions": PictureDescriptionVlmEngineOptions,
        "ApiVlmEngineOptions": ApiVlmEngineOptions,
    }

def _chart_factories() -> dict:
    from docling.datamodel.pipeline_options import ChartExtractionVlmEngineOptions
    from docling.datamodel.vlm_engine_options import ApiVlmEngineOptions

    return {
        "ChartExtractionVlmEngineOptions": ChartExtractionVlmEngineOptions,
        "ApiVlmEngineOptions": ApiVlmEngineOptions,
    }
