"""Enrichment flags reach both the standard PDF options and the VLM options."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / "Chunky" / "Resources" / "Scripts"
sys.path.insert(0, str(SCRIPTS))

from enrichment import apply_enrichment  # noqa: E402

PDF_FIELDS = (
    "do_picture_description",
    "do_picture_classification",
    "do_chart_extraction",
    "do_formula_enrichment",
    "do_code_enrichment",
    "generate_picture_images",
    "images_scale",
)
VLM_FIELDS = (
    "do_picture_description",
    "do_picture_classification",
    "do_chart_extraction",
    "generate_picture_images",
    "images_scale",
)


class Options:
    def __init__(self, fields):
        self.model_fields = {name: None for name in fields}
        for name in fields:
            setattr(self, name, 1.0 if name == "images_scale" else False)


def test_picture_formula_and_code_flags_reach_both_pipelines():
    flags = dict(
        do_picture_description=True,
        do_picture_classification=True,
        do_chart_extraction=True,
        do_formula_enrichment=True,
        do_code_enrichment=True,
    )
    pdf = Options(PDF_FIELDS)
    vlm = Options(VLM_FIELDS)
    apply_enrichment(pdf, **flags)
    apply_enrichment(vlm, **flags)

    for options in (pdf, vlm):
        assert options.do_picture_description is True
        assert options.do_picture_classification is True
        assert options.do_chart_extraction is True
        assert options.generate_picture_images is True
        assert options.images_scale == 2.0

    assert pdf.do_formula_enrichment is True
    assert pdf.do_code_enrichment is True
    assert not hasattr(vlm, "do_formula_enrichment")
    assert not hasattr(vlm, "do_code_enrichment")


def test_any_picture_enrichment_turns_on_scaled_images():
    for flag in ("do_picture_description", "do_picture_classification", "do_chart_extraction"):
        pdf = Options(PDF_FIELDS)
        vlm = Options(VLM_FIELDS)
        apply_enrichment(pdf, **{flag: True})
        apply_enrichment(vlm, **{flag: True})
        for options in (pdf, vlm):
            assert getattr(options, flag) is True
            assert options.generate_picture_images is True
            assert options.images_scale == 2.0


def test_formula_and_code_do_not_force_picture_images():
    pdf = Options(PDF_FIELDS)
    vlm = Options(VLM_FIELDS)
    apply_enrichment(
        pdf,
        generate_images=True,
        do_formula_enrichment=True,
        do_code_enrichment=True,
    )
    apply_enrichment(vlm, do_formula_enrichment=True, do_code_enrichment=True)
    assert pdf.do_formula_enrichment is True
    assert pdf.do_code_enrichment is True
    assert pdf.generate_picture_images is True
    assert pdf.images_scale == 1.0
    assert vlm.generate_picture_images is False
    assert vlm.images_scale == 1.0
    assert vlm.do_picture_description is False


def test_daemon_forwards_enrichment_flags_to_the_vlm_builder(monkeypatch):
    import types

    converter_mod = types.ModuleType("docling.document_converter")

    class DocumentConverter:
        def __init__(self, format_options=None):
            self.format_options = format_options

    converter_mod.DocumentConverter = DocumentConverter
    monkeypatch.setitem(sys.modules, "docling", types.ModuleType("docling"))
    monkeypatch.setitem(sys.modules, "docling.document_converter", converter_mod)

    import docling_convert
    import docling_daemon

    seen = {}

    def fake_build(vlm_model, ollama_url, **kwargs):
        seen["model"] = vlm_model
        seen["url"] = ollama_url
        seen["kwargs"] = kwargs
        return {}

    monkeypatch.setattr(docling_convert, "_build_vlm_format_options", fake_build)
    docling_daemon._converter_cache.clear()
    docling_daemon._get_converter(
        {
            "vlm_model": "granite-docling-mlx",
            "ollama_url": "http://127.0.0.1:11434",
            "do_picture_description": True,
            "do_picture_classification": True,
            "do_chart_extraction": True,
            "do_formula_enrichment": True,
            "do_code_enrichment": True,
            "generate_images": True,
        }
    )
    assert seen["model"] == "granite-docling-mlx"
    assert seen["url"] == "http://127.0.0.1:11434"
    assert seen["kwargs"]["do_picture_description"] is True
    assert seen["kwargs"]["do_picture_classification"] is True
    assert seen["kwargs"]["do_chart_extraction"] is True
    assert seen["kwargs"]["do_formula_enrichment"] is True
    assert seen["kwargs"]["do_code_enrichment"] is True
    assert seen["kwargs"]["generate_images"] is True
