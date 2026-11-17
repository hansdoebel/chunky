from pathlib import Path
import subprocess
import sys


def validate_existing(path, run=subprocess.run):
    if not path.exists():
        return
    python = path / "bin/python3"
    if not (path / "pyvenv.cfg").is_file() or not python.is_file():
        raise RuntimeError(f"{path} is not a usable venv. Move it aside explicitly before creating a new environment.")
    result = run([str(python), "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"], capture_output=True, text=True, timeout=30)
    if result.returncode or result.stdout.strip() != "3.12":
        raise RuntimeError(f"{path} is not Python 3.12. Choose another environment or move it aside explicitly; it was not changed.")


def main():
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError("Run setup with python3.12.")
    path = Path.home() / ".chunky-venv"
    validate_existing(path)
    if not path.exists():
        subprocess.run([sys.executable, "-m", "venv", str(path)], check=True)
    requirements = Path(__file__).resolve().parents[1] / "requirements/macos-scripts.txt"
    subprocess.run([str(path / "bin/python3"), "-m", "pip", "install", "-r", str(requirements)], check=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
