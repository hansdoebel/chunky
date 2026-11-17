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
with tempfile.TemporaryDirectory() as directory:
    stage = Path(directory)
    archive = stage / "source.tar"
    with archive.open("wb") as output:
        subprocess.run(["git", "-C", str(args.checkout), "archive", manifest["revision"], *manifest["paths"]], stdout=output, check=True)
    with tarfile.open(archive) as source:
        source.extractall(stage, filter="data")
    subprocess.run(["git", "apply", str(Path(__file__).with_name(manifest["patch"]))], cwd=stage, check=True)
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
