import subprocess
import unittest
from macos_preflight import check, version_at_least


class MacPreflightTests(unittest.TestCase):
    def test_minimum_versions_and_newer_patch_releases(self):
        self.assertTrue(version_at_least("Xcode 27.2\nBuild version 27B52", (27, 2, 0)))
        self.assertTrue(version_at_least("Apple Swift version 6.4.2", (6, 4, 0)))
        self.assertFalse(version_at_least("26.6", (27, 0, 0)))
        self.assertFalse(version_at_least("Xcode 27.1", (27, 2, 0)))
        self.assertFalse(version_at_least("not installed", (6, 4, 0)))

    def test_linux_exits_without_invoking_mac_tools(self):
        def unexpected(*args, **kwargs):
            self.fail("Mac tools must not run on Linux")
        self.assertEqual(len(check(lambda: "Linux", unexpected, unexpected)), 1)

    def test_reports_all_missing_prerequisites(self):
        self.assertEqual(len(check(lambda: "Darwin", lambda _: None)), 4)

    def test_supported_mac_and_toolchain(self):
        outputs = {"sw_vers": "27.0", "xcodebuild": "Xcode 27.2", "xcrun": "Apple Swift version 6.4.2"}
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, outputs[command[0]], "")
        self.assertEqual(check(lambda: "Darwin", lambda name: name, run), [])

    def test_failed_or_hung_commands_are_actionable(self):
        def run(command, **kwargs):
            if command[0] == "xcrun":
                raise subprocess.TimeoutExpired(command, 30)
            return subprocess.CompletedProcess(command, 1, "", "unavailable")
        failures = check(lambda: "Darwin", lambda name: name, run)
        self.assertEqual(len(failures), 3)
        self.assertTrue(any("first-launch" in message for message in failures))


if __name__ == "__main__":
    unittest.main()
