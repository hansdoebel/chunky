import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from macos_distribution import bundle_metadata, install_app, package_app, validate_url


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "source/Chunky.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.binary = self.app / "Contents/MacOS/Chunky"
        self.binary.write_bytes(b"fixture executable")
        self.binary.chmod(0o755)
        self.info = {
            "CFBundleIdentifier": "com.chunkyapp.Chunky",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "Chunky",
            "LSMinimumSystemVersion": "27.0",
        }
        self.write_info()
        self.calls = []
        self.architectures = "arm64"
        self.authority = "Authority=Developer ID Application: Test Fixture"
        self.failure = None
        self.output = self.root / "output"
        self.url = "https://example.invalid/releases/Chunky-1.2.3-42-arm64.zip"

    def write_info(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def command(self, args):
        self.calls.append(args)
        if self.failure and self.failure in args:
            raise subprocess.CalledProcessError(1, args, stderr="fixture verification failure")
        if args[0] == "/usr/bin/ditto":
            if "-c" in args:
                with zipfile.ZipFile(args[-1], "w") as archive:
                    source = Path(args[-2])
                    for path in source.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(source.parent))
            else:
                shutil.copytree(args[-2], args[-1], symlinks=True)
        stdout = self.architectures if args[0].endswith("lipo") else ""
        stderr = self.authority if "--display" in args else ""
        return subprocess.CompletedProcess(args, 0, stdout, stderr)

    def test_development_archive_has_actual_checksum_and_bundle(self):
        result = package_app(self.app, self.output, development=True, command=self.command)
        archive = self.output / result["archive"]
        self.assertEqual(result["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(result["bytes"], archive.stat().st_size)
        self.assertEqual(result["distribution"], "development")
        self.assertIn("-development.zip", archive.name)
        self.assertFalse((self.output / "chunky.rb").exists())
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), result)
        self.assertEqual((self.output / "SHA256SUMS").read_text(), f"{result['sha256']}  {archive.name}\n")
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(bundle.read("Chunky.app/Contents/MacOS/Chunky"), self.binary.read_bytes())
        self.assertFalse(any("--verify" in call for call in self.calls))

    def test_release_verifies_staged_bundle_before_generating_cask(self):
        result = package_app(self.app, self.output, self.url, command=self.command)
        cask = (self.output / "chunky.rb").read_text()
        self.assertIn(f'sha256 "{result["sha256"]}"', cask)
        self.assertIn('version "1.2.3,42"', cask)
        self.assertIn(self.url, cask)
        self.assertIn("depends_on arch: :arm64", cask)
        self.assertIn("depends_on macos: :golden_gate", cask)
        for argument in ("--verify", "--display", "--assess", "stapler"):
            verification = next(call for call in self.calls if argument in call)
            self.assertNotEqual(verification[-1], str(self.app))
        self.assertEqual(result["distribution"], "notarized")

    def test_failed_verification_never_emits_distribution_artifacts(self):
        for failure in ("--verify", "--assess", "stapler"):
            with self.subTest(failure=failure):
                self.failure = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    package_app(self.app, self.output, self.url, command=self.command)
                self.assertFalse(self.output.exists())

    def test_ad_hoc_signature_cannot_generate_release(self):
        self.authority = "Signature=adhoc"
        with self.assertRaisesRegex(ValueError, "Developer ID"):
            package_app(self.app, self.output, self.url, command=self.command)
        self.assertFalse(self.output.exists())

    def test_development_cannot_generate_cask(self):
        with self.assertRaisesRegex(ValueError, "cannot generate"):
            package_app(self.app, self.output, self.url, development=True, command=self.command)
        self.assertFalse(self.output.exists())

    def test_actual_archive_name_must_match_asset(self):
        with self.assertRaisesRegex(ValueError, "actual archive name"):
            package_app(self.app, self.output, "https://example.invalid/wrong.zip", command=self.command)
        self.assertFalse(self.output.exists())

    def test_unknown_architecture_is_rejected(self):
        self.architectures = "ppc"
        with self.assertRaisesRegex(ValueError, "architectures"):
            package_app(self.app, self.output, development=True, command=self.command)

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_text("existing package")
        with self.assertRaisesRegex(ValueError, "never overwritten"):
            package_app(self.app, self.output, development=True, command=self.command)
        self.assertEqual(sentinel.read_text(), "existing package")
        self.assertFalse(self.calls)

    def test_install_copies_app_without_changing_source(self):
        destination = self.root / "Applications/Chunky.app"
        self.assertEqual(install_app(self.app, destination, command=self.command), destination)
        self.assertEqual((destination / "Contents/MacOS/Chunky").read_bytes(), self.binary.read_bytes())
        self.assertTrue(self.app.exists())
        self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_install_preserves_existing_app_and_dangling_symlink(self):
        destination = self.root / "Chunky.app"
        destination.mkdir()
        (destination / "keep").write_text("existing app")
        with self.assertRaisesRegex(ValueError, "already exists"):
            install_app(self.app, destination, command=self.command)
        self.assertEqual((destination / "keep").read_text(), "existing app")
        shutil.rmtree(destination)
        destination.symlink_to(self.root / "missing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            install_app(self.app, destination, command=self.command)
        self.assertTrue(destination.is_symlink())
        self.assertFalse(self.calls)

    def test_bundle_identity_and_resolved_versions_are_required(self):
        for field, value in (("CFBundleIdentifier", "other.app"),
                             ("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
                             ("CFBundleVersion", "../42"),
                             ("LSMinimumSystemVersion", "26.0"),
                             ("CFBundleExecutable", "../outside")):
            with self.subTest(field=field):
                old = self.info[field]
                self.info[field] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    bundle_metadata(self.app)
                self.info[field] = old
        self.write_info()
        self.binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            bundle_metadata(self.app)

    def test_asset_urls_cannot_embed_credentials_or_ruby(self):
        for url in ("http://example.invalid/a.zip", "https://token@example.invalid/a.zip",
                    "https://example.invalid/a.zip?token=secret", "https://example.invalid/a.zip#fragment",
                    'https://example.invalid/"bad.zip', "https://example.invalid/#{bad}.zip",
                    "https://example.invalid/a\nb.zip", "https://example.invalid/a.dmg"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                validate_url(url)
        self.assertEqual(validate_url(self.url), self.url)
