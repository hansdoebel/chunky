from pathlib import Path
import subprocess
import tempfile
import unittest
from setup_macos_venv import validate_existing


class MacVenvTests(unittest.TestCase):
    def test_missing_environment_needs_no_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            validate_existing(Path(directory) / "missing", lambda *a, **k: self.fail("unexpected probe"))

    def test_unrelated_directory_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            fixture = path / "user-data"
            fixture.write_text("keep")
            with self.assertRaisesRegex(RuntimeError, "not a usable venv"):
                validate_existing(path)
            self.assertEqual(fixture.read_text(), "keep")

    def test_old_or_failed_python_is_rejected_without_mutation(self):
        for code, version in [(0, "3.11"), (1, "3.12")]:
            with self.subTest(code=code, version=version), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                (path / "bin").mkdir()
                (path / "bin/python3").touch()
                (path / "pyvenv.cfg").write_text("fixture")
                with self.assertRaisesRegex(RuntimeError, "was not changed"):
                    validate_existing(path, lambda *a, **k: subprocess.CompletedProcess([], code, version, ""))
                self.assertEqual((path / "pyvenv.cfg").read_text(), "fixture")

    def test_existing_312_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "bin").mkdir()
            (path / "bin/python3").touch()
            (path / "pyvenv.cfg").write_text("fixture")
            validate_existing(path, lambda *a, **k: subprocess.CompletedProcess([], 0, "3.12\n", ""))
