# Personal installation and updates

This is the short path for using Chunky on your own Mac. A private Homebrew server, public release and Apple Developer account are not needed for a local source build. Release packaging remains optional; see [distribution](distribution.md).

## First installation

The current app requires macOS 27 or newer. Building requires Xcode 27.2 or newer with Swift 6.4. Install and open Xcode, accept its license and select it as the active developer directory. Updating Xcode alone does not make the app compatible with an older macOS release.

From Terminal:

```sh
git clone https://github.com/hansdoebel/chunky.git
cd chunky
make first-launch
make install
open "$HOME/Applications/Chunky.app"
```

`make first-launch` finishes Xcode setup and may request administrator authentication. `make install` runs the prerequisite checks, builds this checkout and installs into your own Applications folder. It does not download models or install processing dependencies. It refuses to overwrite an existing app or symbolic link. Builds use the repository's signing-disabled development configuration; this is not a notarized downloaded release.

If the developer directory is wrong, follow [first-run troubleshooting](macbook-first-run.md). To build and open directly from the checkout without installing another app, use `make run` instead.

## Add only the dependencies your workflow needs

| Workflow | Additional setup |
| --- | --- |
| Open the app and configure it | None |
| Use a remote worker | Reachable worker URL and token; local processing dependencies are unnecessary unless using local fallback |
| Process documents on this Mac | Python 3.12 and the pinned environment below |
| Generate local CPU embeddings | Managed Python environment and the selected model download |
| Use Ollama embeddings | A reachable Ollama service and matching model; it can be remote |
| Use OpenAI-compatible embeddings or Qdrant Cloud | The selected endpoint and credentials; no local database container |
| Run app-managed local Qdrant | Colima and Docker CLI; see [local Qdrant](local-qdrant.md) |
| Develop the browser workspace | Bun and the repository's frontend toolchain; not needed to launch the native app |

For local processing, with Homebrew installed:

```sh
brew install python@3.12
make setup-venv
```

This installs `requirements/macos-scripts.txt` into `~/.chunky-venv`. An incompatible existing environment is reported rather than replaced. Dependency installation and first model use need network access and disk space.

Start in Simple mode with **Save files**. Use Document and worker settings to select **Local Mac** and **Standard (no VLM)**, then return to Simple and choose the output folder. Try one short document before adding embeddings or a database. Even Standard processing may download its required model assets; no VLM download is needed for this path. A successful build alone does not validate live document conversion. See [the full first-run checklist](macbook-first-run.md) when adding services or datasets.

## Update an existing personal installation

There is no automatic app updater or safe replacement command yet. Quit Chunky and use your existing checkout:

```sh
git pull --ff-only
make build
open build/DerivedData/Build/Products/Debug
open "$HOME/Applications"
```

After the build succeeds, replace `~/Applications/Chunky.app` in Finder with the newly built `Chunky.app`. Keep the previous bundle separately if you want to restore it. Do not delete preferences, Keychain entries, worker profiles, datasets, `~/.chunky-venv` or database volumes. Replacing only the app bundle leaves those separate data locations intact. If Git reports local changes or diverged history, inspect them rather than resetting the checkout.

`make install` deliberately refuses an existing destination. [PER-241](https://linear.app/hansdoebel/issue/PER-241) tracks an explicit personal update command with rollback; it is not implemented yet.

When the repository's tested Python requirements change, rerun `make setup-venv` while local processing is stopped. This updates the existing compatible managed environment; it is not transactional and has no automatic rollback.

The current Preferences **Update Docling** action upgrades Docling independently of the repository's tested pins. Prefer the pinned setup command for this personal workflow. **Check for Updates** in that Dependencies section checks Docling, not Chunky itself. [PER-240](https://linear.app/hansdoebel/issue/PER-240) tracks consistent, clearly labeled runtime maintenance; it is not implemented yet.

## What is already improved

The installation command combines preflight checks, a deterministic build path and installation into `~/Applications`. Dependency setup selects Python 3.12 and uses the checked-in requirements. Models and containers remain optional, and no collection is created or reconfigured by installation. Development packaging produces an archive, checksum and manifest, but does not publish a release or provision Homebrew infrastructure.

Installation tooling has portable unit coverage and native CI build/archive validation. Those checks do not replace your first live processing test on the MacBook.
