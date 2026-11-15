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

def test_disabled_chunking_is_skipped_and_stage_events_emit_immediately():
    settings = JobSettings(chunk=False)
    recorder = MetricsRecorder(settings, clock=lambda: 1.0)
    seen = []
    recorder.on_event = seen.append

    def embed():
        assert seen[-1] == {"type": "stage", "stage": "embedding", "phase": "start", "runtime": "ollama"}
        return [[1.0]]

    recorder.time("embedding", "ollama", embed)

    def boom():
        raise RuntimeError("nope")

    try:
        recorder.time("qdrant_upsert", "qdrant", boom)
    except RuntimeError:
        pass
    else:
        raise AssertionError("expected the stage function to raise")

    assert seen[-1]["phase"] == "end"
    assert seen[-1]["status"] == "error"
    finished = recorder.finish(pages=0, chunks=0, embeddings=0)
    by_name = {stage.name: stage for stage in finished.stages}
    assert by_name["chunking"].status == "skipped"
    assert by_name["qdrant_upsert"].status == "error"
