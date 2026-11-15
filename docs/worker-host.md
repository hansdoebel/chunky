# Worker host

Run the app on an Apple Silicon machine and send heavy conversion to a Linux worker. The worker needs a ROCm-capable AMD GPU with at least 32 GB of GPU memory. Put addresses and the token on the machines. Do not commit them.

How the app reaches that worker, including a LAN and a VPN, is in [remote-workers.md](remote-workers.md). Topologies are in [worker-use-cases.md](worker-use-cases.md). Model ids are in [models.md](models.md).

## Install

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

Do not install `mlx-vlm`. The PyPI `torch==2.15.0` pin is for CPU CI. On the worker, replace it with the ROCm wheel that your ROCm release validates and that lists your GPU's gfx target. The generic CUDA wheel does not. See the [ROCm compatibility matrix](https://rocm.docs.amd.com/en/latest/compatibility/compatibility-matrix.html).

```bash
worker/.venv/bin/python -c "import torch; print(torch.version.hip, torch.cuda.is_available(), torch.cuda.get_arch_list())"
```

`torch.cuda.is_available()` must be true. ROCm reports the GPU through that CUDA API. Your gfx target must appear in the arch list. `/v1/health` repeats this under `vlm.gpu` and logs `gpu_visible` at startup.

## Granite-docling

The worker does not load MLX. A granite job uses Docling's `granite_docling` preset, which sends DocTags rather than a generic markdown OCR prompt.

Preferred engine: vLLM on ROCm, loopback only. Install the vLLM build that matches this ROCm release. Leave Flash Attention 2 off (`cuda_use_flash_attention2` stays false).

```bash
vllm serve ibm-granite/granite-docling-258M \
  --host 127.0.0.1 --port 8000 \
  --max-num-seqs 512 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --gpu-memory-utilization 0.6
```

`0.6` is a starting point so Ollama can keep `qwen3-embedding:0.6b` on the same GPU when it has at least 32 GB. Raise utilization only if the embedding model is not resident. The worker calls `http://127.0.0.1:8000/v1/chat/completions` with `CHUNKY_VLM_ENGINE=vllm` (the default).

Chart extraction does not use that server. Granite Vision 4.1 is a different model. Leave `CHUNKY_CHART_VLLM_URL` empty and charts run in-process with Transformers. To serve charts separately:

```bash
vllm serve ibm-granite/granite-vision-4.1-4b \
  --host 127.0.0.1 --port 8001 \
  --max-num-seqs 64 \
  --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.3
```

Then set `CHUNKY_CHART_VLLM_URL=http://127.0.0.1:8001`. If the GPU cannot hold the document server, the embedding model, and this 4B model, keep charts on Transformers or turn chart extraction off.

## Batch sizes

With no vision model resident, OCR and layout batches start at 64 and tables at 4. When granite-docling, picture description, or chart extraction shares the GPU, those drop to 8 and 16. The app machine keeps batches of 2 and 1, and TableFormer stays on the CPU.

Docling's GPU guide lists a vLLM concurrency of 64. That number was measured on NVIDIA hardware. This worker keeps concurrency at 8 until you measure it on your GPU. `page_batch_size` stays at least that concurrency. `max_tokens` stays 4096 and the timeout stays 90.

## Picture description

The worker-host default is Granite Vision 3.3-2B (`granite_vision`). The app-machine default is SmolVLM-256M. Qwen2.5-VL-3B is the larger picker choice. Do not keep granite-docling, a 2B or 3B description model, and the embedding model fully resident at the same time on a 32 GB GPU. Drop one, or lower `--gpu-memory-utilization` on the document server.

Fallback, if vLLM is not running: `CHUNKY_VLM_ENGINE=transformers`, with `device="cuda"`. Do not enable Flash Attention 2.

```bash
ollama pull qwen3-embedding:0.6b
```

`qwen3-embedding` with no tag, and `qwen3-embedding:latest`, are the 8B model (4096 dimensions). The app default is `qwen3-embedding:0.6b` and 1024 dimensions. A different width needs a new collection.

## Token and bind

```bash
sudo worker/.venv/bin/chunky-worker --generate-token --token-file /etc/chunky/worker.token
sudo chgrp chunky /etc/chunky/worker.token
sudo chmod 640 /etc/chunky/worker.token
sudo cp worker/deploy/chunky-worker.service /etc/systemd/system/chunky-worker.service
```

Set `CHUNKY_WORKER_HOST` in that unit to the address the app machine should use, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now chunky-worker
sudo ufw allow from APP_MACHINE_IP to WORKER_IP port 8080 proto tcp
```

Any bind other than loopback refuses to start until a bearer token is set.

## Smoke test

```bash
curl -sS "http://127.0.0.1:8080/v1/health"
curl -sS -H "Authorization: Bearer $(sudo cat /etc/chunky/worker.token)" \
  "http://127.0.0.1:8080/v1/models"
```

From the app machine, use `http://WORKER_IP:8080`. `401` means the token does not match. A timeout means the bind address, systemd, or the firewall.

## App

1. Preferences, Documents, Processing host: **Devbox**. That label means "use a worker."
2. Save a profile with the worker URL and the bearer token, then press Use. Check reachability calls `/v1/health`, then `/v1/models`.
3. Plain HTTP to a private LAN address is allowed by `NSAllowsLocalNetworking`. A public name needs HTTPS, or the `ts.net` exception already in the app plist.
4. For Qdrant Cloud ingest, fill **Qdrant Cloud URL** and the API key. **Server URL** is the local Docker address on the app machine.
5. Chunk Only sends `ingest_target=none`. Chunk & Ingest sends `return_vectors` or `qdrant_cloud`.
