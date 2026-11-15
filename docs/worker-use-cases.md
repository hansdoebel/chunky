# Worker use cases

A worker is optional. The app can do the whole pipeline itself, or it can upload a file and poll a worker. The in-app host picker calls the worker mode **Devbox**. A profile is a name, a base URL, and a Keychain token. Use applies that profile. Model ids are in [models.md](models.md). Installing a worker is in [worker-host.md](worker-host.md). Reaching it is in [remote-workers.md](remote-workers.md).

Every non-loopback bind requires a bearer token. `GET /v1/health` stays open. Every other `/v1` route needs `Authorization: Bearer`. Ollama and vLLM stay on worker loopback.

## Everything on one machine

**Topology.** Apple Silicon runs the app, MLX granite-docling, local Ollama embeddings, and local Qdrant. No worker process.

**Bind and token.** None. Processing host is **Local Mac**.

**Models.** `granite-docling-mlx`, `qwen3-embedding:0.6b` (1024 dimensions), SmolVLM if you describe pictures. Layout Heron.

**Throughput.** Limited by unified memory and the MLX runtime. Fine for a few PDFs. A long batch of large scans is slower than a discrete GPU. TableFormer stays on the CPU. Keep table batches small.

## App plus a GPU worker on the same LAN

**Topology.** The app machine and a Linux worker share a switched network, wired or Wi-Fi. The app uploads the file and polls progress. The worker runs Docling, vLLM, and embeddings.

**Bind and token.** Bind the worker to that NIC's address, or to `0.0.0.0` if several app machines must connect. Set `CHUNKY_WORKER_TOKEN` or a token file. Allow TCP 8080 only from the app machines. A wired link is usually faster and more stable than Wi-Fi. Wi-Fi is enough for typical PDFs. A large scan can stall if the radio is busy.

**Models.** Worker: `ibm-granite/granite-docling-258M` on vLLM, `qwen3-embedding:0.6b` on Ollama. Chart extraction on a second port only when the GPU has room. App machine: leave MLX unused for that job.

**Throughput.** The upload is the whole file, then SSE progress. Wired LAN is the high-throughput case. Wi-Fi is fine until the file is large or the link is noisy.

## Worker over a VPN

**Topology.** The app machine is off the worker LAN. Tailscale, or another VPN that gives the worker a stable name, carries the HTTP connection. The app still stores only a URL.

**Bind and token.** Bind to the VPN address, or to `0.0.0.0` with a firewall that also allows the LAN. Same bearer token as the LAN profile. Prefer HTTPS (`tailscale serve`) or the app's `ts.net` HTTP exception. Do not publish the port on the public internet.

**Models.** Same as the LAN worker. The VPN does not change which models run.

**Throughput.** A direct VPN path is close to the underlying link. A relay (Tailscale DERP, or any similar fallback) is shared and rate-limited. Large PDFs should use the LAN profile when you are on that network. Check `tailscale status` for "via DERP".

## Several workers and profiles

**Topology.** One app, more than one worker. Example profiles: a wired LAN worker, a Wi-Fi address for the same worker, and a VPN name. Or two worker hosts with different GPUs.

**Bind and token.** Each worker has its own bind address and its own token. The app stores one token per profile in the Keychain. Selecting a profile does not change where the next job goes. Use does.

**Models.** Profiles do not store a model id. The embedding model and VLM are app settings. If two workers were installed with different embedding widths, use a separate collection per width. Check reachability reports latency so you can pick the faster path.

**Throughput.** Keep the fast path (usually wired LAN) for bulk ingest. Use the VPN profile when you are away. Do not run two heavy jobs at the same worker unless you have measured the GPU.

## Local Qdrant or Qdrant Cloud

**Topology.** Search always has a Qdrant. It can be Docker on the app machine, or Qdrant Cloud.

**Bind and token.** This is not the worker token. Local Docker uses **Server URL** (`http://localhost:6334` after `make qdrant`). Qdrant Cloud uses **Qdrant Cloud URL** and the API key. Devbox ingest **Qdrant Cloud** sends that URL and key with the job. The worker does not store the key. Devbox ingest **Local Docker** returns vectors for the app to upsert into Server URL.

**Models.** The collection width must match the embedding model. `qwen3-embedding:0.6b` is 1024. A 4B or 8B model needs a new collection.

**Throughput.** Local Docker avoids a cloud round trip and stays available offline. Cloud ingest moves the upsert off the app machine and is the path Retrieval uses when the host is Devbox and ingest is Qdrant Cloud.

## Offline

**Topology.** No cloud account and no VPN. Either everything is on the app machine, or the app and the worker are on a LAN that does not route to the internet.

**Bind and token.** Loopback needs no token. A LAN worker still needs a token if it is not bound to loopback. Pull models before you disconnect: `qwen3-embedding:0.6b`, and the granite-docling weights the host will use.

**Models.** Same defaults. Do not point embeddings or the VLM at a URL that leaves the machine.

**Throughput.** Identical to the local or LAN case. The limit is the GPU or the MLX runtime, not the network.

## Benchmark and eval

**Topology.** The app runs a fixed set of sample PDFs, or an eval query set, and writes metrics. Benchmark collections are throwaway names. Eval scores recall@k, MRR, nDCG, and hit rate.

**Bind and token.** Use the same worker profile you want to measure. A benchmark that should include the network must Use the LAN or VPN profile first. A benchmark of the app machine uses Local Mac.

**Models.** Record the embedding tag and the VLM in the run. Do not compare a 1024-wide collection with a 2560-wide one.

**Throughput.** Benchmark numbers include upload time when a worker is selected. A relayed VPN will dominate the timing. Prefer a direct LAN path when you want GPU time rather than network time. Eval retrieval uses the same route as the Retrieval tab.
