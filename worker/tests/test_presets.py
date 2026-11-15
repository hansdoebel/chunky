"""Heron layout and Granite Vision chart presets."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from presets import (  # noqa: E402
    apply_chart_extraction,
    chart_extraction_plan,
    layout_preset_id,
)


def test_heron_maps_to_the_docling_layout_preset():
    assert layout_preset_id("heron") == "layout_heron_default"
    assert layout_preset_id("egret-medium") == "layout_egret_medium"
    assert layout_preset_id("egret-large") == "layout_egret_large"
    assert layout_preset_id("egret-xlarge") == "layout_egret_xlarge"
    assert layout_preset_id("default") is None
    assert layout_preset_id(None) is None


class ChartOptions:
    model_fields = {"chart_extraction_options": None, "do_chart_extraction": None}

    def __init__(self):
        self.chart_extraction_options = None
        self.do_chart_extraction = False


class ChartFactory:
    def __init__(self):
        self.calls = []

    def from_preset(self, preset, **kwargs):
        self.calls.append((preset, kwargs))
        return {"preset": preset, **kwargs}


class Api:
    def __init__(self, **kwargs):
        self.kwargs = kwargs


def _apply(host, engine="transformers", enabled=True, url="http://127.0.0.1:8000"):
    factory = ChartFactory()
    options = ChartOptions()
    apply_chart_extraction(
        options,
        enabled=enabled,
        host=host,
        vlm_engine=engine,
        vllm_url=url,
        factories={
            "ChartExtractionVlmEngineOptions": factory,
            "ApiVlmEngineOptions": Api,
        },
    )
    return options, factory


def test_chart_extraction_uses_mlx_on_mac_and_transformers_or_api_on_devbox():
    mac, mac_factory = _apply("mac")
    assert mac_factory.calls[0][0] == "granite_vision_v4_mlx"
    assert mac_factory.calls[0][1] == {}
    assert mac.chart_extraction_options["preset"] == "granite_vision_v4_mlx"

    transformers, transformers_factory = _apply("devbox", "transformers")
    assert transformers_factory.calls[0][0] == "granite_vision_v4"
    assert "engine_options" not in transformers_factory.calls[0][1]

    api, api_factory = _apply("devbox", "vllm")
    preset, kwargs = api_factory.calls[0]
    assert preset == "granite_vision_v4"
    assert kwargs["engine_options"].kwargs["url"] == "http://127.0.0.1:8000/v1/chat/completions"
    assert kwargs["engine_options"].kwargs["params"]["model"] == "ibm-granite/granite-vision-4.1-4b"
    assert api.chart_extraction_options["preset"] == "granite_vision_v4"

    assert chart_extraction_plan(host="mac")["engine"] == "mlx"
    assert chart_extraction_plan(host="devbox", vlm_engine="vllm")["engine"] == "api"
    assert chart_extraction_plan(host="devbox")["engine"] == "transformers"


def test_chart_preset_is_left_alone_when_extraction_is_off():
    options, factory = _apply("mac", enabled=False)
    assert factory.calls == []
    assert options.chart_extraction_options is None
