import time

from chunky_worker.metrics import JobMetrics, MetricsRecorder
from chunky_worker.models import JobSettings


def test_metrics_round_trip_and_skipped_stages():
    settings = JobSettings(enable_ocr=False, do_picture_description=False, vlm_model=None, chunk=True)
    clock = {"now": 0.0}

    def tick():
        return clock["now"]

    recorder = MetricsRecorder(settings, host="devbox", resources=lambda: {
        "gpu_name": "Radeon",
        "vram_used_mb": 100,
        "vram_total_mb": 32000,
        "utilization": [10.0],
    }, clock=tick)
    clock["now"] = 0.05
    recorder.apply_pipeline(
        {"success": True, "page_count": 2, "chunks": [{}, {}], "stage_ms": {"convert_layout": 12, "chunking": 4}, "runtime": "docling"},
        20,
    )

    def embed():
        clock["now"] = 0.08
        return [[0.1], [0.2]]

    vectors = recorder.time("embedding", "ollama", embed, chunks=2)
    assert len(vectors) == 2
    clock["now"] = 0.1
    metrics = recorder.finish(pages=2, chunks=2, embeddings=2)
    payload = metrics.model_dump(mode="json")
    restored = JobMetrics.model_validate(payload)
    by_name = {stage.name: stage for stage in restored.stages}
    assert by_name["ocr"].status == "skipped"
    assert by_name["picture_description"].status == "skipped"
    assert by_name["vlm_convert"].status == "skipped"
    assert by_name["convert_layout"].duration_ms == 12
    assert by_name["embedding"].status == "ok"
    assert by_name["embedding"].chunks == 2
    assert restored.resources.gpu_name == "Radeon"
    kinds = [(event["stage"], event["phase"]) for event in recorder.events]
    assert ("convert_layout", "start") in kinds
    assert ("convert_layout", "end") in kinds
    assert ("embedding", "end") in kinds
    assert restored.wall_ms == 100
    time.sleep(0)
