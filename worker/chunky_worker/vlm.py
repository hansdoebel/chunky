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

GRANITE_REPO_ID = "ibm-granite/granite-docling-258M"
GRANITE_PRESET = "granite_docling"

GRANITE_CONCURRENCY = 8
VLM_ENGINES = {"vllm", "transformers"}

def normalize_vlm_engine(value: str | None) -> str:
    """Worker-wide engine. ``vllm`` is the default; ``transformers`` is the fallback."""
    engine = (value or "vllm").strip().lower()
    if engine not in VLM_ENGINES:
        raise ValueError("CHUNKY_VLM_ENGINE must be 'vllm' or 'transformers'")
    return engine

def chat_completions_url(base: str) -> str:
    """OpenAI-compatible chat URL. Accepts a host root, ``/v1``, or the full path."""
    trimmed = base.strip().rstrip("/")
    if trimmed.endswith("/chat/completions"):
        return trimmed
    if trimmed.endswith("/v1"):
        return trimmed + "/chat/completions"
    return trimmed + "/v1/chat/completions"

def granite_engine_for(vlm_model: str | None, configured: str) -> str | None:
    """Return the granite engine for this job, or None when the job is not granite."""
    if model_for_worker(vlm_model) != "granite-docling-transformers":
        return None
    return normalize_vlm_engine(configured)

def granite_plan(engine: str, vllm_url: str, accelerator: str | None) -> dict:
    """Describe a granite-docling run. Does not import Docling, torch, or MLX.

    The vLLM path uses Docling's ``granite_docling`` preset, which carries the
    DocTags prompt. The Transformers path is the fallback and pins the device
    to CUDA (ROCm's HIP name) with Flash Attention 2 left off.
    """
    selected = normalize_vlm_engine(engine)
    device = "cpu" if (accelerator or "").strip().lower() == "cpu" else "cuda"
    common = {
        "preset": GRANITE_PRESET,
        "repo_id": GRANITE_REPO_ID,
        "device": device,
        "cuda_use_flash_attention2": False,
        "page_batch_size": GRANITE_CONCURRENCY,
    }
    if selected == "transformers":
        return {**common, "engine": "transformers"}
    return {
        **common,
        "engine": "vllm",
        "url": chat_completions_url(vllm_url),
        "concurrency": GRANITE_CONCURRENCY,
        "timeout": 90,
        "params": {
            "model": GRANITE_REPO_ID,
            "max_tokens": 4096,
            "temperature": 0.0,

            "skip_special_tokens": False,
        },
    }

def granite_engine_call(plan: dict) -> dict:
    """Arguments for ``VlmConvertOptions.from_preset`` and the pipeline wrapper."""
    accelerator = {
        "device": plan["device"],
        "cuda_use_flash_attention2": False,
    }
    if plan["engine"] == "transformers":
        return {
            "preset": plan["preset"],
            "engine": "transformers",
            "engine_cls": "TransformersVlmEngineOptions",
            "engine_kwargs": {},
            "enable_remote_services": False,
            "accelerator": accelerator,
        }
    return {
        "preset": plan["preset"],
        "engine": "vllm",
        "engine_cls": "ApiVlmEngineOptions",
        "engine_kwargs": {
            "url": plan["url"],
            "params": dict(plan["params"]),
            "concurrency": plan["concurrency"],
            "timeout": plan["timeout"],
        },
        "enable_remote_services": True,
        "accelerator": accelerator,
    }

def build_granite_pipeline_options(plan: dict, *, factories: dict | None = None):
    """Build ``VlmPipelineOptions`` for granite-docling.

    ``factories`` is for tests. The real classes are imported only when it is
    omitted, so unit tests never load Docling or MLX.
    """
    call = granite_engine_call(plan)
    if factories is None:
        factories = _docling_vlm_factories(plan.get("page_batch_size", GRANITE_CONCURRENCY))
    engine = factories[call["engine_cls"]](**call["engine_kwargs"])
    try:
        vlm_options = factories["VlmConvertOptions"].from_preset(
            call["preset"],
            engine_options=engine,
        )
    except Exception:
        if call["engine"] != "transformers":
            raise
        vlm_options = factories["GRANITEDOCLING_TRANSFORMERS"]
    return factories["VlmPipelineOptions"](
        enable_remote_services=call["enable_remote_services"],
        vlm_options=vlm_options,
        accelerator_options=factories["AcceleratorOptions"](**call["accelerator"]),
    )

def _docling_vlm_factories(page_batch_size: int) -> dict:
    from docling.datamodel.pipeline_options import VlmConvertOptions, VlmPipelineOptions
    from docling.datamodel.vlm_engine_options import ApiVlmEngineOptions, TransformersVlmEngineOptions
    from docling.datamodel.vlm_model_specs import GRANITEDOCLING_TRANSFORMERS

    try:
        from docling.datamodel.accelerator_options import AcceleratorOptions
    except ImportError:
        from docling.datamodel.pipeline_options import AcceleratorOptions

    _match_page_batch(page_batch_size)
    return {
        "VlmConvertOptions": VlmConvertOptions,
        "VlmPipelineOptions": VlmPipelineOptions,
        "ApiVlmEngineOptions": ApiVlmEngineOptions,
        "TransformersVlmEngineOptions": TransformersVlmEngineOptions,
        "AcceleratorOptions": AcceleratorOptions,
        "GRANITEDOCLING_TRANSFORMERS": GRANITEDOCLING_TRANSFORMERS,
    }

def _match_page_batch(concurrency: int) -> None:
    """Docling requires ``page_batch_size`` to be at least the API concurrency."""
    try:
        from docling.datamodel.settings import settings as docling_settings
    except ImportError:
        return
    perf = getattr(docling_settings, "perf", None)
    current = getattr(perf, "page_batch_size", None)
    if isinstance(current, int) and current < concurrency:
        perf.page_batch_size = concurrency

def gpu_probe() -> dict:
    """Report whether PyTorch sees a GPU. ROCm appears as ``torch.cuda``. Never imports MLX."""
    try:
        import torch
    except ImportError:
        return {"torch": False, "cuda": False, "device_name": None, "arch_list": [], "hip": None}
    cuda_mod = getattr(torch, "cuda", None)
    available = False
    if cuda_mod is not None:
        try:
            available = bool(cuda_mod.is_available())
        except Exception:
            available = False
    arch_list: list[str] = []
    device_name = None
    if available:
        try:
            arch_list = [str(item) for item in cuda_mod.get_arch_list()]
        except Exception:
            arch_list = []
        try:
            device_name = str(cuda_mod.get_device_name(0))
        except Exception:
            device_name = "cuda"
    hip = getattr(getattr(torch, "version", None), "hip", None)
    return {
        "torch": True,
        "cuda": available,
        "device_name": device_name,
        "arch_list": arch_list,
        "hip": hip,
    }
