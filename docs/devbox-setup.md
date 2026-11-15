# Devbox setup

Run Chunky on the Mac and do the heavy work on the Ubuntu devbox over the direct 10GbE link. Put addresses and the token on the machines. Do not commit them.

## Ubuntu worker

```bash
sudo apt install -y python3-venv python3-dev
sudo useradd --system --create-home --home-dir /opt/chunky chunky || true
sudo mkdir -p /opt/chunky /etc/chunky
sudo chown -R chunky:chunky /opt/chunky
cd /opt/chunky
python3 -m venv worker/.venv
worker/.venv/bin/pip install -U pip
worker/.venv/bin/pip install -r worker/requirements.txt
worker/.venv/bin/pip install -r worker/requirements-docling.txt
```

Do not install `mlx-vlm`. The PyPI `torch==2.15.0` pin is for CPU CI. On this machine, replace it with the ROCm wheel that ROCm 10.1 validates (PyTorch 2.14.x) and that lists `gfx1201`. The generic 2.15.0 wheel does not. See the [ROCm compatibility matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html).

```bash
worker/.venv/bin/python -c "import torch; print(torch.version.hip, torch.cuda.is_available(), torch.cuda.get_arch_list())"
```

`torch.cuda.is_available()` must be true. ROCm reports the R9700 through that CUDA API. `gfx1201` must appear in the arch list. `/v1/health` repeats this under `vlm.gpu` and logs `gpu_visible` at startup.

## Granite-docling

The worker does not load MLX. A granite job uses Docling's `granite_docling` preset, which sends DocTags rather than a generic markdown OCR prompt.

Preferred engine: vLLM on ROCm, loopback only. Install the vLLM build that matches this ROCm release. The default PyPI vLLM wheel is CUDA and will not see the R9700. Leave Flash Attention 2 off (`cuda_use_flash_attention2` stays false).

```bash
vllm serve ibm-granite/granite-docling-258M \
  --host 127.0.0.1 --port 8000 \
  --max-num-seqs 512 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --gpu-memory-utilization 0.6
```

`0.6` is a starting point so Ollama can keep `qwen3-embedding` on the same 32 GB GPU. The 258M VLM and that embedding model both fit; raise utilization only if the embedding model is not resident. The worker calls `http://127.0.0.1:8000/v1/chat/completions` with `CHUNKY_VLM_ENGINE=vllm` (the default).

Chart extraction does not use that server. Granite Vision 4.1 is a different model. Leave `CHUNKY_CHART_VLLM_URL` empty and charts run in-process with Transformers on CUDA. To serve charts separately:

```bash
vllm serve ibm-granite/granite-vision-4.1-4b \
  --host 127.0.0.1 --port 8001 \
  --max-num-seqs 64 \
  --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.3
```

Then set `CHUNKY_CHART_VLLM_URL=http://127.0.0.1:8001`. `0.3` is a starting point beside the document server and the embedding model. If the GPU cannot hold all three, keep charts on Transformers and start that process only for a chart job, or lower the document server's utilization.

## Batch sizes

The standard pipeline on the devbox uses Docling's threaded PDF pipeline. With no vision model resident, OCR and layout batches start at 64 and tables at 4. When granite-docling, picture description, or chart extraction is also on the GPU, those drop to 8 and 16 so the card is shared. The Mac keeps batches of 2 and 1, and TableFormer stays on the CPU.

Docling's GPU guide lists a vLLM concurrency of 64 with `max_tokens` 4096 and a 90 second timeout. That concurrency was measured on NVIDIA hardware. This worker keeps concurrency at 8 until it is checked on the R9700. `page_batch_size` stays at least that concurrency. `max_tokens` stays 4096 and the timeout stays 90.

## Picture description on 32 GB

The devbox default description model is Granite Vision 3.3-2B (`granite_vision`). The Mac default is SmolVLM-256M, which also has an MLX build. Qwen2.5-VL-3B is the larger picker choice. The VLM server URL is only for the API preset. It is separate from Ollama, which stays the embedding server.

A 2B or 3B description model plus `qwen3-embedding` fits in 32 GB if the granite-docling vLLM process is not also holding most of the card. SmolVLM-256M is small enough to leave room for the document server. Do not keep granite-docling, Granite Vision or Qwen, and the embedding model fully resident at the same time. Drop one, or lower `--gpu-memory-utilization` on the document server before enabling description. The Qdrant quality profile turns description and classification on.

Fallback, if vLLM is not running: `CHUNKY_VLM_ENGINE=transformers`. That loads `GRANITEDOCLING_TRANSFORMERS` through `VlmConvertOptions.from_preset("granite_docling", engine_options=TransformersVlmEngineOptions())` with `device="cuda"`. Same rule: do not enable Flash Attention 2.

Ollama stays on `127.0.0.1:11434` for embeddings, or use a separate pooling server:

```bash
vllm serve Qwen/Qwen3-Embedding-0.6B \
  --runner pooling \
  --host 127.0.0.1 --port 8002 \
  --gpu-memory-utilization 0.15
```

Set `CHUNKY_EMBEDDING_BACKEND=openai` and `CHUNKY_EMBEDDING_URL=http://127.0.0.1:8002`. This process is not the granite-docling server. `0.15` leaves room for that server on 32 GB. If both cannot stay resident, stop one before starting the other. The chunk tokenizer follows this model (`Qwen/Qwen3-Embedding-0.6B`), not MiniLM.

Ollama remains available:

```bash
ollama pull qwen3-embedding
```

Generate a token and bind the worker to the 10GbE address in `worker/deploy/chunky-worker.service`:

```bash
sudo worker/.venv/bin/chunky-worker --generate-token --token-file /etc/chunky/worker.token
sudo chgrp chunky /etc/chunky/worker.token
sudo chmod 640 /etc/chunky/worker.token
sudo cp worker/deploy/chunky-worker.service /etc/systemd/system/chunky-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now chunky-worker
sudo ufw allow from MAC_10GBE_IP to DEVBOX_10GBE_IP port 8080 proto tcp
```

## Smoke test

```bash
curl -sS "http://127.0.0.1:8080/v1/health"
curl -sS -H "Authorization: Bearer $(sudo cat /etc/chunky/worker.token)" \
  "http://127.0.0.1:8080/v1/models"
```

From the Mac, use `http://DEVBOX_10GBE_IP:8080`. `401` means the token does not match. A timeout means the bind address, systemd, or the firewall.

## Mac app

1. Preferences, Documents, Processing host: **Devbox**.
2. Worker URL `http://DEVBOX_10GBE_IP:8080` and the token. Test connection calls `/v1/health`, then `/v1/models` with the bearer token. The message distinguishes an unreachable host, HTTP 401, a dimension mismatch, and App Transport Security.
3. Plain HTTP to a private LAN address is allowed by `NSAllowsLocalNetworking` in `Info.plist`. A public IP still needs HTTPS.
4. Preferences, Qdrant, Devbox ingest: **Local Docker** returns vectors for the Mac to upsert, or **Qdrant Cloud** sends the Cloud URL and Keychain API key with the job. The worker does not store the key.
5. Chunk Only sends `ingest_target=none`. Chunk & Ingest sends `return_vectors` or `qdrant_cloud`. Local Mac keeps the current path.
