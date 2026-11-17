from pathlib import Path
import shlex
import subprocess
import unittest


class MacMakefileTests(unittest.TestCase):
    def test_build_run_and_cleanup_use_the_same_checkout(self):
        root = Path(__file__).resolve().parents[1]
        output = subprocess.check_output(["make", "--no-print-directory", "-n", "build", "run", "clean"], cwd=root, text=True)
        commands = [shlex.split(line) for line in output.splitlines()]
        xcode = [command for command in commands if command[0] == "xcodebuild"]
        self.assertEqual(len(xcode), 2)
        expected = str(root / "build/DerivedData")
        for command in xcode:
            self.assertEqual(command[command.index("-scheme") + 1], "Chunky")
            self.assertEqual(command[command.index("-derivedDataPath") + 1], expected)
        opened = next(command for command in commands if command[0] == "open")
        self.assertEqual(opened[1], str(root / "build/DerivedData/Build/Products/Debug/Chunky.app"))
        self.assertFalse(any(command[0] in {"rm", "find"} for command in commands))

    def test_plain_make_still_builds_the_app(self):
        root = Path(__file__).resolve().parents[1]
        output = subprocess.check_output(["make", "--no-print-directory", "-n"], cwd=root, text=True)
        commands = [shlex.split(line) for line in output.splitlines()]
        builds = [command for command in commands if command[0] == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0][-1], "build")
