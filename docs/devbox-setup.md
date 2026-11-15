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

Fallback, if vLLM is not running: `CHUNKY_VLM_ENGINE=transformers`. That loads `GRANITEDOCLING_TRANSFORMERS` through `VlmConvertOptions.from_preset("granite_docling", engine_options=TransformersVlmEngineOptions())` with `device="cuda"`. Same rule: do not enable Flash Attention 2.

Ollama stays on `127.0.0.1:11434` for embeddings:

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
