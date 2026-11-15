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


def layout_preset_id(layout_model: str | None) -> str | None:
    """Docling layout preset for a picker value. ``default`` stays unset."""
    if not layout_model or layout_model == "default":
        return None
    return LAYOUT_PRESETS.get(layout_model)


def default_chart_host() -> str:
    return "mac" if sys.platform == "darwin" else "devbox"


def chart_extraction_plan(
    *,
    host: str | None = None,
    vlm_engine: str | None = None,
    vllm_url: str | None = None,
) -> dict:
    """Mac uses the MLX Granite Vision 4.1 preset. The devbox uses Transformers or the vLLM API."""
    selected = (host or default_chart_host()).strip().lower()
    engine = (vlm_engine or "").strip().lower()
    if selected in {"mac", "darwin", "local", "localmac"}:
        return {"preset": CHART_MLX_PRESET, "engine": "mlx", "repo_id": CHART_REPO_ID}
    if engine == "vllm":
        base = (vllm_url or "http://127.0.0.1:8000").strip().rstrip("/")
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


def _chart_factories() -> dict:
    from docling.datamodel.pipeline_options import ChartExtractionVlmEngineOptions
    from docling.datamodel.vlm_engine_options import ApiVlmEngineOptions

    return {
        "ChartExtractionVlmEngineOptions": ChartExtractionVlmEngineOptions,
        "ApiVlmEngineOptions": ApiVlmEngineOptions,
    }
