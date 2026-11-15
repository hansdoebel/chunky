"""Enrichment flags shared by the standard PDF pipeline and the VLM pipeline."""

from __future__ import annotations

ENRICHMENT_FLAGS = (
    "do_picture_description",
    "do_picture_classification",
    "do_chart_extraction",
    "do_formula_enrichment",
    "do_code_enrichment",
)

PICTURE_ENRICHMENT_FLAGS = (
    "do_picture_description",
    "do_picture_classification",
    "do_chart_extraction",
)

def enrichment_values(
    *,
    generate_images: bool = False,
    do_picture_description: bool = False,
    do_picture_classification: bool = False,
    do_chart_extraction: bool = False,
    do_formula_enrichment: bool = False,
    do_code_enrichment: bool = False,
) -> dict:
    flags = {
        "do_picture_description": bool(do_picture_description),
        "do_picture_classification": bool(do_picture_classification),
        "do_chart_extraction": bool(do_chart_extraction),
        "do_formula_enrichment": bool(do_formula_enrichment),
        "do_code_enrichment": bool(do_code_enrichment),
    }
    picture = any(flags[name] for name in PICTURE_ENRICHMENT_FLAGS)
    flags["generate_picture_images"] = picture or bool(generate_images)
    if picture:
        flags["images_scale"] = 2.0
    return flags

def _accepts(options, key: str) -> bool:
    fields = getattr(options, "model_fields", None)
    if isinstance(fields, dict):
        return key in fields
    return hasattr(options, key)

def apply_enrichment(options, **flags):
    """Copy enrichment flags onto a pipeline options object.

    Picture description, classification, or chart extraction also turns on
    picture images at scale 2. Fields the options model does not declare are
    left alone, so formula and code flags stay on the standard pipeline when
    the VLM options model has no such fields.
    """
    for key, value in enrichment_values(**flags).items():
        if _accepts(options, key):
            setattr(options, key, value)
    return options
