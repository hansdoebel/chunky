import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("checkout", type=Path)
parser.add_argument("--update", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
manifest = json.loads(Path(__file__).with_name("qdrant-swift.json").read_text())
target = root / "LocalPackages/qdrant-swift"
paths = manifest["paths"]
if not paths or any(name not in {"Sources", "Tests", "Package.swift", "Package.resolved", "Makefile"} for name in paths):
    raise SystemExit("Unexpected manifest paths")
if target.is_symlink() or target.parent.is_symlink() or any((target / name).is_symlink() for name in paths):
    raise SystemExit("Refusing symlink vendor destinations")
patch = Path(__file__).with_name(manifest["patch"])
if patch.parent != Path(__file__).parent or not patch.is_file():
    raise SystemExit("Invalid compatibility patch")
if args.update:
    dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all", "--", *[str(target / name) for name in paths]], cwd=root)
    if dirty:
        raise SystemExit("Refusing to overwrite dirty or untracked vendor files")
with tempfile.TemporaryDirectory() as directory:
    stage = Path(directory)
    archive = stage / "source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "-C", str(args.checkout), "archive", manifest["revision"], *manifest["paths"]], stdout=output, check=True)
    with tarfile.open(archive) as source:
        source.extractall(stage, filter="data")
    subprocess.run(["git", "apply", str(patch)], cwd=stage, check=True)
    for name in paths:
        source = stage / name
        if not source.exists() or source.is_symlink() or any(p.is_symlink() for p in source.rglob("*")):
            raise SystemExit("Missing or symlinked staged source: " + name)
    changed = []
    for name in manifest["paths"]:
        source = stage / name
        destination = target / name
        if args.update:
            if destination.is_dir():
                shutil.rmtree(destination)
            elif destination.exists():
                destination.unlink()
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                shutil.copy2(source, destination)
        else:
            expected = {str(p.relative_to(source)): p.read_bytes() for p in source.rglob("*") if p.is_file()} if source.is_dir() else {name: source.read_bytes()}
            actual = {str(p.relative_to(destination)): p.read_bytes() for p in destination.rglob("*") if p.is_file()} if destination.is_dir() else {name: destination.read_bytes()}
            changed.extend(f"{name}/{key}" for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
    if changed:
        raise SystemExit("Vendor drift:\n" + "\n".join(sorted(changed)))
    print("Updated vendored snapshot" if args.update else "Vendored snapshot matches pinned upstream plus compatibility patch")
