import contextlib
import json
import math
import os
import sys
from pathlib import Path

MODEL = "minishlab/potion-retrieval-32M"
DIMENSIONS = 512
CACHE = Path(os.environ.get("CHUNKY_FASTEMBED_CACHE", "~/.cache/chunky/fastembed")).expanduser()


class Runtime:
    def __init__(self, factory=None, tokenizer_factory=None):
        self.factory = factory
        self.encoder = None
        self.tokenizer_factory = tokenizer_factory
        self.strict_tokenizer = None

    def validate_full_input(self, encoder, texts):
        if self.strict_tokenizer is None:
            tokenizer = getattr(getattr(encoder, "model", None), "tokenizer", None)
            if tokenizer is None or (tokenizer.truncation or {}).get("max_length") != 512:
                raise ValueError("Cannot verify the cached Potion tokenizer's 512-token context; refusing Cloud import")
            factory = self.tokenizer_factory
            if factory is None:
                from tokenizers import Tokenizer
                factory = Tokenizer.from_str
            clone = factory(tokenizer.to_str())
            clone.no_truncation()
            clone.no_padding()
            self.strict_tokenizer = clone
        encoded = self.strict_tokenizer.encode_batch(texts, add_special_tokens=False)
        if len(encoded) != len(texts) or any(len(value.ids) > 512 for value in encoded):
            raise ValueError("Potion input exceeds 512 tokens. Choose smaller Cloud import chunks; no text was truncated")

    def load(self, download=False):
        if self.encoder is None:
            if self.factory is None:
                from fastembed import TextEmbedding
                self.factory = TextEmbedding
            supported = self.factory.list_supported_models()
            if not any(m["model"] == MODEL and m["dim"] == DIMENSIONS for m in supported):
                raise ValueError("Install FastEmbed 0.9.1 with make setup-venv; Potion 32M/512 is required.")
            self.encoder = self.factory(model_name=MODEL, cache_dir=str(CACHE), local_files_only=not download)
        return self.encoder

    def handle(self, request):
        if request.get("model") != MODEL:
            raise ValueError(f"Unsupported local CPU model. Select {MODEL}.")
        command = request.get("command")
        if command == "health":
            try:
                self.load()
                return {"status": "Ready · cached locally · CPU", "model": MODEL, "dimensions": DIMENSIONS}
            except Exception as exc:
                return {"status": f"Not ready: {exc}. Run make setup-venv, then Download model while online.", "model": MODEL, "dimensions": DIMENSIONS}
        encoder = self.load(download=command == "prepare")
        if command == "prepare":
            return {"status": "Ready", "model": MODEL, "dimensions": DIMENSIONS}
        if command != "embed":
            raise ValueError("Unknown embedding command")
        texts = request.get("texts")
        if not isinstance(texts, list) or any(not isinstance(t, str) or not t.strip() for t in texts):
            raise ValueError("Embedding input must contain non-empty text strings")
        if request.get("query") not in (True, False):
            raise ValueError("Specify document or query embedding")
        strict = request.get("reject_truncation", False)
        if not isinstance(strict, bool):
            raise ValueError("reject_truncation must be a boolean")
        if strict:
            self.validate_full_input(encoder, texts)
        method = encoder.query_embed if request["query"] else encoder.passage_embed
        vectors = [v.tolist() for v in method(texts, batch_size=64)] if texts else []
        if len(vectors) != len(texts) or any(len(v) != DIMENSIONS or not all(math.isfinite(x) for x in v) for v in vectors):
            raise ValueError("Potion returned invalid vectors; refusing to index or search")
        result = {"vectors": vectors, "model": MODEL, "dimensions": DIMENSIONS}
        if strict:
            result["untruncated"] = True
        return result


def main():
    runtime = Runtime()
    for line in sys.stdin:
        try:
            with contextlib.redirect_stdout(sys.stderr):
                result = runtime.handle(json.loads(line))
        except Exception as exc:
            result = {"error": f"Local CPU embedding failed: {exc}. Check make setup-venv and Download model in Preferences."}
        print(json.dumps(result, allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
