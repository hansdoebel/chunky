"""Host rules for VLM ids. The worker never runs MLX."""

from __future__ import annotations

MLX_TO_TRANSFORMERS = {
    "granite-docling-mlx": "granite-docling-transformers",
    "smoldocling-mlx": "smoldocling-transformers",
}


class UnsupportedMLXModel(ValueError):
    """An MLX model id has no Linux equivalent."""


def model_for_worker(vlm_model: str | None) -> str | None:
    """Map an MLX model id to its Transformers counterpart.

    ``standard`` and empty values stay unset. Unknown ``*-mlx`` ids raise
    ``UnsupportedMLXModel`` instead of being forwarded to Docling.
    """
    if vlm_model is None:
        return None
    name = vlm_model.strip()
    if name == "" or name == "standard":
        return None
    if name in MLX_TO_TRANSFORMERS:
        return MLX_TO_TRANSFORMERS[name]
    if name.endswith("-mlx"):
        raise UnsupportedMLXModel(
            f"MLX model {name!r} cannot run on the worker (mlx-vlm is Apple-only). "
            "Choose the Transformers model or a vLLM endpoint."
        )
    return name


def accelerator_for_worker(accelerator: str | None) -> str:
    """ROCm is addressed as CUDA. MPS and an empty value become ``cuda``."""
    name = (accelerator or "").strip().lower()
    if name in {"", "mps", "auto"}:
        return "cuda"
    return name
