# Run Chunky from an M4 Max MacBook Pro

Use the MacBook in two ways:

1. **Local Mac.** Process on the laptop with MLX granite-docling or SmolDocling MLX and local Ollama embeddings, then ingest to Qdrant Cloud.
2. **Devbox worker.** The app uploads the document and polls the Ubuntu worker. The R9700 runs Docling, granite-docling through vLLM, and embeddings. Ingest can still go to Qdrant Cloud.

The Mac Studio path over 10GbE stays the default for heavy ingest. See [devbox-setup.md](devbox-setup.md). This guide covers the MacBook over local Wi-Fi and an optional Tailscale path for a stable name and for access when you are not on the LAN.

Do not commit addresses or the bearer token. There is no Tailscale SDK in the app. The worker is a URL plus the token. Model ids and why they were picked are in [models.md](models.md).

## Install and test today

This is the short path for the M4 Max against the devbox worker. Addresses stay on the machines.

1. On the Mac: Xcode 27.2, then `make first-launch` and `make setup-venv` in this repo. Build with `make run`.
2. On the devbox, the worker is already bound off loopback with a bearer token. Confirm `curl -sS http://DEVBOX_LAN_IP:8080/v1/health`.
3. On the devbox, pull the embedding tag the collection uses: `ollama pull qwen3-embedding:0.6b`. Do not pull bare `qwen3-embedding`. That tag is the 8B model and its vectors are 4096 wide.
4. In the app, Preferences, Documents: Processing host **Devbox**. Save a Wi-Fi LAN profile with `http://DEVBOX_LAN_IP:8080` or `http://HOSTNAME.local:8080` and the token. Press Use, then Check reachability. A green result includes a latency.
5. Preferences, Qdrant. For Devbox ingest **Qdrant Cloud**, fill **Qdrant Cloud URL** and the API key. That pair is what the job and Retrieval send. **Server URL** is the Local Docker address on the Mac (`http://localhost:6334` after `make qdrant`). An empty Cloud URL makes the first Cloud ingest fail.
6. Embedding model `qwen3-embedding:0.6b`, dimensions 1024. VLM Granite-Docling (the devbox preset, not the MLX build). Layout Heron. Drop one PDF on the queue and run Chunk & Ingest.
7. Open Retrieval, search that collection, and confirm a hit. Hybrid and rerank can wait until that search works. If the width is wrong, the job fails with `dimension_mismatch`. Create a new collection instead of reusing one built with another model.

## Recommendation

Save one worker URL per path (Mac Studio 10GbE, Wi-Fi LAN, Tailscale) and use Test Connection. That probe calls `GET /v1/health`, then `GET /v1/models` with the token.

Tailscale is optional. MagicDNS gives a stable hostname, and WireGuard encrypts the hop, without opening a port on the router. On the same Wi-Fi LAN a direct Tailscale path is usually fine. If `tailscale status` shows the peer **via DERP**, large uploads go through a shared relay and get slow. Prefer the LAN profile whenever the status says DERP. Use Tailscale when you want the stable name or you are off the LAN.

The bearer token stays required on every profile. Tailscale only limits who can open the port.

## Worker bind, token, and ports

| Setting | Default | Role |
| --- | --- | --- |
| `CHUNKY_WORKER_HOST` or `--host` | `127.0.0.1` | Bind address |
| `CHUNKY_WORKER_PORT` or `--port` | `8080` | Bind port |
| `CHUNKY_WORKER_TOKEN` | unset | Bearer token. Overrides token files whenever it is set. An empty or whitespace-only value disables file fallback. Unset the variable to use a token file |
| `CHUNKY_WORKER_TOKEN_FILE` | unset | Token file. Must exist when set |
| `~/.config/chunky/worker.token` or `$XDG_CONFIG_HOME/chunky/worker.token` | — | File fallback |

Generate a token once. It is printed to stdout. The optional file is mode `0600`:

```bash
sudo /opt/chunky/worker/.venv/bin/chunky-worker --generate-token --token-file /etc/chunky/worker.token
sudo chgrp chunky /etc/chunky/worker.token
sudo chmod 640 /etc/chunky/worker.token
```

Every `/v1` route except `GET /v1/health` requires:

```
Authorization: Bearer <token>
```

`/v1/health` stays open so a reachability probe can succeed before the token is checked. A missing, empty, or wrong token on `/v1/models`, `/v1/search`, and the job routes returns 401. Do not put the token in the query string.

Ollama (`CHUNKY_OLLAMA_URL`, default `http://127.0.0.1:11434`) and vLLM (`CHUNKY_VLLM_URL`, default `http://127.0.0.1:8000`) stay on loopback. Do not publish them on Wi-Fi or the tailnet.

### Bind addresses

- **Loopback (`127.0.0.1`).** Only this machine can connect, unless you put `tailscale serve` in front.
- **One interface.** Bind the 10GbE address for the Mac Studio, the Wi-Fi or LAN address for the MacBook, or the Tailscale IPv4 from `tailscale ip -4` when only the tailnet should connect.
- **`0.0.0.0`.** Use this when one process must accept the Mac Studio on 10GbE, the MacBook on Wi-Fi, and Tailscale together. The worker logs a warning. Restrict the port with `ufw` and a Tailscale grant. Do not rely on the bind address alone.

Example environment when one listener serves all of those paths:

```bash
CHUNKY_WORKER_HOST=0.0.0.0
CHUNKY_WORKER_PORT=8080
CHUNKY_WORKER_TOKEN_FILE=/etc/chunky/worker.token
```

Firewall sketch. Replace the placeholders. The `100.64.0.0/10` line is the Tailscale CGNAT range, for a tailnet IP when you bind `0.0.0.0` and you are not using Serve:

```bash
sudo ufw allow from MAC_STUDIO_10GBE_IP to DEVBOX_10GBE_IP port 8080 proto tcp
sudo ufw allow from MACBOOK_LAN_IP to DEVBOX_LAN_IP port 8080 proto tcp
sudo ufw allow from 100.64.0.0/10 to any port 8080 proto tcp
sudo ufw deny 8080/tcp
```

Narrow the Tailscale source to the MacBook and Mac Studio tailnet addresses once those addresses stay put.

## Local Mac on the M4 Max MacBook Pro

1. Install Xcode, then run `make first-launch` and `make setup-venv`.
2. Start local Ollama and pull `qwen3-embedding:0.6b` if you embed on the laptop. The bare `qwen3-embedding` tag is the 8B model.
3. In Preferences, Documents, set Processing host to **Local Mac**.
4. VLM: Granite-Docling 258M (MLX) or SmolDocling 256M (MLX). **Standard (no VLM)** uses the classic pipeline.
5. In Preferences, Qdrant, set **Server URL** to the Qdrant Cloud address and enter the API key. Local Mac ingest uses **Server URL**. The **Qdrant Cloud URL** field is only for Devbox ingest and is ignored on Local Mac. For Docker on the laptop, leave **Server URL** at `http://localhost:6334` after `make qdrant`.

This path does not need the devbox, Wi-Fi routing, or Tailscale.

## Connect over local Wi-Fi

The MacBook and the devbox must be on the same LAN. The worker must listen on an address that LAN can reach (the LAN NIC or `0.0.0.0`), not only the 10GbE NIC or loopback.

1. On the devbox, note the Wi-Fi or shared-LAN IPv4 (`ip -4 addr`). Prefer a DHCP reservation so the address does not change.
2. mDNS: if Avahi is installed, `http://HOSTNAME.local:8080` may work from the Mac. `ping HOSTNAME.local` is a better check than `host` or `nslookup`. If mDNS is flaky, put the reserved IPv4 in the worker URL.
3. Open port 8080 from the MacBook LAN address. See the `ufw` sketch above.
4. In the app: Processing host **Devbox**, worker URL `http://DEVBOX_LAN_IP:8080` or `http://HOSTNAME.local:8080`, paste the bearer token, then Test Connection.

`NSAllowsLocalNetworking` in `Chunky/Info.plist` allows plain HTTP to a private LAN address. A public IP still needs HTTPS.

### curl from the MacBook

```bash
curl -sS "http://DEVBOX_LAN_IP:8080/v1/health"
curl -sS -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"quarterly revenue","collection":"documents","limit":5,"qdrant_url":"https://QDRANT_CLOUD_HOST","qdrant_api_key":"QDRANT_API_KEY"}' \
  "http://DEVBOX_LAN_IP:8080/v1/search"
```

`POST /v1/search` returns 400 `qdrant_url is required` unless the JSON includes `qdrant_url` or the worker process has `CHUNKY_QDRANT_URL` set. Add `CHUNKY_QDRANT_API_KEY` on the worker only when that URL is the one you search. A request for a different URL must send `qdrant_api_key` in the JSON. Do not commit either value.

A timeout is the bind address, the firewall, or the wrong interface. HTTP 401 is a token mismatch. `/v1/health` succeeding and `/v1/search` returning 401 still means the host is reachable.

## Optional Tailscale path

Install Tailscale on the devbox, the MacBook, and later the Mac Studio, all on the same tailnet. Turn MagicDNS on in the admin console. This is machine setup. The app does not talk to Tailscale.

### macOS client

Use the **standalone** Tailscale client from Tailscale’s package server, not the App Store build and not the open-source `tailscaled` variant. The App Store build can join a tailnet, but it is sandboxed and is not the client to use here. Do not install both.

Sign in, then confirm with `tailscale status`.

### Ubuntu devbox

Follow Tailscale’s Linux install. After `sudo tailscale up`:

```bash
tailscale ip -4
tailscale status
```

Use a plain MagicDNS or tailnet HTTP URL on port 8080. If the node is named `devbox`, that is `http://devbox:8080`. The longer name is `http://devbox.TAILNET.ts.net:8080`. Some macOS tools (`host`, `nslookup`) skip system DNS and fail. Check the name with `ping` or `curl`.

### Plain HTTP on 8080, or Serve HTTPS

Start with the plain MagicDNS name or the tailnet IPv4, HTTP, port 8080. Bind the worker to `tailscale ip -4`, or to `0.0.0.0` if the Mac Studio and the LAN must connect too. That matches the app’s HTTP worker URL.

`tailscale serve` is the later option when you want HTTPS. It proxies the tailnet to loopback and can present a `*.ts.net` certificate. The command below forwards to `127.0.0.1`, so the worker must be listening there. If it is bound only to `tailscale ip -4`, switch `CHUNKY_WORKER_HOST` to `127.0.0.1` before starting Serve. If the LAN and 10GbE must stay reachable, keep `CHUNKY_WORKER_HOST=0.0.0.0` and the firewall rules above. `0.0.0.0` accepts the Serve forward. A Tailscale-only bind does not.

```bash
CHUNKY_WORKER_HOST=127.0.0.1
sudo tailscale serve --bg --https=443 http://127.0.0.1:8080
```

Serve is easier for App Transport Security, and the worker process can stay on `127.0.0.1`, but that bind does not serve the Mac Studio on 10GbE. Enable HTTPS certificates for the tailnet before using Serve. Do not use Funnel. The worker stays private to the tailnet.

### App Transport Security

`Chunky/Info.plist` sets `NSAllowsLocalNetworking`, which covers RFC1918 HTTP, including a Wi-Fi LAN address and `HOSTNAME.local`. It does not cover a public name. Plain HTTP to `*.ts.net` needs an exception. The plist includes `ts.net` with `NSIncludesSubdomains` and `NSExceptionAllowsInsecureHTTPLoads` so `http://devbox.TAILNET.ts.net:8080` can load.

If Test Connection still reports an ATS failure, switch that profile to Serve HTTPS (`https://devbox.TAILNET.ts.net`) instead of plain HTTP. A tailnet IP in `100.64.0.0/10` is not a LAN address. Prefer the MagicDNS name with the `ts.net` exception, or Serve HTTPS, over a raw `100.x` URL.

### Grants

Grants are deny-by-default and additive. A default allow-all policy still allows every port. Narrow it if the restriction should apply. Tag the devbox `tag:chunky-devbox` and allow only your Macs to the worker port (8080 for plain HTTP, 443 if you also use Serve):

```json
{
  "tagOwners": {
    "tag:chunky-devbox": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:chunky-devbox"],
      "ip": ["tcp:8080"]
    }
  ]
}
```

Replace `autogroup:member` with specific users or tagged Macs if the tailnet is shared. Grant `tcp:443` as well when you use Serve HTTPS.

### curl over the tailnet

```bash
tailscale ping devbox
tailscale status
curl -sS "http://devbox:8080/v1/health"
curl -sS -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"quarterly revenue","collection":"documents","limit":5,"qdrant_url":"https://QDRANT_CLOUD_HOST","qdrant_api_key":"QDRANT_API_KEY"}' \
  "http://devbox:8080/v1/search"
```

If Serve HTTPS is on:

```bash
curl -sS "https://devbox.TAILNET.ts.net/v1/health"
curl -sS -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"quarterly revenue","collection":"documents","limit":5,"qdrant_url":"https://QDRANT_CLOUD_HOST","qdrant_api_key":"QDRANT_API_KEY"}' \
  "https://devbox.TAILNET.ts.net/v1/search"
```

In the app, the Tailscale profile uses that URL and the same bearer token.

### Large PDFs and DERP

`POST /v1/jobs` sends the whole file, then streams progress. On the same Wi-Fi LAN, Tailscale usually switches to a direct path. A DERP relay is a shared, rate-limited fallback and can stall a large PDF.

Check `tailscale ping devbox` and `tailscale status`. **via DERP** means relayed. A peer address means direct. If you are at home and the path is relayed, switch the app to the LAN profile. Do not wait on Tailscale for that upload.

## Profiles to keep

Preferences, Documents, saves these named worker endpoints. Fill in the URL and token, then Use and Check reachability:

| Profile | Typical URL | When to use |
| --- | --- | --- |
| Mac Studio 10GbE | `http://DEVBOX_10GBE_IP:8080` | Desk ingest. Fastest path |
| Wi-Fi LAN | `http://DEVBOX_LAN_IP:8080` or `http://HOSTNAME.local:8080` | Same LAN. Use this when Tailscale is via DERP |
| Tailscale | `http://devbox:8080` or `https://devbox.TAILNET.ts.net` | Stable name, or you are off the LAN |

The same token is used for all three. Selecting a profile only fills the form. Use is what the next upload calls, and what Retrieval calls when Devbox ingest is Qdrant Cloud. Check reachability uses the form fields and shows latency. A result from an older check is dropped when the URL or token changes.

Retrieval searches through the active profile in that Cloud case, including hybrid dense plus BM25 with RRF. Local Docker ingest still searches the Qdrant URL on the Mac. Rerank, Eval, and citation chat run in the app. The worker URL is only an HTTP base URL. There is no Tailscale SDK in the app.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Test Connection times out | Bind is loopback or the 10GbE NIC only. `ufw` denies the MacBook. Wrong IP. Tailscale is down |
| HTTP 401 on `/v1/search` or `/v1/models` | The Keychain token does not match `CHUNKY_WORKER_TOKEN` or the token file |
| `/v1/health` works, jobs fail | Token first, then vLLM and Ollama on loopback (`CHUNKY_VLLM_URL`, `CHUNKY_OLLAMA_URL`) |
| ATS error | HTTP to a name that is not a LAN host. Use the LAN profile, the `ts.net` exception, or Serve HTTPS |
| MagicDNS name does not resolve | MagicDNS is off. `host` or `nslookup` was used instead of `curl` or `ping`. Tailscale is not connected |
| Slow or stalled PDF upload | `tailscale status` shows DERP. Switch to the LAN profile |
| Studio works, MacBook does not | The worker is bound only to the 10GbE address |
| Ollama or granite answers from the laptop | Those servers must stay on devbox loopback. Only port 8080 should be reachable |

## Sources

- [MagicDNS](https://tailscale.com/docs/features/magicdns)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [tailscale serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [ACLs and grants](https://tailscale.com/docs/features/access-control/acls)
- [macOS client variants](https://tailscale.com/docs/concepts/macos-variants)
- [Install Tailscale on macOS](https://tailscale.com/docs/install/mac)
- [Install Tailscale on Linux](https://tailscale.com/docs/install/linux)
- [Connection types](https://tailscale.com/docs/reference/connection-types)
- [Poor performance](https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet)
- [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
