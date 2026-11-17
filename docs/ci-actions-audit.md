# GitHub Actions version audit

Verified against official GitHub releases and release commits on 2026-11-17. Application dependencies are audited separately.

| Action | Stable release | Pinned commit |
| --- | --- | --- |
| [actions/checkout](https://github.com/actions/checkout/releases/tag/v7.0.1) | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [actions/setup-python](https://github.com/actions/setup-python/releases/tag/v7.1.0) | v7.1.0 | `6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` |
| [actions/setup-node](https://github.com/actions/setup-node/releases/tag/v7.1.0) | v7.1.0 | `949feb2413d6458794dcd2491c4babbbce0c15c1` |
| [actions/upload-artifact](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| [oven-sh/setup-bun](https://github.com/oven-sh/setup-bun/releases/tag/v2.2.0) | v2.2.0 | `0c5077e51419868618aeaa5fe8019c62421857d6` |
| [dorny/paths-filter](https://github.com/dorny/paths-filter/releases/tag/v4.0.3) | v4.0.3 | `ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d` |

The Bun and path-filter actions were already current. The actions run on Node.js 24, requiring Actions Runner 2.327.1 or newer. The existing hosted Ubuntu and `xcode-27` jobs already execute the Node.js 24 Bun action. Actual workflow runs validate the upgraded actions on both platforms. This runtime is separate from the Node version installed for frontend tools.

Checkout 7 restricts fork code checkout under `pull_request_target` and `workflow_run`; these workflows use neither trigger. Checkout 6 moved persisted credentials into the runner temporary directory. No job runs authenticated Git commands inside Docker actions. Workflow permissions remain unchanged.

Setup Python 7 changes its implementation to ESM without changing inputs or outputs. Existing Python 3.12 selection and explicit pip cache paths remain. Setup Node 7 removes a dummy registry authentication token; these workflows do not configure a registry URL or depend on that token. Automatic npm caching is explicitly disabled because package installation uses Bun and its committed lockfile.

Upload Artifact 7 adds optional direct single-file uploads. These workflows retain the default ZIP archive mode, existing artifact names, retention, missing-file policy, and hidden-file exclusion. No artifact consumer or screenshot format changes.

The release notes and `action.yml` definitions for each pinned release are the source for these compatibility decisions. Native builds, Python tests, web tests, container assets, Mac dependency imports, and artifact uploads must pass in hosted CI before merging.
