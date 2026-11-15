"""Integration tests for docling_convert.py — requires docling installed."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent / "docling_convert.py"
ASSETS = Path(__file__).resolve().parent.parent.parent.parent / "assets"
SAMPLE_PDF = ASSETS / "sample.pdf"
PYTHON = os.path.expanduser("~/.chunky-venv/bin/python3")

def _has_docling():
    try:
        result = subprocess.run(
            [PYTHON, "-c", "import docling"],
            capture_output=True,
            timeout=10,
        )
        return result.returncode == 0
    except Exception:
        return False

@unittest.skipUnless(
    SAMPLE_PDF.exists(), f"sample.pdf not found at {SAMPLE_PDF}"
)
@unittest.skipUnless(
    os.path.exists(PYTHON), f"Python venv not found at {PYTHON}"
)
@unittest.skipUnless(_has_docling(), "docling not installed in venv")
class TestDoclingConvertIntegration(unittest.TestCase):

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="chunky-test-")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _run(self, *extra_args, timeout=120):
        cmd = [
            PYTHON, str(SCRIPT),
            str(SAMPLE_PDF),
            "--output-dir", self.tmpdir,
            "--progress",
        ] + list(extra_args)
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result

    def test_convert_to_json(self):
        result = self._run("--format", "json")
        self.assertEqual(result.returncode, 0, f"stderr: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertTrue(data["success"], data.get("error"))
        self.assertGreater(data["page_count"], 0)
        output_file = Path(data["output_file"])
        self.assertTrue(output_file.exists())
        content = json.loads(output_file.read_text())
        self.assertIn("texts", content)

    def test_convert_to_markdown(self):
        result = self._run("--format", "markdown")
        self.assertEqual(result.returncode, 0, f"stderr: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertTrue(data["success"], data.get("error"))
        output_file = Path(data["output_file"])
        self.assertTrue(output_file.exists())
        content = output_file.read_text()
        self.assertGreater(len(content), 10)

    def test_convert_to_text(self):
        result = self._run("--format", "text")
        self.assertEqual(result.returncode, 0, f"stderr: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertTrue(data["success"], data.get("error"))

    def test_convert_to_html(self):
        result = self._run("--format", "html")
        self.assertEqual(result.returncode, 0, f"stderr: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertTrue(data["success"], data.get("error"))

    def test_progress_on_stderr(self):
        result = self._run("--format", "json")
        self.assertEqual(result.returncode, 0)
        lines = [l for l in result.stderr.strip().split("\n") if l.strip()]
        self.assertGreater(len(lines), 0)
        first = json.loads(lines[0])
        self.assertEqual(first["type"], "progress")

    def test_max_pages(self):
        result = self._run("--format", "json", "--max-pages", "1")
        self.assertEqual(result.returncode, 0, f"stderr: {result.stderr}")
        data = json.loads(result.stdout)
        self.assertTrue(data["success"], data.get("error"))
        self.assertEqual(data["page_count"], 1)

    def test_log_file_created(self):
        self._run("--format", "json")
        log_file = Path.home() / "Library" / "Logs" / "Chunky" / "docling_convert.log"
        self.assertTrue(log_file.exists(), f"Log file not found at {log_file}")
        content = log_file.read_text()
        self.assertIn("convert_document called", content)

    def test_nonexistent_file(self):
        cmd = [
            PYTHON, str(SCRIPT),
            "/nonexistent/file.pdf",
            "--output-dir", self.tmpdir,
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        data = json.loads(result.stdout)
        self.assertFalse(data["success"])
        self.assertEqual(data["error_type"], "file_not_found")

if __name__ == "__main__":
    unittest.main()
