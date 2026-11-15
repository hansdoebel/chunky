import json

from chunky_worker.model_catalog import (
    DownloadManager,
    parse_hf_cache,
    parse_ollama_tags,
    parse_openai_models,
    parse_pull_event,
    recommended,
    vlm_report,
)

def test_ollama_tags_keep_digest_size_and_quantization():
    rows = parse_ollama_tags(
        {
            "models": [
                {
                    "name": "qwen3-embedding:latest",
                    "digest": "abc123",
                    "size": 4096,
                    "details": {"parameter_size": "0.6B", "quantization_level": "Q8_0"},
                }
            ]
        }
    )
    assert rows == [
        {
            "name": "qwen3-embedding:latest",
            "digest": "abc123",
            "size": 4096,
            "parameter_size": "0.6B",
            "quantization": "Q8_0",
        }
    ]

def test_hf_cache_and_server_models_mark_availability():
    cache = parse_hf_cache(
        [{"repo_id": "ibm-granite/granite-docling-258M", "revision": "rev1", "size": 100}]
    )
    report = {item["name"]: item for item in vlm_report(cache, server_models=["ds4sd/SmolDocling-256M-preview"])}
    granite = report["granite-docling-transformers"]
    assert granite["available"] is True
    assert granite["revision"] == "rev1"
    assert granite["size"] == 100
    assert report["smoldocling-transformers"]["available"] is True
    assert report["granite-docling-mlx"]["available"] is False
    assert recommended("devbox") == [
        "qwen3-embedding:0.6b",
        "ibm-granite/granite-docling-258M",
        "ibm-granite/granite-vision-3.3-2b",
    ]

def test_pull_event_decoder():
    event = parse_pull_event('{"status":"pulling","completed":50,"total":100}\n')
    assert event["percent"] == 50
    assert event["status"] == "pulling"
    assert parse_pull_event("   ") is None
    assert parse_openai_models({"data": [{"id": "Qwen/Qwen3-Embedding-0.6B"}]}) == [
        "Qwen/Qwen3-Embedding-0.6B"
    ]

def test_granite_engine_follows_the_worker_setting():
    report = {item["name"]: item for item in vlm_report([], granite_engine="vllm")}
    assert report["granite-docling-transformers"]["engine"] == "vllm"
    assert report["smoldocling-transformers"]["engine"] == "transformers"

def test_same_target_reuses_the_running_download_and_cancel_waits():
    import threading
    import time

    started = threading.Event()

    def fake_download(repo_id, revision, on_progress, cancel_event):
        started.set()
        while not cancel_event.is_set():
            time.sleep(0.01)
        on_progress(None, "stopping")

    manager = DownloadManager(fake_download)
    first = manager.start("ibm-granite/granite-docling-258M")
    assert started.wait(1)
    second = manager.start("ibm-granite/granite-docling-258M")
    assert second == first
    assert manager.cancel(first)["status"] == "canceling"
    for _ in range(50):
        if manager.get(first)["status"] == "canceled":
            break
        time.sleep(0.02)
    assert manager.get(first)["status"] == "canceled"

def test_download_manager_reports_progress_without_a_network_call():
    seen = {}

    def fake_download(repo_id, revision, on_progress, cancel_event):
        seen["repo"] = repo_id
        on_progress(40, "copying")
        assert not cancel_event.is_set()

    manager = DownloadManager(fake_download)
    job_id = manager.start("ibm-granite/granite-docling-258M")
    for _ in range(50):
        record = manager.get(job_id)
        if record and record["status"] == "succeeded":
            break
    else:
        raise AssertionError(manager.get(job_id))
    assert seen["repo"] == "ibm-granite/granite-docling-258M"
    assert record["percent"] == 100
    assert "cancel" not in json.dumps(record)
