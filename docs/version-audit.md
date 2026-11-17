# Version audit — 17 November 2026

Versions below were read from official registries or project release APIs on this date. A server release, SDK, Python client and model are separately versioned. No dependency is described as updated until its manifest/lockfile and validation agree.

## Python packages

| Package | Current pin | Latest published | Source |
| --- | --- | --- | --- |
| docling | 2.150.1 | 2.150.1 | [PyPI](https://pypi.org/pypi/docling/json) |
| docling-core | 2.107.0 | 2.107.1 | [PyPI](https://pypi.org/pypi/docling-core/json) |
| docling-ibm-models | 4.0.4 | 4.0.4 | [PyPI](https://pypi.org/pypi/docling-ibm-models/json) |
| transformers | 5.23.0 | 5.23.0 | [PyPI](https://pypi.org/pypi/transformers/json) |
| torch | 2.15.0 | 2.15.0 | [PyPI](https://pypi.org/pypi/torch/json) |
| mlx-vlm | 0.7.12 | 0.8.0 | [PyPI](https://pypi.org/pypi/mlx-vlm/json) |
| fastembed | 0.9.1 | 0.9.1 | [PyPI](https://pypi.org/pypi/fastembed/json) |
| fastapi | 0.163.0 | 0.163.1 | [PyPI](https://pypi.org/pypi/fastapi/json) |
| uvicorn | 0.54.0 | 0.54.0 | [PyPI](https://pypi.org/pypi/uvicorn/json) |
| httpx | 0.28.1 | 0.28.1 | [PyPI](https://pypi.org/pypi/httpx/json) |
| python-multipart | 0.0.33 | 0.0.34 | [PyPI](https://pypi.org/pypi/python-multipart/json) |
| pydantic | 2.14.3 | 2.14.3 | [PyPI](https://pypi.org/pypi/pydantic/json) |
| qdrant-client | 1.20.0 | 1.20.0 | [PyPI](https://pypi.org/pypi/qdrant-client/json) |
| pytest | 9.2.0 | 9.2.0 | [PyPI](https://pypi.org/pypi/pytest/json) |
| lxml | 6.1.3 | 6.1.3 | [PyPI](https://pypi.org/pypi/lxml/json) |
| pypdf | 6.4.2 | 7.1.0 | [PyPI](https://pypi.org/pypi/pypdf/json) |

Docling, Transformers and model runtimes need compatible dependency resolution together. Mac MLX inference cannot be validated on a Linux executor. ROCm images intentionally supply their own GPU-enabled PyTorch instead of replacing it with the PyPI CPU/CUDA package. Patch and major updates are being validated separately from the first-launch cleanup; this table records the audit, not an inference pass.

## Browser toolchain

| Package | Current pin | Latest published | Source |
| --- | --- | --- | --- |
| svelte | 5.57.3 | 5.57.3 | [npm](https://registry.npmjs.org/svelte/latest) |
| @internationalized/date | 3.12.4 | 3.12.4 | [npm](https://registry.npmjs.org/@internationalized%2fdate/latest) |
| @lucide/svelte | 1.73.0 | 1.73.0 | [npm](https://registry.npmjs.org/@lucide%2fsvelte/latest) |
| @playwright/test | 1.65.1 | 1.65.1 | [npm](https://registry.npmjs.org/@playwright%2ftest/latest) |
| @sveltejs/vite-plugin-svelte | 7.3.1 | 7.3.1 | [npm](https://registry.npmjs.org/@sveltejs%2fvite-plugin-svelte/latest) |
| @tailwindcss/vite | 4.3.5 | 4.3.5 | [npm](https://registry.npmjs.org/@tailwindcss%2fvite/latest) |
| @types/node | 24.10.1 | 26.6.6 | [npm](https://registry.npmjs.org/@types%2fnode/latest) |
| @types/pngjs | 6.0.5 | 6.0.5 | [npm](https://registry.npmjs.org/@types%2fpngjs/latest) |
| bits-ui | 2.21.0 | 2.21.0 | [npm](https://registry.npmjs.org/bits-ui/latest) |
| cn | 0.5.2 | 0.5.2 | [npm](https://registry.npmjs.org/cn/latest) |
| pngjs | 7.0.0 | 7.0.0 | [npm](https://registry.npmjs.org/pngjs/latest) |
| shadcn-svelte | 1.8.1 | 1.8.1 | [npm](https://registry.npmjs.org/shadcn-svelte/latest) |
| svelte-check | 4.7.8 | 4.7.8 | [npm](https://registry.npmjs.org/svelte-check/latest) |
| tailwind-variants | 3.3.1 | 4.0.2 | [npm](https://registry.npmjs.org/tailwind-variants/latest) |
| tailwindcss | 4.3.5 | 4.3.5 | [npm](https://registry.npmjs.org/tailwindcss/latest) |
| tw-animate-css | 1.4.0 | 1.4.0 | [npm](https://registry.npmjs.org/tw-animate-css/latest) |
| typescript | 6.0.3 | 7.0.2 | [npm](https://registry.npmjs.org/typescript/latest) |
| vite | 8.3.8 | 8.3.8 | [npm](https://registry.npmjs.org/vite/latest) |
| vitest | 5.1.0 | 5.1.0 | [npm](https://registry.npmjs.org/vitest/latest) |

Bun 1.4.4 is the latest stable release ([official release](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4)). Node 24.22.1 remains the pinned runtime line; the latest Node release index also lists Node 26.13.1 LTS and Node 27 prereleases ([official index](https://nodejs.org/dist/index.json)). Node types should match the chosen runtime major; the latest 24.x types are 24.19.2, rather than the registry default 26.6.6. TypeScript 7 and tailwind-variants 4 require a tested frontend migration, including the Bun lockfile and browser component suite.

## Swift and server images

| Component | Current pin | Latest verified | Source |
| --- | --- | --- | --- |
| grpc-swift-2 | 2.4.4 | 2.4.4 | [Releases](https://github.com/grpc/grpc-swift-2/releases/latest) |
| grpc-swift-nio-transport | 2.12.0 | 2.13.0 | [Releases](https://github.com/grpc/grpc-swift-nio-transport/releases/latest) |
| grpc-swift-protobuf | 2.5.0 | 2.5.0 | [Releases](https://github.com/grpc/grpc-swift-protobuf/releases/latest) |
| swift-protobuf | 1.41.0 | 1.41.0 | [Releases](https://github.com/apple/swift-protobuf/releases/latest) |
| Qdrant server | 1.20.2 | 1.20.2 | [Releases](https://github.com/qdrant/qdrant/releases/latest) |
| Ollama ROCm image | 0.40.16-rocm | 0.40.16 release | [Releases](https://github.com/ollama/ollama/releases/latest) |
| vLLM ROCm image | 0.33.0-rocm100 | 0.34.0 release | [Releases](https://github.com/vllm-project/vllm/releases/latest) |

The official [ROCm PyTorch image tags](https://hub.docker.com/r/rocm/pytorch/tags) still include `rocm10.1.0_ubuntu24.04_py3.12_pytorch_release_2.14.0`, the selected Python 3.12/Ubuntu 24.04 combination. Tags using Ubuntu 26.04/Python 3.14 are not drop-in replacements for this application. Do not infer container compatibility from the ROCm GitHub latest-release pointer, which currently returns `rocm-7.14.0`. Live GPU acceptance remains an operator test on the target hardware; registry existence alone does not prove R9700 support.

Swift client updates must go through the [pinned vendor workflow](qdrant-client.md), with upstream tests and replay verification. Generated public-subset headers that mention Qdrant 1.20.1 describe their source subset; they are not active server image pins and are not manually edited.

The native app and vendored package require macOS 27, Xcode 27.2 and Swift 6.4 as specified in [AGENTS.md](../AGENTS.md). Lowering that baseline is a separate compatibility change.
