import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


BUNDLE_ID = "com.chunkyapp.Chunky"


def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=300)


def require_macos():
    if platform.system() != "Darwin":
        raise ValueError("App installation and packaging require macOS. The tooling tests can run on Linux.")


def bundle_metadata(app):
    app = Path(app)
    if app.name != "Chunky.app" or not app.is_dir():
        raise ValueError("Choose a built Chunky.app bundle.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("The bundle identifier is not Chunky's.")
    fields = {
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "minimum_macos": info.get("LSMinimumSystemVersion"),
    }
    for name, value in fields.items():
        if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
            raise ValueError(f"The built bundle has an invalid {name}; unresolved Xcode placeholders are not accepted.")
    if fields["minimum_macos"] not in {"27", "27.0"}:
        raise ValueError("Review the cask minimum macOS mapping before packaging a different deployment target.")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", executable):
        raise ValueError("The bundle executable name is invalid.")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("The app executable is missing or not executable.")
    return fields, binary


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_url(url):
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or any(character.isspace() or ord(character) < 32 for character in url)
            or any(character in url for character in ['"', "'", "\\", "#", "{", "}"])):
        raise ValueError("Use a stable HTTPS asset URL without credentials, query, fragment or Ruby interpolation.")
    if not parsed.path.endswith(".zip"):
        raise ValueError("The asset URL must point to the generated ZIP archive.")
    return url


def cask_text(metadata, url):
    validate_url(url)
    if metadata["distribution"] != "notarized":
        raise ValueError("Development archives cannot generate an installable cask.")
    architectures = metadata["architectures"]
    arch = ":arm64" if architectures == ["arm64"] else ":x86_64" if architectures == ["x86_64"] else "[:arm64, :x86_64]"
    return f'''cask "chunky" do
  version "{metadata['version']},{metadata['build']}"
  sha256 "{metadata['sha256']}"

  url "{url}"
  name "Chunky"
  desc "Document processing and vector database workspace"
  homepage "https://github.com/hansdoebel/chunky"

  depends_on arch: {arch}
  depends_on macos: :golden_gate

  app "Chunky.app"
end
'''


def package_app(app, output, asset_url=None, development=False, command=run):
    app = Path(app).resolve()
    bundle_metadata(app)
    if Path(output).exists():
        raise ValueError("Choose a new output directory; existing packages are never overwritten.")
    with tempfile.TemporaryDirectory(prefix="chunky-package-") as temporary:
        staged = Path(temporary) / "Chunky.app"
        command(["/usr/bin/ditto", str(app), str(staged)])
        return package_staged(staged, Path(output).resolve(), asset_url, development, command)


def package_staged(app, output, asset_url, development, command):
    metadata, binary = bundle_metadata(app)
    if development and asset_url:
        raise ValueError("Development archives cannot generate a cask; omit --asset-url.")
    if asset_url:
        validate_url(asset_url)
    architectures = sorted(set(command(["/usr/bin/lipo", "-archs", str(binary)]).stdout.split()))
    if not architectures or not set(architectures) <= {"arm64", "x86_64"}:
        raise ValueError("The app contains unsupported or unrecognized architectures.")
    if not development:
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        signature = command(["/usr/bin/codesign", "--display", "--verbose=4", str(app)])
        if "Authority=Developer ID Application:" not in signature.stdout + signature.stderr:
            raise ValueError("Distribution requires a Developer ID Application signature.")
        command(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
        command(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    metadata.update(architectures=architectures, distribution="development" if development else "notarized")
    suffix = "-development" if development else ""
    archive_name = f"Chunky-{metadata['version']}-{metadata['build']}-{'-'.join(architectures)}{suffix}.zip"
    if asset_url and Path(urlsplit(asset_url).path).name != archive_name:
        raise ValueError(f"The asset URL must end with the actual archive name: {archive_name}")
    output.mkdir(parents=True, exist_ok=False)
    archive = output / archive_name
    command(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    metadata.update(archive=archive.name, sha256=sha256(archive), bytes=archive.stat().st_size)
    if asset_url:
        metadata["asset_url"] = asset_url
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (output / "SHA256SUMS").write_text(f"{metadata['sha256']}  {archive.name}\n")
    if asset_url:
        (output / "chunky.rb").write_text(cask_text(metadata, asset_url))
    return metadata


def install_app(app, destination, command=run):
    app = Path(app).resolve()
    bundle_metadata(app)
    destination = Path(destination).expanduser().absolute()
    if destination.name != "Chunky.app":
        raise ValueError("The destination must be named Chunky.app.")
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"{destination} already exists. Quit Chunky and replace the app explicitly in Finder; saved data is not removed.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".chunky-install-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "Chunky.app"
        command(["/usr/bin/ditto", str(app), str(staged)])
        bundle_metadata(staged)
        if destination.exists() or destination.is_symlink():
            raise ValueError("The destination appeared during installation; it was not changed.")
        staged.rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description="Install a local build or prepare an explicitly verified app archive; never publish releases.")
    commands = parser.add_subparsers(dest="action", required=True)
    install = commands.add_parser("install")
    install.add_argument("--app", type=Path, required=True)
    install.add_argument("--destination", type=Path, default=Path.home() / "Applications/Chunky.app")
    package = commands.add_parser("package")
    package.add_argument("--app", type=Path, required=True)
    package.add_argument("--output", type=Path, required=True)
    package.add_argument("--asset-url")
    package.add_argument("--development", action="store_true")
    args = parser.parse_args()
    require_macos()
    if args.action == "install":
        print(f"Installed {install_app(args.app, args.destination)}")
    else:
        print(json.dumps(package_app(args.app, args.output, args.asset_url, args.development), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        raise SystemExit(1)
