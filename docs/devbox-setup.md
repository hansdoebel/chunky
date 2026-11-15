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

Do not install `mlx-vlm`. For the GPU, install a ROCm PyTorch wheel into the same venv. Ollama stays on `127.0.0.1:11434`:

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
