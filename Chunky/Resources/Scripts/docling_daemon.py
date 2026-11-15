#!/usr/bin/env python3
import json
import os
import re
import sys
import traceback

LOG_DIR = os.path.expanduser("~/Library/Logs/Chunky")
os.makedirs(LOG_DIR, exist_ok=True)

import logging
logging.basicConfig(
    filename=os.path.join(LOG_DIR, "docling_daemon.log"),
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

LOCAL_VLM_MODELS = {
    "smoldocling-mlx": "SMOLDOCLING_MLX",
    "smoldocling-transformers": "SMOLDOCLING_TRANSFORMERS",
    "granite-docling-mlx": "GRANITEDOCLING_MLX",
    "granite-docling-transformers": "GRANITEDOCLING_TRANSFORMERS",
}

_converter_cache = {}


def _setup_env(vlm_model, accelerator):
    if vlm_model in LOCAL_VLM_MODELS:
        return
    if accelerator == "cpu":
        os.environ["PYTORCH_MPS_DISABLE"] = "1"
        os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"
        os.environ["CUDA_VISIBLE_DEVICES"] = ""
        os.environ["PYTORCH_NO_CUDA_MEMORY_CACHING"] = "1"
        os.environ["DOCLING_DEVICE"] = "cpu"
        os.environ["DEVICE"] = "cpu"
        os.environ["ACCELERATOR"] = "cpu"


def _progress(message, percent=None):
    payload = {"type": "progress", "message": message}
    if percent is not None:
        payload["percent"] = percent
    print(json.dumps(payload), file=sys.stderr, flush=True)


def _get_converter(cmd):
    from docling_convert import (
        _build_standard_format_options,
        _build_vlm_format_options,
        _non_pdf_format_options,
    )
    from docling.document_converter import DocumentConverter

    vlm_model = cmd.get("vlm_model")
    use_vlm = vlm_model is not None

    cache_key = (
        vlm_model or "standard",
        cmd.get("accelerator", "cpu"),
        cmd.get("enable_ocr", False),
        cmd.get("table_mode", "fast"),
        cmd.get("no_tables", False),
        cmd.get("layout_model", "default"),
        cmd.get("workers", 2),
        cmd.get("do_formula_enrichment", False),
        cmd.get("do_code_enrichment", False),
        cmd.get("do_chart_extraction", False),
        cmd.get("do_picture_description", False),
        cmd.get("do_picture_classification", False),
        cmd.get("generate_images", False),
    )

    if cache_key in _converter_cache:
        return _converter_cache[cache_key]

    if use_vlm:
        format_options = _build_vlm_format_options(
            vlm_model,
            cmd.get("ollama_url", "http://localhost:11434"),
            do_formula_enrichment=cmd.get("do_formula_enrichment", False),
            do_code_enrichment=cmd.get("do_code_enrichment", False),
            do_chart_extraction=cmd.get("do_chart_extraction", False),
            do_picture_description=cmd.get("do_picture_description", False),
            do_picture_classification=cmd.get("do_picture_classification", False),
            generate_images=cmd.get("generate_images", False),
        )
    else:
        format_options = _build_standard_format_options(
            accelerator=cmd.get("accelerator", "cpu"),
            enable_ocr=cmd.get("enable_ocr", False),
            ocr_language=cmd.get("ocr_language"),
            table_mode=cmd.get("table_mode", "fast"),
            no_tables=cmd.get("no_tables", False),
            generate_images=cmd.get("generate_images", False),
            do_formula_enrichment=cmd.get("do_formula_enrichment", False),
            do_code_enrichment=cmd.get("do_code_enrichment", False),
            do_chart_extraction=cmd.get("do_chart_extraction", False),
            do_picture_description=cmd.get("do_picture_description", False),
            do_picture_classification=cmd.get("do_picture_classification", False),
            layout_model=cmd.get("layout_model", "default"),
            workers=cmd.get("workers", 2),
        )

    input_format = cmd.get("input_format")
    if input_format:
        from docling.datamodel.base_models import InputFormat as IF
        format_map = {f.value: f for f in IF}
        if input_format in format_map:
            requested = format_map[input_format]
            if requested in format_options:
                format_options = {requested: format_options[requested]}

    converter = DocumentConverter(format_options=format_options)
    _converter_cache[cache_key] = converter
    return converter


def _handle_convert(cmd):
    from docling_convert import _write_output, _chunk_document
    from pathlib import Path

    input_path = cmd["input"]
    input_file = Path(input_path)
    if not input_file.exists():
        return {"success": False, "error": f"Input file not found: {input_path}", "error_type": "file_not_found"}

    output_dir = cmd.get("output_dir")
    output_format = cmd.get("format", "json")

    if output_dir:
        out_dir = Path(output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
    else:
        out_dir = input_file.parent

    output_file = out_dir / f"{input_file.stem}.{output_format}"

    _progress("Initializing converter...", 0)

    converter = _get_converter(cmd)

    _progress("Converting document...", 10)

    max_pages = cmd.get("max_pages")
    if max_pages:
        result = converter.convert(input_path, max_num_pages=max_pages)
    else:
        result = converter.convert(input_path)

    _progress("Processing conversion result...", 80)

    from docling.datamodel.base_models import ConversionStatus
    if result.status == ConversionStatus.FAILURE:
        errors = [str(e) for e in result.errors] if result.errors else ["Unknown error"]
        return {"success": False, "error": "; ".join(errors), "error_type": "conversion_error"}

    doc = result.document

    image_export_mode = cmd.get("image_export_mode", "embedded")
    ok, err = _write_output(doc, output_format, output_file, image_export_mode)
    if not ok:
        return {"success": False, "error": err, "error_type": "invalid_format"}

    result_data = {
        "success": True,
        "input_file": str(input_file.absolute()),
        "output_file": str(output_file.absolute()),
        "output_format": output_format,
        "page_count": len(doc.pages),
    }

    if output_format == "json":
        result_data["text_items_count"] = len(list(doc.texts))
    result_data["table_count"] = len(list(doc.tables))

    desc = doc.description if hasattr(doc, "description") else None
    origin = doc.origin if hasattr(doc, "origin") else None
    result_data["doc_title"] = getattr(desc, "title", None) if desc else getattr(doc, "name", None)
    result_data["authors"] = getattr(desc, "authors", None) if desc else None
    result_data["doi"] = getattr(desc, "doi", None) if desc else None
    result_data["doc_url"] = (
        getattr(desc, "url", None) if desc
        else (getattr(origin, "uri", None) if origin else None)
    )

    year = None
    desc_date = getattr(desc, "date", None) if desc else None
    if desc_date:
        m = re.search(r'(?<!\d)((?:19|20)\d{2})(?!\d)', str(desc_date))
        if m:
            year = int(m.group())
    if year is None:
        fname = getattr(origin, "filename", "") if origin else str(input_file.name)
        m = re.search(r'(?<!\d)((?:19|20)\d{2})(?!\d)', fname)
        if m:
            year = int(m.group(1))
    result_data["year"] = year

    lang = None
    try:
        from langdetect import detect
        sample = ""
        for item in doc.texts:
            if hasattr(item, "text") and item.text:
                sample += item.text + " "
                if len(sample) > 1000:
                    break
        if sample.strip():
            lang = detect(sample)
    except Exception:
        pass
    result_data["language"] = lang

    if cmd.get("chunk", False):
        chunk_result = _chunk_document(
            doc,
            cmd.get("chunk_tokenizer", ""),
            cmd.get("chunk_max_tokens", 512),
            cmd.get("chunk_merge_peers", True),
            _progress,
        )
        if chunk_result is not None:
            result_data["chunks"] = chunk_result

    extract_schema = cmd.get("extract_schema")
    if extract_schema:
        _progress("Running structured extraction...", 85)
        try:
            import tempfile
            from docling.document_extractor import DocumentExtractor
            schema_path = Path(extract_schema)
            if schema_path.exists():
                template = json.loads(schema_path.read_text(encoding="utf-8"))
                extractor = DocumentExtractor()
                extract_result = extractor.extract(source=input_path, template=template)
                extraction_data = []
                for page in extract_result.pages:
                    extraction_data.append({
                        "page_no": page.page_no,
                        "extracted_data": page.extracted_data,
                    })
                extraction_file = out_dir / f"{input_file.stem}.extraction.json"
                import tempfile
                fd, tmp_path = tempfile.mkstemp(dir=out_dir, suffix=".tmp")
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as f:
                        json.dump(extraction_data, f, indent=2, ensure_ascii=False)
                    os.replace(tmp_path, extraction_file)
                except BaseException:
                    try:
                        os.unlink(tmp_path)
                    except OSError:
                        pass
                    raise
                result_data["extraction_output"] = str(extraction_file.absolute())
                result_data["extraction_count"] = len(extraction_data)
        except ImportError:
            pass

    _progress("Conversion complete", 100)
    return result_data


def _redirect_stdout():
    real_stdout = os.dup(1)
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, 1)
    os.close(devnull)
    return real_stdout


def _restore_stdout(real_stdout_fd):
    os.dup2(real_stdout_fd, 1)
    os.close(real_stdout_fd)


def _send(real_stdout_fd, obj):
    data = json.dumps(obj, ensure_ascii=False) + "\n"
    os.write(real_stdout_fd, data.encode("utf-8"))


def main():
    os.environ.setdefault("OMP_NUM_THREADS", "4")

    real_stdout_fd = _redirect_stdout()

    log.info("Daemon starting, preloading docling...")
    _progress("Daemon starting...", 0)

    try:
        import docling  # noqa: F401
        from docling.document_converter import DocumentConverter  # noqa: F401
        log.info("Docling preloaded successfully")
    except ImportError as e:
        log.error("Failed to preload docling: %s", e)

    _send(real_stdout_fd, {"type": "ready"})
    log.info("Daemon ready, waiting for commands")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except json.JSONDecodeError as e:
            log.error("Invalid JSON: %s", e)
            _send(real_stdout_fd, {"success": False, "error": f"Invalid JSON: {e}"})
            continue

        command = cmd.get("command", "convert")

        if command == "shutdown":
            log.info("Shutdown requested")
            _send(real_stdout_fd, {"type": "shutdown", "success": True})
            break

        if command == "ping":
            _send(real_stdout_fd, {"type": "pong", "success": True})
            continue

        if command == "convert":
            try:
                vlm_model = cmd.get("vlm_model")
                accelerator = cmd.get("accelerator", "cpu")
                _setup_env(vlm_model, accelerator)

                result = _handle_convert(cmd)
                _send(real_stdout_fd, result)
            except Exception as e:
                log.error("Convert failed: %s\n%s", e, traceback.format_exc())
                _send(real_stdout_fd, {
                    "success": False,
                    "error": str(e),
                    "error_type": "exception",
                    "traceback": traceback.format_exc(),
                })
        else:
            _send(real_stdout_fd, {"success": False, "error": f"Unknown command: {command}"})

    _restore_stdout(real_stdout_fd)
    log.info("Daemon exiting")


if __name__ == "__main__":
    main()
