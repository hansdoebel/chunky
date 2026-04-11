#!/usr/bin/env python3
"""
Docling document conversion wrapper for Chunky macOS app.
Converts documents to JSON with structured content for chunking.

Usage:
    python docling_convert.py <input_path> [options]

Options:
    --output-dir PATH       Output directory (default: same as input)
    --format FORMAT         Output format: json, markdown, markdown_no_images,
                            markdown_with_images, text, doctags, html (default: json)
    --max-pages N           Maximum pages to process (default: unlimited)
    --ocr                   Enable OCR for scanned documents
    --table-mode MODE       Table extraction mode: fast, accurate (default: fast)
    --progress              Print progress updates as JSON to stderr
    --accelerator MODE      Hardware accelerator: auto, cpu, mps, cuda (default: cpu)
"""

import logging
import os
import re
import sys
import traceback

LOG_DIR = os.path.expanduser("~/Library/Logs/Chunky")
os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    filename=os.path.join(LOG_DIR, "docling_convert.log"),
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


def _setup_cpu_mode():
    # Skip CPU enforcement when a local VLM model is specified,
    # since those models manage their own device selection.
    vlm_model = None
    accelerator = "cpu"
    for i, arg in enumerate(sys.argv):
        if arg == "--vlm-model" and i + 1 < len(sys.argv):
            vlm_model = sys.argv[i + 1]
        elif arg in ("--accelerator", "-a") and i + 1 < len(sys.argv):
            accelerator = sys.argv[i + 1]

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


_setup_cpu_mode()

import argparse  # noqa: E402
import json  # noqa: E402
import tempfile  # noqa: E402
from pathlib import Path  # noqa: E402
from typing import NotRequired, TypedDict  # noqa: E402


class ConversionResult(TypedDict):
    success: bool
    error: NotRequired[str]
    error_type: NotRequired[str]
    traceback: NotRequired[str]
    input_file: NotRequired[str]
    output_file: NotRequired[str]
    output_format: NotRequired[str]
    page_count: NotRequired[int]
    text_items_count: NotRequired[int]
    table_count: NotRequired[int]
    extraction_output: NotRequired[str]
    extraction_count: NotRequired[int]


def _non_pdf_format_options():
    from docling.backend.asciidoc_backend import AsciiDocBackend
    from docling.backend.csv_backend import CsvDocumentBackend
    from docling.backend.html_backend import HTMLDocumentBackend
    from docling.backend.image_backend import ImageDocumentBackend
    from docling.backend.md_backend import MarkdownDocumentBackend
    from docling.backend.msexcel_backend import MsExcelDocumentBackend
    from docling.backend.mspowerpoint_backend import MsPowerpointDocumentBackend
    from docling.backend.msword_backend import MsWordDocumentBackend
    from docling.backend.xml.jats_backend import JatsDocumentBackend
    from docling.backend.xml.uspto_backend import PatentUsptoDocumentBackend
    from docling.backend.xml.xbrl_backend import XBRLDocumentBackend
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import FormatOption
    from docling.pipeline.simple_pipeline import SimplePipeline
    from docling.pipeline.standard_pdf_pipeline import StandardPdfPipeline

    return {
        InputFormat.DOCX: FormatOption(backend=MsWordDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.PPTX: FormatOption(backend=MsPowerpointDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.XLSX: FormatOption(backend=MsExcelDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.HTML: FormatOption(backend=HTMLDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.IMAGE: FormatOption(backend=ImageDocumentBackend, pipeline_cls=StandardPdfPipeline),
        InputFormat.MD: FormatOption(backend=MarkdownDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.ASCIIDOC: FormatOption(backend=AsciiDocBackend, pipeline_cls=SimplePipeline),
        InputFormat.CSV: FormatOption(backend=CsvDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.XML_USPTO: FormatOption(backend=PatentUsptoDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.XML_JATS: FormatOption(backend=JatsDocumentBackend, pipeline_cls=SimplePipeline),
        InputFormat.XML_XBRL: FormatOption(backend=XBRLDocumentBackend, pipeline_cls=SimplePipeline),
    }


def _build_vlm_format_options(vlm_model, ollama_url):
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import VlmPipelineOptions
    from docling.document_converter import FormatOption, PdfFormatOption
    from docling.pipeline.vlm_pipeline import VlmPipeline

    is_local_vlm = vlm_model in LOCAL_VLM_MODELS
    if is_local_vlm:
        from docling.datamodel.vlm_model_specs import (
            GRANITEDOCLING_MLX,
            GRANITEDOCLING_TRANSFORMERS,
            SMOLDOCLING_MLX,
            SMOLDOCLING_TRANSFORMERS,
        )

        local_vlm_specs = {
            "smoldocling-mlx": SMOLDOCLING_MLX,
            "smoldocling-transformers": SMOLDOCLING_TRANSFORMERS,
            "granite-docling-mlx": GRANITEDOCLING_MLX,
            "granite-docling-transformers": GRANITEDOCLING_TRANSFORMERS,
        }
        pipeline_options = VlmPipelineOptions(
            vlm_options=local_vlm_specs[vlm_model],
        )
    else:
        from docling.datamodel.pipeline_options_vlm_model import (
            ApiVlmOptions,
            ResponseFormat,
        )
        from pydantic import AnyUrl

        vlm_options = ApiVlmOptions(
            url=AnyUrl(f"{ollama_url}/v1/chat/completions"),
            params=dict(model=vlm_model),
            prompt="OCR the full page to markdown.",
            timeout=120,
            scale=1.0,
            response_format=ResponseFormat.MARKDOWN,
        )
        pipeline_options = VlmPipelineOptions(
            enable_remote_services=True,
            vlm_options=vlm_options,
        )

    format_options: dict[InputFormat, FormatOption] = {
        InputFormat.PDF: PdfFormatOption(
            pipeline_cls=VlmPipeline,
            pipeline_options=pipeline_options,
        ),
        **_non_pdf_format_options(),
    }
    return format_options


def _build_standard_format_options(
    accelerator,
    enable_ocr,
    ocr_language,
    table_mode,
    no_tables,
    generate_images,
    do_formula_enrichment,
    do_code_enrichment,
    do_chart_extraction,
    do_picture_description,
    do_picture_classification,
    layout_model="default",
    workers=2,
):
    from docling.datamodel.accelerator_options import AcceleratorOptions
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import (
        PdfPipelineOptions,
        TableFormerMode,
        TableStructureOptions,
    )
    from docling.document_converter import FormatOption, PdfFormatOption

    accel_options = AcceleratorOptions(
        device=accelerator,
        num_threads=workers,
    )

    pipeline_options = PdfPipelineOptions(
        accelerator_options=accel_options,
        generate_picture_images=generate_images,
    )
    pipeline_options.do_ocr = enable_ocr

    if enable_ocr and ocr_language:
        pipeline_options.ocr_options.lang = [ocr_language]

    pipeline_options.do_formula_enrichment = do_formula_enrichment
    pipeline_options.do_code_enrichment = do_code_enrichment
    pipeline_options.do_picture_classification = do_picture_classification
    pipeline_options.do_picture_description = do_picture_description

    if layout_model != "default":
        from docling.datamodel.pipeline_options import LayoutObjectDetectionOptions

        layout_opts = LayoutObjectDetectionOptions()
        if layout_model in ("egret-medium", "egret-large", "egret-xlarge"):
            from docling.datamodel import stage_model_specs

            egret_map = {
                "egret-medium": stage_model_specs.OBJECT_DETECTION_LAYOUT_EGRET_MEDIUM,
                "egret-large": stage_model_specs.OBJECT_DETECTION_LAYOUT_EGRET_LARGE,
                "egret-xlarge": stage_model_specs.OBJECT_DETECTION_LAYOUT_EGRET_XLARGE,
            }
            preset = egret_map[layout_model]
            layout_opts.model_spec = preset.model_spec.model_copy(deep=True)
        pipeline_options.layout_options = layout_opts

    if do_chart_extraction:
        pipeline_options.generate_picture_images = True

    if no_tables:
        pipeline_options.do_table_structure = False
    elif table_mode == "accurate":
        pipeline_options.do_table_structure = True
        pipeline_options.table_structure_options = TableStructureOptions(
            mode=TableFormerMode.ACCURATE
        )
    else:
        pipeline_options.do_table_structure = True
        pipeline_options.table_structure_options = TableStructureOptions(
            mode=TableFormerMode.FAST
        )

    format_options: dict[InputFormat, FormatOption] = {
        InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options),
        **_non_pdf_format_options(),
    }
    return format_options


def _write_output(doc, output_format, output_file, image_export_mode):
    """Export the converted document to a file atomically.

    Writes to a temporary file first, then renames to the target path
    to avoid leaving corrupt files on crash.
    """
    import re

    out_dir = output_file.parent

    def _get_content():
        if output_format == "json":
            return json.dumps(
                doc.export_to_dict(), indent=2, ensure_ascii=False
            )
        elif output_format == "markdown":
            return doc.export_to_markdown()
        elif output_format == "markdown_no_images":
            content = doc.export_to_markdown()
            content = re.sub(r"\n*<!-- image -->\n*", "\n\n", content)
            content = re.sub(r"\n{3,}", "\n\n", content)
            return content.strip() + "\n"
        elif output_format == "markdown_with_images":
            from docling_core.types.doc.base import ImageRefMode

            mode_map = {
                "embedded": ImageRefMode.EMBEDDED,
                "placeholder": ImageRefMode.PLACEHOLDER,
                "referenced": ImageRefMode.REFERENCED,
            }
            img_mode = mode_map.get(image_export_mode, ImageRefMode.EMBEDDED)
            return doc.export_to_markdown(image_mode=img_mode)
        elif output_format == "text":
            return doc.export_to_text()
        elif output_format == "doctags":
            return doc.export_to_doctags()
        elif output_format == "html":
            return doc.export_to_html()
        else:
            return None

    content = _get_content()
    if content is None:
        return False, f"Unsupported output format: {output_format}"

    fd, tmp_path = tempfile.mkstemp(dir=out_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, output_file)
    except BaseException:
        # Clean up temp file on any failure
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return True, None


def _chunk_document(doc, chunk_tokenizer, chunk_max_tokens, chunk_merge_peers, progress_callback):
    try:
        from docling_core.transforms.chunker.hybrid_chunker import HybridChunker
    except ImportError:
        log.warning("docling-core[chunking] not installed, skipping chunking")
        return None

    progress_callback("Chunking document...", 88)

    chunker_kwargs = {
        "max_tokens": chunk_max_tokens,
        "merge_peers": chunk_merge_peers,
        "repeat_table_header": True,
    }

    if chunk_tokenizer:
        try:
            chunker = HybridChunker(tokenizer=chunk_tokenizer, **chunker_kwargs)
        except Exception as e:
            log.warning("Failed to load tokenizer '%s': %s, using default", chunk_tokenizer, e)
            chunker = HybridChunker(**chunker_kwargs)
    else:
        chunker = HybridChunker(**chunker_kwargs)

    chunk_list = []
    for i, chunk in enumerate(chunker.chunk(doc)):
        contextualized = chunker.serialize(chunk)

        page = None
        content_type = "text"
        if chunk.meta and chunk.meta.doc_items:
            first_item = chunk.meta.doc_items[0]
            if hasattr(first_item, "prov") and first_item.prov:
                prov = first_item.prov[0] if isinstance(first_item.prov, list) else first_item.prov
                if hasattr(prov, "page_no"):
                    page = prov.page_no
            if hasattr(first_item, "label") and first_item.label:
                content_type = str(first_item.label)

        headings = []
        if chunk.meta and chunk.meta.headings:
            headings = [str(h) for h in chunk.meta.headings]

        token_count = chunker.tokenizer.count_tokens(chunk.text)

        chunk_list.append({
            "text": chunk.text,
            "embedding_text": contextualized,
            "page": page,
            "headings": headings,
            "content_type": content_type,
            "chunk_index": i,
            "token_count": token_count,
        })

    progress_callback(f"Chunked into {len(chunk_list)} chunks", 92)
    return chunk_list


def convert_document(
    input_path: str,
    output_dir: str | None = None,
    output_format: str = "json",
    max_pages: int | None = None,
    enable_ocr: bool = False,
    ocr_language: str | None = None,
    table_mode: str = "fast",
    no_tables: bool = False,
    report_progress: bool = False,
    accelerator: str = "cpu",
    vlm_model: str | None = None,
    ollama_url: str = "http://localhost:11434",
    generate_images: bool = False,
    image_export_mode: str = "embedded",
    do_formula_enrichment: bool = False,
    do_code_enrichment: bool = False,
    do_chart_extraction: bool = False,
    do_picture_description: bool = False,
    do_picture_classification: bool = False,
    input_format: str | None = None,
    extract_schema: str | None = None,
    layout_model: str = "default",
    workers: int = 2,
    chunk: bool = False,
    chunk_max_tokens: int = 512,
    chunk_merge_peers: bool = True,
    chunk_tokenizer: str = "",
) -> ConversionResult:
    try:
        from docling.document_converter import DocumentConverter
    except ImportError as e:
        return {
            "success": False,
            "error": f"Docling not installed. Run: pip install docling\n{e}",
            "error_type": "import_error",
        }

    log.info("convert_document called: input=%s format=%s vlm=%s accelerator=%s workers=%d",
             input_path, output_format, vlm_model, accelerator, workers)

    input_file = Path(input_path)
    if not input_file.exists():
        log.error("Input file not found: %s", input_path)
        return {
            "success": False,
            "error": f"Input file not found: {input_path}",
            "error_type": "file_not_found",
        }

    if output_dir:
        out_dir = Path(output_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
    else:
        out_dir = input_file.parent

    output_file = out_dir / f"{input_file.stem}.{output_format}"

    def progress_callback(message: str, percent: float | None = None):
        if report_progress:
            progress: dict[str, str | float] = {"type": "progress", "message": message}
            if percent is not None:
                progress["percent"] = percent
            print(json.dumps(progress), file=sys.stderr)

    try:
        progress_callback("Initializing docling converter...", 0)

        use_vlm = vlm_model is not None
        if use_vlm:
            format_options = _build_vlm_format_options(vlm_model, ollama_url)
        else:
            format_options = _build_standard_format_options(
                accelerator=accelerator,
                enable_ocr=enable_ocr,
                ocr_language=ocr_language,
                table_mode=table_mode,
                no_tables=no_tables,
                generate_images=generate_images,
                do_formula_enrichment=do_formula_enrichment,
                do_code_enrichment=do_code_enrichment,
                do_chart_extraction=do_chart_extraction,
                do_picture_description=do_picture_description,
                do_picture_classification=do_picture_classification,
                layout_model=layout_model,
                workers=workers,
            )

        if input_format:
            from docling.datamodel.base_models import InputFormat as IF

            format_map = {f.value: f for f in IF}
            if input_format in format_map:
                requested = format_map[input_format]
                if requested in format_options:
                    format_options = {requested: format_options[requested]}

        converter = DocumentConverter(format_options=format_options)

        progress_callback("Converting document...", 10)

        if max_pages:
            result = converter.convert(input_path, max_num_pages=max_pages)
        else:
            result = converter.convert(input_path)

        progress_callback("Processing conversion result...", 80)

        from docling.datamodel.base_models import ConversionStatus

        if result.status == ConversionStatus.FAILURE:
            errors = (
                [str(e) for e in result.errors] if result.errors else ["Unknown error"]
            )
            return {
                "success": False,
                "error": "; ".join(errors),
                "error_type": "conversion_error",
            }

        doc = result.document

        ok, err = _write_output(doc, output_format, output_file, image_export_mode)
        if not ok:
            assert err is not None
            return {
                "success": False,
                "error": err,
                "error_type": "invalid_format",
            }

        result_data: ConversionResult = {
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
        result_data["doc_title"] = getattr(desc, "title", None) if desc else (getattr(doc, "name", None))
        result_data["authors"] = getattr(desc, "authors", None) if desc else None
        result_data["doi"] = getattr(desc, "doi", None) if desc else None
        result_data["doc_url"] = getattr(desc, "url", None) if desc else (getattr(origin, "uri", None) if origin else None)

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

        if chunk:
            chunk_result = _chunk_document(
                doc, chunk_tokenizer, chunk_max_tokens, chunk_merge_peers, progress_callback
            )
            if chunk_result is not None:
                result_data["chunks"] = chunk_result

        if extract_schema:
            progress_callback("Running structured extraction...", 85)
            try:
                from docling.document_extractor import DocumentExtractor

                schema_path = Path(extract_schema)
                if schema_path.exists():
                    template = json.loads(schema_path.read_text(encoding="utf-8"))
                    extractor = DocumentExtractor()
                    extract_result = extractor.extract(
                        source=input_path, template=template
                    )
                    extraction_data = []
                    for page in extract_result.pages:
                        extraction_data.append({
                            "page_no": page.page_no,
                            "extracted_data": page.extracted_data,
                        })
                    extraction_file = out_dir / f"{input_file.stem}.extraction.json"
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

        progress_callback("Conversion complete", 100)
        log.info("Conversion succeeded: output=%s pages=%d", result_data.get("output_file"), result_data.get("page_count", 0))

        return result_data

    except Exception as e:
        log.error("Conversion failed: %s\n%s", e, traceback.format_exc())
        return {
            "success": False,
            "error": str(e),
            "error_type": "exception",
            "traceback": traceback.format_exc(),
        }


def main():
    parser = argparse.ArgumentParser(description="Convert documents using docling")
    parser.add_argument("input", help="Input file path or URL")
    parser.add_argument("--output-dir", "-o", help="Output directory")
    parser.add_argument(
        "--format",
        "-f",
        choices=[
            "json",
            "markdown",
            "markdown_no_images",
            "markdown_with_images",
            "text",
            "doctags",
            "html",
        ],
        default="json",
        help="Output format (default: json)",
    )
    parser.add_argument("--max-pages", "-m", type=int, help="Maximum pages to process")
    parser.add_argument(
        "--ocr", action="store_true", help="Enable OCR for scanned documents"
    )
    parser.add_argument(
        "--table-mode",
        "-t",
        choices=["fast", "accurate"],
        default="fast",
        help="Table extraction mode (default: fast)",
    )
    parser.add_argument(
        "--no-tables",
        action="store_true",
        help="Disable table structure extraction entirely",
    )
    parser.add_argument(
        "--progress",
        "-p",
        action="store_true",
        help="Report progress to stderr as JSON",
    )
    parser.add_argument(
        "--accelerator",
        "-a",
        choices=["auto", "cpu", "mps", "cuda"],
        default="cpu",
        help="Hardware accelerator (default: cpu, recommended when running from GUI app)",
    )
    parser.add_argument(
        "--vlm-model",
        help="Ollama VLM model name for vision-language pipeline (e.g., moondream, llava, granite3.2-vision:2b)",
    )
    parser.add_argument(
        "--ollama-url",
        default="http://localhost:11434",
        help="Ollama server URL (default: http://localhost:11434)",
    )
    parser.add_argument(
        "--generate-images",
        action="store_true",
        help="Generate picture images for embedding in markdown output",
    )
    parser.add_argument(
        "--ocr-lang",
        help="OCR language code (e.g., en, de, fr)",
    )
    parser.add_argument(
        "--image-export-mode",
        choices=["embedded", "placeholder", "referenced"],
        default="embedded",
        help="Image export mode for markdown output (default: embedded)",
    )
    parser.add_argument(
        "--do-formula-enrichment",
        action="store_true",
        help="Enable formula enrichment",
    )
    parser.add_argument(
        "--do-code-enrichment",
        action="store_true",
        help="Enable code enrichment",
    )
    parser.add_argument(
        "--do-chart-extraction",
        action="store_true",
        help="Enable chart extraction",
    )
    parser.add_argument(
        "--do-picture-description",
        action="store_true",
        help="Enable picture description",
    )
    parser.add_argument(
        "--do-picture-classification",
        action="store_true",
        help="Enable picture classification",
    )
    parser.add_argument(
        "--layout-model",
        choices=["default", "heron", "egret-medium", "egret-large", "egret-xlarge"],
        default="default",
        help="Layout analysis model (default: docling standard, heron: faster)",
    )
    parser.add_argument(
        "--extract-schema",
        help="Path to JSON schema file for structured extraction",
    )
    parser.add_argument(
        "--chunk",
        action="store_true",
        help="Enable document chunking via HybridChunker",
    )
    parser.add_argument(
        "--chunk-max-tokens",
        type=int,
        default=512,
        help="Maximum tokens per chunk (default: 512)",
    )
    parser.add_argument(
        "--chunk-merge-peers",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Merge undersized adjacent chunks sharing headings (default: True)",
    )
    parser.add_argument(
        "--chunk-tokenizer",
        default="",
        help="HuggingFace tokenizer name for chunking (default: HybridChunker default)",
    )
    parser.add_argument(
        "--input-format",
        choices=[
            "pdf", "docx", "pptx", "xlsx", "html", "image",
            "md", "asciidoc", "csv", "xml_uspto", "xml_jats", "xml_xbrl",
        ],
        default=None,
        help="Force input format (default: auto-detect from extension)",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=2,
        help="Number of worker threads (default: 2)",
    )

    args = parser.parse_args()

    result = convert_document(
        input_path=args.input,
        output_dir=args.output_dir,
        output_format=args.format,
        max_pages=args.max_pages,
        enable_ocr=args.ocr,
        ocr_language=args.ocr_lang,
        table_mode=args.table_mode,
        no_tables=args.no_tables,
        report_progress=args.progress,
        accelerator=args.accelerator,
        vlm_model=args.vlm_model,
        ollama_url=args.ollama_url,
        generate_images=args.generate_images,
        image_export_mode=args.image_export_mode,
        do_formula_enrichment=args.do_formula_enrichment,
        do_code_enrichment=args.do_code_enrichment,
        do_chart_extraction=args.do_chart_extraction,
        do_picture_description=args.do_picture_description,
        do_picture_classification=args.do_picture_classification,
        input_format=args.input_format,
        extract_schema=args.extract_schema,
        layout_model=args.layout_model,
        workers=args.workers,
        chunk=args.chunk,
        chunk_max_tokens=args.chunk_max_tokens,
        chunk_merge_peers=args.chunk_merge_peers,
        chunk_tokenizer=args.chunk_tokenizer,
    )

    print(json.dumps(result, indent=2))

    sys.exit(0 if result.get("success") else 1)


if __name__ == "__main__":
    main()
