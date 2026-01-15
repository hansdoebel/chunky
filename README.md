# Chunky

> **Early Development**: This app is in early development and has only been tested with specific configurations. Use at your own risk. Contributions and bug reports welcome!

A macOS app for chunking documents (PDF, DOCX, PPTX, HTML, images) into semantic chunks, generating embeddings via Ollama, and storing them in Qdrant for vector search.

![Chunky Screenshot](assets/screenshot.webp)

## Requirements

- macOS 14.0+
- Swift 5.9+
- Python 3.10+
- [Ollama](https://ollama.ai/) (for embeddings)
- [Qdrant](https://qdrant.tech/) (cloud or local)
- Rust (for building qdrant-up CLI tool)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/hansdoebel/chunky.git
cd chunky
```

### 2. Set up Python environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Build the qdrant-up CLI tool

```bash
cd qdrant-up
cargo build --release
cp target/release/qdrant-up ~/.local/bin/  # or /usr/local/bin/
cd ..
```

### 4. Build the app

```bash
./build-app.sh
```

### 5. Run the app

```bash
open build/Chunky.app
```

Or install to Applications:

```bash
cp -r build/Chunky.app /Applications/
```

## Configuration

Before using Chunky, configure:

1. **Ollama**: Start Ollama and pull an embedding model:
   ```bash
   ollama serve
   ollama pull snowflake-arctic-embed2
   ```

2. **Qdrant**: Set up your Qdrant URL and API key in Preferences

### Tested Configuration

This app has been tested with:
- **Embedding model**: `snowflake-arctic-embed2` via Ollama
- **Accelerator**: CPU (MPS/Metal has known issues with some documents)
- **Qdrant**: Qdrant Cloud

Other configurations may work but have not been verified.

## Usage

1. Drag and drop documents into the app
2. Select a processing mode:
   - **Chunk Only**: Extract chunks and save as JSON
   - **Chunk & Ingest**: Full pipeline to Qdrant
   - **Ingest Only**: Upload pre-chunked JSON
   - **Batch Ingest**: Process multiple files efficiently
3. Click Start

## Supported Formats

- PDF, DOCX, PPTX, XLSX
- HTML, Markdown
- Images (PNG, JPEG, TIFF, WebP)
- CSV
- Pre-chunked JSON

## Architecture

```
Document -> Docling (chunking) -> Ollama (embeddings) -> Qdrant (storage)
```

- **Chunky/** - Swift macOS app
- **scripts/** - Python chunker using Docling
- **qdrant-up/** - Rust CLI for fast Qdrant uploads

## Documentation

- [Docling](https://ds4sd.github.io/docling/)
- [Ollama](https://ollama.ai/)
- [Qdrant](https://qdrant.tech/documentation/)
