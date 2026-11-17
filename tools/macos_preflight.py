import platform
import re
import shutil
import subprocess
import sys


def version_at_least(output, minimum):
    match = re.search(r"\b(\d+)\.(\d+)(?:\.(\d+))?", output)
    return match is not None and tuple(int(part or 0) for part in match.groups()) >= minimum


def check(system=platform.system, which=shutil.which, run=subprocess.run):
    if system() != "Darwin":
        return ["The native app requires macOS 27 or newer. Linux can run the worker and its tests."]
    failures = []
    checks = [
        (["sw_vers", "-productVersion"], (27, 0, 0), "macOS 27 or newer is required."),
        (["xcodebuild", "-version"], (27, 2, 0), "Select Xcode 27.2 or newer with xcode-select, then run make first-launch."),
        (["xcrun", "swift", "--version"], (6, 4, 0), "The selected Xcode must provide Swift 6.4 or newer."),
    ]
    for command, minimum, message in checks:
        if not which(command[0]):
            failures.append(message)
            continue
        try:
            result = run(command, capture_output=True, text=True, timeout=30)
            if result.returncode or not version_at_least(result.stdout, minimum):
                failures.append(message)
        except (OSError, subprocess.TimeoutExpired):
            failures.append(message)
    return failures


if __name__ == "__main__":
    problems = check()
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        raise SystemExit(1)
    if not shutil.which("python3.12"):
        print("Local document processing needs Python 3.12: brew install python@3.12, then make setup-venv.")
    print("Mac build prerequisites found. Docker, Ollama and model downloads are optional for the first app launch.")
