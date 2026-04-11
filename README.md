# Chunky

A native macOS application for processing documents into semantic chunks and storing them as vector embeddings in a Qdrant vector database.

![Chunky main window](docs/images/main-window.png)

## Features

- Multi-format document processing (PDF, DOCX, PPTX, HTML, images) via Docling
- Local VLM support with DocTags output (SmolDocling MLX, Granite-Docling MLX)
- Text chunking with configurable token limits and overlap
- Embedding generation via Ollama (local LLM server)
- Vector storage in Qdrant via gRPC
- Collection browser for exploring stored vectors
- Export to Markdown, HTML, JSON, and plain text

## Prerequisites

- Xcode
- Docker (for Qdrant)
- [Ollama](https://ollama.com/)
- Python 3 (for Docling)

```
brew install protobuf swift-protobuf grpc-swift
```

## Setup

```
make first-launch
make setup-venv
```

The Python venv is created at `~/.chunky-venv` with Docling and MLX installed.

> **Note:** The build disables code signing by default, so no Apple Developer account is required.

## Usage

```
make run           # build and launch the app
make build         # build only
make test          # run Swift tests
make test-python   # run Python tests (no docling needed)
make test-all      # run all tests
make clean         # clean build artifacts
make open-xcode    # open in Xcode
```

Start the required services:

```
make qdrant        # start Qdrant on localhost:6333 (REST) / 6334 (gRPC)
make ollama        # start Ollama
make services      # start both
```

## VLM Models

Chunky supports local vision-language models for document processing via Docling's built-in model specs. These run directly on Apple Silicon using MLX — no Ollama needed for VLM inference.

| Model | Engine | Output | Speed* |
|-------|--------|--------|--------|
| SmolDocling 256M (MLX) | MLX | DocTags | ~6s/page |
| SmolDocling 256M (Transformers) | Transformers | DocTags | ~102s/page |
| Granite-Docling 258M (MLX) | MLX | DocTags | — |
| Granite-Docling 258M (Transformers) | Transformers | DocTags | — |

*Benchmarked on MacBook M3 Max, single PDF page.

The default model is **SmolDocling MLX**. Change it in Preferences > Documents > VLM Model. Select "Standard (no VLM)" to use the classic layout-analysis pipeline instead.

## Architecture

```
Chunky/Sources/
  Models/         -- AppState, AppSettings, ProcessingJob, QdrantModels
  Services/       -- Docling, Ollama, Qdrant, Chunking, DocumentProcessor
  Views/          -- ContentView, CollectionBrowser, Preferences
  Theme/          -- AppTheme
LocalPackages/    -- qdrant-swift (local gRPC client package)
```

## Dependencies

- [grpc-swift-2](https://github.com/grpc/grpc-swift-2) -- GRPCCore
- [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport.git) -- GRPCNIOTransportHTTP2
- [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf.git) -- GRPCProtobuf
- [swift-protobuf](https://github.com/apple/swift-protobuf.git)
- [swift-collections](https://github.com/apple/swift-collections.git)

## Resources

- [Docling](https://www.docling.ai/)
