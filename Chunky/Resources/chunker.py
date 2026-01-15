#!/usr/bin/env python3
import argparse
import json
import os
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.base_models import InputFormat
from docling_core.transforms.chunker import HierarchicalChunker

VLM_MODELS = {
    "granite-docling": "GRANITEDOCLING_MLX",
    "smol-docling": "SMOLDOCLING_MLX",
    "qwen2.5-vl": "QWEN25_VL_3B_MLX",
    "pixtral": "PIXTRAL_12B_MLX",
}


def create_converter(args) -> DocumentConverter:
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.datamodel.accelerator_options import AcceleratorOptions
    from docling.datamodel.pipeline_options import TableStructureOptions, TableFormerMode

    accelerator_device = "auto"
    if args.accelerator != "auto":
        accelerator_device = args.accelerator

    table_mode = TableFormerMode.ACCURATE if args.table_mode == "accurate" else TableFormerMode.FAST

    pipeline_options = PdfPipelineOptions(
        do_table_structure=args.tables,
        do_ocr=args.ocr,
        accelerator_options=AcceleratorOptions(
            device=accelerator_device,
            num_threads=args.workers,
        ),
        table_structure_options=TableStructureOptions(mode=table_mode),
    )

    if args.model == "default" or args.model not in VLM_MODELS:
        return DocumentConverter(
            format_options={
                InputFormat.PDF: PdfFormatOption(
                    pipeline_options=pipeline_options,
                ),
            }
        )

    from docling.pipeline.vlm_pipeline import VlmPipeline
    from docling.datamodel.pipeline_options import VlmPipelineOptions
    from docling.datamodel import vlm_model_specs

    model_spec_name = VLM_MODELS[args.model]
    vlm_options = getattr(vlm_model_specs, model_spec_name, None)

    if vlm_options is None:
        print(f"Warning: Model spec {model_spec_name} not found, using default", file=sys.stderr)
        return DocumentConverter()

    vlm_pipeline_options = VlmPipelineOptions(vlm_options=vlm_options)

    return DocumentConverter(
        format_options={
            InputFormat.PDF: PdfFormatOption(
                pipeline_cls=VlmPipeline,
                pipeline_options=vlm_pipeline_options,
            ),
        }
    )


def export_document(doc, source_name: str, export_format: str, export_folder: str):
    if not export_folder or export_format == "none":
        return

    folder = Path(export_folder)
    folder.mkdir(parents=True, exist_ok=True)
    base_name = Path(source_name).stem

    if export_format in ("json", "both"):
        json_path = folder / f"{base_name}.json"
        with open(json_path, "w") as f:
            json.dump(doc.export_to_dict(), f, indent=2, default=str)
        print(f"Exported JSON to: {json_path}", file=sys.stderr)

    if export_format in ("markdown", "both"):
        md_path = folder / f"{base_name}.md"
        with open(md_path, "w") as f:
            f.write(doc.export_to_markdown())
        print(f"Exported Markdown to: {md_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Chunk PDF documents using Docling")
    parser.add_argument("--input", required=True, type=Path, help="Input PDF file path")
    parser.add_argument("--output", required=True, type=Path, help="Output JSON file path")

    parser.add_argument("--model", default="default",
                        choices=["default"] + list(VLM_MODELS.keys()),
                        help="Docling VLM model to use")
    parser.add_argument("--workers", type=int, default=4,
                        help="Number of worker threads")
    parser.add_argument("--accelerator", default="auto",
                        choices=["auto", "cpu", "mps"],
                        help="Accelerator device")
    parser.add_argument("--timeout", type=int, default=300,
                        help="Timeout in seconds per document")
    parser.add_argument("--max-pages", type=int, default=0,
                        help="Maximum pages to process (0 = unlimited)")
    parser.add_argument("--max-tokens", type=int, default=512,
                        help="Maximum tokens per chunk")

    parser.add_argument("--tables", action="store_true", default=True,
                        help="Enable table extraction")
    parser.add_argument("--no-tables", dest="tables", action="store_false",
                        help="Disable table extraction")
    parser.add_argument("--table-mode", default="accurate",
                        choices=["fast", "accurate"],
                        help="Table extraction mode")
    parser.add_argument("--ocr", action="store_true", default=False,
                        help="Enable OCR for scanned documents")

    parser.add_argument("--export-format", default="none",
                        choices=["none", "json", "markdown", "both"],
                        help="Export format for processed documents")
    parser.add_argument("--export-folder", type=str, default="",
                        help="Folder to save exported documents")

    args = parser.parse_args()

    if args.workers > 1:
        os.environ["OMP_NUM_THREADS"] = str(args.workers)

    if not args.input.exists():
        print(f"Error: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    print(f"Converting document: {args.input}", file=sys.stderr)
    print(f"  Model: {args.model}", file=sys.stderr)
    print(f"  Workers: {args.workers}", file=sys.stderr)
    print(f"  Accelerator: {args.accelerator}", file=sys.stderr)
    print(f"  Tables: {args.tables} ({args.table_mode})", file=sys.stderr)
    print(f"  OCR: {args.ocr}", file=sys.stderr)

    converter = create_converter(args)

    convert_kwargs = {}
    if args.max_pages > 0:
        convert_kwargs["max_num_pages"] = args.max_pages

    result = converter.convert(str(args.input), **convert_kwargs)
    doc = result.document

    if args.export_format != "none" and args.export_folder:
        export_document(doc, args.input.name, args.export_format, args.export_folder)

    print("Chunking document...", file=sys.stderr)
    chunker = HierarchicalChunker(max_tokens=args.max_tokens)
    chunks = list(chunker.chunk(doc))

    output_chunks = []
    for i, chunk in enumerate(chunks):
        headings = []
        if chunk.meta.headings:
            for h in chunk.meta.headings:
                if isinstance(h, str):
                    headings.append(h)
                elif hasattr(h, 'text'):
                    headings.append(h.text)

        page_no = None
        if chunk.meta.doc_items and len(chunk.meta.doc_items) > 0:
            item = chunk.meta.doc_items[0]
            if hasattr(item, 'prov') and item.prov and len(item.prov) > 0:
                page_no = item.prov[0].page_no

        chunk_data = {
            "id": str(uuid.uuid4()),
            "text": chunk.text,
            "metadata": {
                "chunk_index": i,
                "source": str(args.input.name),
                "headings": headings,
                "page": page_no,
            },
        }
        output_chunks.append(chunk_data)

    output_data = {
        "source": str(args.input.name),
        "total_chunks": len(output_chunks),
        "chunks": output_chunks,
    }

    with open(args.output, "w") as f:
        json.dump(output_data, f, indent=2)

    print(f"Wrote {len(output_chunks)} chunks to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
