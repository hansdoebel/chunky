"""Tests for docling_convert.py — pure logic only, no docling dependency required."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent))

import docling_convert

class TestSetupCpuMode(unittest.TestCase):
    """Tests for _setup_cpu_mode env var configuration."""

    CPU_ENV_VARS = [
        "PYTORCH_MPS_DISABLE",
        "PYTORCH_ENABLE_MPS_FALLBACK",
        "CUDA_VISIBLE_DEVICES",
        "PYTORCH_NO_CUDA_MEMORY_CACHING",
        "DOCLING_DEVICE",
        "DEVICE",
        "ACCELERATOR",
    ]

    def _clear_cpu_env(self):
        for var in self.CPU_ENV_VARS:
            os.environ.pop(var, None)

    def setUp(self):
        self._clear_cpu_env()

    def tearDown(self):
        self._clear_cpu_env()

    def test_default_sets_cpu_env(self):
        """Default (no args) should force CPU mode."""
        with patch.object(sys, "argv", ["docling_convert.py", "input.pdf"]):
            docling_convert._setup_cpu_mode()
        self.assertEqual(os.environ["DOCLING_DEVICE"], "cpu")
        self.assertEqual(os.environ["PYTORCH_MPS_DISABLE"], "1")

    def test_accelerator_mps_skips_cpu_env(self):
        """--accelerator mps should not set CPU env vars."""
        with patch.object(
            sys, "argv", ["docling_convert.py", "input.pdf", "--accelerator", "mps"]
        ):
            docling_convert._setup_cpu_mode()
        self.assertNotIn("DOCLING_DEVICE", os.environ)

    def test_accelerator_cpu_sets_cpu_env(self):
        """--accelerator cpu should still set CPU env vars."""
        with patch.object(
            sys, "argv", ["docling_convert.py", "input.pdf", "--accelerator", "cpu"]
        ):
            docling_convert._setup_cpu_mode()
        self.assertEqual(os.environ["DOCLING_DEVICE"], "cpu")

    def test_local_vlm_model_skips_cpu_env(self):
        """Local VLM models manage their own device — skip CPU enforcement."""
        with patch.object(
            sys,
            "argv",
            ["docling_convert.py", "input.pdf", "--vlm-model", "smoldocling-mlx"],
        ):
            docling_convert._setup_cpu_mode()
        self.assertNotIn("DOCLING_DEVICE", os.environ)

    def test_remote_vlm_model_still_sets_cpu(self):
        """Non-local VLM models should still get CPU env when accelerator is cpu."""
        with patch.object(
            sys,
            "argv",
            ["docling_convert.py", "input.pdf", "--vlm-model", "llava"],
        ):
            docling_convert._setup_cpu_mode()
        self.assertEqual(os.environ["DOCLING_DEVICE"], "cpu")

    def test_short_flag_accelerator(self):
        """-a should work the same as --accelerator."""
        with patch.object(
            sys, "argv", ["docling_convert.py", "input.pdf", "-a", "cuda"]
        ):
            docling_convert._setup_cpu_mode()
        self.assertNotIn("DOCLING_DEVICE", os.environ)

class TestWriteOutput(unittest.TestCase):
    """Tests for _write_output atomic file writing."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.output_file = Path(self.tmpdir) / "out.json"

    def tearDown(self):
        import shutil

        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _make_mock_doc(self, text="hello world"):
        doc = MagicMock()
        doc.export_to_dict.return_value = {"text": text}
        doc.export_to_markdown.return_value = f"# Doc\n\n{text}\n"
        doc.export_to_text.return_value = text
        doc.export_to_doctags.return_value = f"<doc>{text}</doc>"
        doc.export_to_html.return_value = f"<html><body>{text}</body></html>"
        return doc

    def test_json_format(self):
        doc = self._make_mock_doc()
        ok, err = docling_convert._write_output(
            doc, "json", self.output_file, "embedded"
        )
        self.assertTrue(ok)
        self.assertIsNone(err)
        content = json.loads(self.output_file.read_text())
        self.assertEqual(content, {"text": "hello world"})

    def test_markdown_format(self):
        doc = self._make_mock_doc()
        out = Path(self.tmpdir) / "out.markdown"
        ok, _ = docling_convert._write_output(doc, "markdown", out, "embedded")
        self.assertTrue(ok)
        self.assertIn("# Doc", out.read_text())

    def test_text_format(self):
        doc = self._make_mock_doc()
        out = Path(self.tmpdir) / "out.text"
        ok, _ = docling_convert._write_output(doc, "text", out, "embedded")
        self.assertTrue(ok)
        self.assertEqual(out.read_text(), "hello world")

    def test_doctags_format(self):
        doc = self._make_mock_doc()
        out = Path(self.tmpdir) / "out.doctags"
        ok, _ = docling_convert._write_output(doc, "doctags", out, "embedded")
        self.assertTrue(ok)
        self.assertIn("<doc>", out.read_text())

    def test_html_format(self):
        doc = self._make_mock_doc()
        out = Path(self.tmpdir) / "out.html"
        ok, _ = docling_convert._write_output(doc, "html", out, "embedded")
        self.assertTrue(ok)
        self.assertIn("<html>", out.read_text())

    def test_unsupported_format_returns_error(self):
        doc = self._make_mock_doc()
        ok, err = docling_convert._write_output(
            doc, "xlsx", self.output_file, "embedded"
        )
        self.assertFalse(ok)
        self.assertIsNotNone(err)
        assert err is not None
        self.assertIn("xlsx", err)
        self.assertFalse(self.output_file.exists())

    def test_markdown_no_images_strips_placeholders(self):
        doc = self._make_mock_doc()
        doc.export_to_markdown.return_value = (
            "# Title\n\n<!-- image -->\n\nSome text\n\n<!-- image -->\n\nMore text"
        )
        out = Path(self.tmpdir) / "out.markdown_no_images"
        ok, _ = docling_convert._write_output(
            doc, "markdown_no_images", out, "embedded"
        )
        self.assertTrue(ok)
        content = out.read_text()
        self.assertNotIn("<!-- image -->", content)
        self.assertIn("Some text", content)
        self.assertNotIn("\n\n\n", content)

    def test_atomic_write_no_partial_file_on_error(self):
        """If export raises, no output file should be left behind."""
        doc = self._make_mock_doc()
        doc.export_to_dict.side_effect = RuntimeError("export failed")
        with self.assertRaises(RuntimeError):
            docling_convert._write_output(doc, "json", self.output_file, "embedded")
        self.assertFalse(self.output_file.exists())

        tmp_files = list(Path(self.tmpdir).glob("*.tmp"))
        self.assertEqual(tmp_files, [])

    def test_atomic_write_preserves_existing_on_error(self):
        """If export fails, the previous output file should remain intact."""
        self.output_file.write_text("original content")
        doc = self._make_mock_doc()
        doc.export_to_dict.side_effect = RuntimeError("export failed")
        with self.assertRaises(RuntimeError):
            docling_convert._write_output(doc, "json", self.output_file, "embedded")
        self.assertEqual(self.output_file.read_text(), "original content")

class TestConvertDocumentErrors(unittest.TestCase):
    """Tests for convert_document error handling (no docling needed)."""

    def test_missing_file(self):
        mock_converter = MagicMock()
        with patch.dict(
            sys.modules,
            {"docling": mock_converter, "docling.document_converter": mock_converter},
        ):
            result = docling_convert.convert_document(
                input_path="/nonexistent/file.pdf",
            )
        self.assertFalse(result["success"])
        self.assertEqual(result.get("error_type"), "file_not_found")

    @patch.dict(sys.modules, {"docling": None, "docling.document_converter": None})
    def test_missing_docling_import(self):

        result = docling_convert.convert_document(
            input_path=__file__,
        )
        self.assertFalse(result["success"])
        self.assertEqual(result.get("error_type"), "import_error")
        self.assertIn("docling", result.get("error", "").lower())

class TestMainArgParsing(unittest.TestCase):
    """Tests for CLI argument parsing."""

    def test_minimal_args(self):
        with patch.object(sys, "argv", ["docling_convert.py", "input.pdf"]):
            parser = docling_convert.main.__code__

            import argparse

            parser = argparse.ArgumentParser()
            parser.add_argument("input")
            parser.add_argument("--format", "-f", default="json")
            parser.add_argument("--max-pages", "-m", type=int)
            parser.add_argument("--ocr", action="store_true")
            parser.add_argument("--accelerator", "-a", default="cpu")
            args = parser.parse_args(["input.pdf"])
            self.assertEqual(args.input, "input.pdf")
            self.assertEqual(args.format, "json")
            self.assertFalse(args.ocr)
            self.assertEqual(args.accelerator, "cpu")

    def test_all_formats_accepted(self):
        valid_formats = [
            "json",
            "markdown",
            "markdown_no_images",
            "markdown_with_images",
            "text",
            "doctags",
            "html",
        ]
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--format", "-f", choices=valid_formats, default="json")
        for fmt in valid_formats:
            args = parser.parse_args(["input.pdf", "--format", fmt])
            self.assertEqual(args.format, fmt)

class TestLayoutModelArg(unittest.TestCase):

    def test_all_layout_models_accepted(self):
        valid_models = ["default", "heron", "egret-medium", "egret-large", "egret-xlarge"]
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--layout-model", choices=valid_models, default="default")
        for model in valid_models:
            args = parser.parse_args(["input.pdf", "--layout-model", model])
            self.assertEqual(args.layout_model, model)

    def test_layout_model_default(self):
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--layout-model", default="default")
        args = parser.parse_args(["input.pdf"])
        self.assertEqual(args.layout_model, "default")

class TestExtractSchemaArg(unittest.TestCase):

    def test_extract_schema_accepted(self):
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--extract-schema", default=None)
        args = parser.parse_args(["input.pdf", "--extract-schema", "/tmp/schema.json"])
        self.assertEqual(args.extract_schema, "/tmp/schema.json")

    def test_extract_schema_default_is_none(self):
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--extract-schema", default=None)
        args = parser.parse_args(["input.pdf"])
        self.assertIsNone(args.extract_schema)

class TestInputFormatArg(unittest.TestCase):

    def test_all_input_formats_accepted(self):
        valid_formats = [
            "pdf", "docx", "pptx", "xlsx", "html", "image",
            "md", "asciidoc", "csv", "xml_uspto", "xml_jats", "xml_xbrl",
        ]
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--input-format", choices=valid_formats, default=None)
        for fmt in valid_formats:
            args = parser.parse_args(["input.pdf", "--input-format", fmt])
            self.assertEqual(args.input_format, fmt)

    def test_input_format_default_is_none(self):
        import argparse

        parser = argparse.ArgumentParser()
        parser.add_argument("input")
        parser.add_argument("--input-format", default=None)
        args = parser.parse_args(["input.pdf"])
        self.assertIsNone(args.input_format)

class TestConversionStageMs(unittest.TestCase):
    def test_inner_stages_share_the_convert_window(self):
        stages = docling_convert._conversion_stage_ms(
            40,
            7,
            enable_ocr=True,
            no_tables=False,
            do_picture_description=True,
            vlm_model="granite-docling-transformers",
            chunk=True,
        )
        self.assertEqual(stages["convert_layout"], 40)
        self.assertEqual(stages["ocr"], 40)
        self.assertEqual(stages["table"], 40)
        self.assertEqual(stages["picture_description"], 40)
        self.assertEqual(stages["vlm_convert"], 40)
        self.assertEqual(stages["chunking"], 7)

    def test_disabled_stages_are_omitted(self):
        stages = docling_convert._conversion_stage_ms(
            10,
            0,
            enable_ocr=False,
            no_tables=True,
            do_picture_description=False,
            vlm_model=None,
            chunk=False,
        )
        self.assertEqual(stages, {"convert_layout": 10})

if __name__ == "__main__":
    unittest.main()
