# ROCm Compose worker

This starts the HTTP worker and Ollama on a Linux devbox with an R9700. The
host must already have a compatible AMD driver and ROCm device access (PER-40
and PER-41). It does not install host drivers. The worker serves its bundled
web UI on the same port as the API; see [web-ui.md](../../docs/web-ui.md).

All upstream image tags are pinned. The worker uses the ROCm PyTorch 2.14 base
from PER-53 and preserves its installed torch with a pip constraint. It does
not install the CPU `torch==2.15.0` pin from `requirements-docling.txt` or the
`docling` extra. A dependency conflict fails the build rather than replacing
ROCm torch. `requirements-rocm.txt` pins the remaining Docling packages.

Run these commands from `worker/deploy` with Docker Compose v2. Set the bind
address to the devbox's private 10GbE interface, never a WAN address or
`0.0.0.0`. Set the numeric device group ids from the host:

```bash
export CHUNKY_BIND_IP=YOUR_PRIVATE_INTERFACE_IP
export CHUNKY_VIDEO_GID=$(getent group video | cut -d: -f3)
export CHUNKY_RENDER_GID=$(getent group render | cut -d: -f3)
export CHUNKY_TOKEN_FILE="$HOME/.config/chunky-compose/worker.token"
install -d -m 700 "$(dirname "$CHUNKY_TOKEN_FILE")"
(umask 077; set -C; python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$CHUNKY_TOKEN_FILE")
chmod 444 "$CHUNKY_TOKEN_FILE"
docker compose config --quiet
docker compose up -d --build
```

Create the token once. Do not overwrite an existing token during an upgrade.
The parent directory is owner-only; the read-only secret mount is readable by
the container's worker user (uid 10001). Put the same token in the app Keychain.
The token is never put in an image, Compose environment, or Qdrant configuration.
The worker refuses its container-wide bind when the file is empty or missing.
Only port 8080 is published, on the selected host interface. Restrict that port
to your app machines with the host firewall, as in [worker-host.md](../../docs/worker-host.md).

Ollama shares the worker's network namespace and binds loopback. vLLM and
Qdrant do the same when enabled. None publishes a host port. Defaults use
Transformers in-process for VLM jobs, because vLLM is off by default.

Pull the exact embedding model, then check the GPU and API:

```bash
docker compose exec ollama ollama pull qwen3-embedding:0.6b
docker compose exec worker python3 -c 'import torch; print(torch.version.hip, torch.cuda.is_available(), torch.cuda.get_arch_list())'
curl -fsS "http://$CHUNKY_BIND_IP:8080/v1/health"
curl -fsS -H "Authorization: Bearer $(cat "$CHUNKY_TOKEN_FILE")" "http://$CHUNKY_BIND_IP:8080/v1/models"
```

Confirm `gfx1201`, GPU availability, 32 GB visibility, and actual model offload
on the R9700 before treating a deployment as validated. The image alone does
not prove driver compatibility. A model first runs after its download; allow
startup time and watch `docker compose logs`. Worker state, converted chunks,
model downloads and optional Qdrant storage use separate persistent volumes.
`docker compose down` preserves them. Do not use `down --volumes` for upgrades.

For optional vLLM, recreate with the matching worker engine:

```bash
CHUNKY_VLM_ENGINE=vllm docker compose --profile vllm up -d
```

If that official vLLM ROCm image cannot serve Granite on the installed driver,
leave the profile off and use the default Transformers engine. Do not switch
to the deprecated `rocm/vllm` image or a floating tag.

For optional Qdrant, start its profile and configure its internal URL for
search. This profile has no Qdrant API key configured; authenticated
`POST /v1/search` requests can search existing collections without a Qdrant
key. The worker bearer token is still required:

```bash
CHUNKY_QDRANT_URL=http://127.0.0.1:6333 docker compose --profile qdrant up -d
```

Worker jobs using `ingest_target=qdrant_cloud` require a nonempty
`qdrant_api_key`, including when the URL points to a local Qdrant server.
The keyless profile above is therefore a search target, not a supported
worker-ingest configuration. Use a Qdrant deployment with a real configured
API key for worker ingestion; do not supply a dummy key. Browser ingestion
keeps that key on the worker; see the
[web UI credential guidance](../../docs/web-ui.md).

The app's Local Docker ingest target still means Qdrant on the Mac, using
returned vectors. The optional devbox Qdrant does not replace it or migrate
collections. Keep model identities and dimensions aligned; changing the
embedding model never reconfigures an existing collection. Mac-originated
Cloud ingest continues to receive its API key per job through the
authenticated API.

To validate configuration without downloading images or needing GPU hardware,
run `docker compose --profile vllm --profile qdrant config --quiet`. Hardware
smoke tests are manual and stay outside CI.
