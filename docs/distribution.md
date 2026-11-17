# Installing and distributing Chunky

For the short personal-use workflow, see [personal installation and updates](personal-installation.md). The release and Homebrew sections below are optional.

## Try the app on your Mac

The current source build requires macOS 27 or later and Xcode 27.2 or later. Install and open Xcode once, accept its license and select it as the active developer directory. From a checkout of this repository:

```sh
make first-launch install
open "$HOME/Applications/Chunky.app"
```

`make install` runs the existing prerequisite checks, builds the app and copies it into your own Applications folder. It does not require administrator access or install Python packages, models or containers. It refuses to overwrite an existing app, including a symbolic link. To update an existing source installation, quit Chunky, run `make build`, then replace the app explicitly in Finder using `build/DerivedData/Build/Products/Debug/Chunky.app`. Replacing the app bundle does not remove preferences, worker profiles, datasets or database collections.

This is a local development build with signing disabled by the existing build target. These commands do not produce a signed, notarized public release or bypass Gatekeeper. A downloaded CI archive is also a development artifact, not the recommended installation route for another Mac. See [the first-run guide](macbook-first-run.md) for troubleshooting.

## Install only the dependencies you use

| Use | Additional dependency |
| --- | --- |
| Open the app, configure connections, use remote services | None beyond the app's macOS requirement; Xcode is needed only to build from source |
| Process documents locally | Python 3.12 and the app's managed Python environment |
| Generate local CPU embeddings | The managed Python environment; model downloads use disk space |
| Use Ollama embeddings | A reachable Ollama service and the chosen model; the service may run on another machine |
| Use OpenAI-compatible embeddings or Qdrant Cloud | A reachable endpoint and the appropriate credentials; no local container runtime |
| Manage local database containers | Docker CLI and a supported running container runtime, such as Colima; optional |
| Develop the web UI | Bun; not required to launch the native app |

For local document processing, install Python 3.12 if needed, then use the existing setup command:

```sh
brew install python@3.12
make setup-venv
```

This creates `~/.chunky-venv` when missing and installs the repository's pinned helper dependencies. An incompatible existing environment is reported rather than replaced. Runtime selection and models remain explicit app settings; installation does not silently configure a collection or download models. See [requirements](../requirements/macos-scripts.txt) for the exact Python packages.

## Prepare a development archive

```sh
make package-development
```

The output is a ZIP, `SHA256SUMS` and `manifest.json` in `dist/development`. The archive name includes the actual app version, build number and executable architectures, followed by `-development`. The manifest records the actual archive bytes and SHA256. Existing output directories are never overwritten: choose a new directory with the command below for another build.

```sh
python3 tools/macos_distribution.py package \
  --development \
  --app build/DerivedData/Build/Products/Debug/Chunky.app \
  --output dist/development-next
```

The native CI job also packages its already-built app and uploads a short-lived artifact named `chunky-development-unsigned`. It does not publish a GitHub release. Portable unit tests use fixture bundles and mocked Apple tools; the native CI packaging step exercises real `ditto` and `lipo`. Neither constitutes signing or notarization validation for a real release.

## Prepare a distributable release

A release maintainer must first build the intended Release app, sign it using a Developer ID Application identity with Apple's required hardened-runtime settings, notarize it and staple the ticket. Follow [Apple's distribution instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution); credentials and signing configuration are deliberately outside this helper. Set the app's marketing version and build number before building. The helper reads their resolved values from the built `Info.plist`; it never invents a version or uses `sha256 :no_check`.

Package the prepared app into a new directory:

```sh
python3 tools/macos_distribution.py package \
  --app /path/to/Chunky.app \
  --output dist/release-candidate
```

The helper copies the bundle to staging, validates its identity, executable and deployment target, inspects actual Mach-O architectures, verifies the signature and Developer ID authority, checks Gatekeeper assessment and validates the stapled notarization ticket. Only then does it create the ZIP and checksum manifest. It currently maps the repository's macOS 27 deployment target to Homebrew's `:golden_gate`; changing the deployment target requires an explicit mapping update. Failed archive creation can leave a partial output directory; inspect it and choose a fresh output path for another attempt.

To generate a cask at the same time, additionally supply `--asset-url` with the intended stable HTTPS URL of that exact ZIP. Its filename must match the actual version/build/architecture filename reported by the helper. The URL must have no embedded credentials, query string or fragment. The helper does not upload the ZIP, check remote availability, create a release/tag, or claim that the supplied URL exists. Publish the exact generated ZIP through the maintainer's chosen release process before installing the cask. Any subsequent archive modification invalidates its checksum and requires a new package and cask.

Do not use `--development` for distribution: it cannot generate a cask. No signed release, Homebrew repository, download endpoint or automatic updater is provisioned by this tooling.

## A private Homebrew tap does not need a separate server

A tap is an ordinary Git repository containing `Casks/chunky.rb`. A private repository hosted by an existing Git service is enough for the metadata. After a maintainer creates the repository and publishes a verified archive, commit the generated cask to that path. Use the actual owner, tap name and authenticated Git URL in place of these placeholders:

```sh
brew tap OWNER/TAP GIT_URL
brew install --cask OWNER/TAP/chunky
brew update
brew upgrade --cask OWNER/TAP/chunky
```

For each update, increment the app version/build, produce and verify a new archive, publish it, then commit the newly generated cask. The cask declares the actual architecture and minimum macOS version, and installs only `Chunky.app`. It has no mandatory local-processing or container dependencies and no `zap` stanza deleting user data. Before adopting Homebrew, quit Chunky and explicitly resolve any existing manually installed app so two installations do not compete.

Private tap access and private release downloads are separate authentication problems. Git credentials that clone the tap do not automatically authenticate an HTTPS release asset. The generated cask deliberately contains no token or custom credential handling. Choose a download location Homebrew can access using its documented authentication mechanism; test `brew fetch --cask OWNER/TAP/chunky` with the intended user's permissions before rollout. If private asset authentication is not configured, use authenticated manual downloads of the verified signed archive until it is. Do not put tokens in the cask, Git history or command-line URL, or turn off quarantine/signature checks to make an unsigned artifact installable.

Official references, reviewed for this implementation:

- [Creating and maintaining a tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew fleet management](https://docs.brew.sh/Homebrew-Fleet-Management) and [FAQ](https://docs.brew.sh/FAQ), including private repository authentication
- [Cask cookbook](https://docs.brew.sh/Cask-Cookbook) and [supported macOS symbols](https://docs.brew.sh/rubydoc/MacOSVersion.html)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
