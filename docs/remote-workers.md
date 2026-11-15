# Reach a worker from the app

The app does not embed a VPN client. A worker is a base URL and a bearer token. Save one profile per path, press Use, then Check reachability. Topologies are in [worker-use-cases.md](worker-use-cases.md). Installing the worker is in [worker-host.md](worker-host.md).

Do not commit addresses or the token.

## Same LAN

The app machine and the worker must share a network, wired or Wi-Fi. The worker must listen on an address that network can reach, not only on loopback.

1. Note the worker's LAN IPv4. A DHCP reservation keeps it stable.
2. `http://HOSTNAME.local:8080` works when mDNS is reliable. Otherwise use the reserved IPv4.
3. Allow TCP 8080 from the app machine. Example:

```bash
sudo ufw allow from APP_MACHINE_IP to WORKER_IP port 8080 proto tcp
sudo ufw deny 8080/tcp
```

4. In the app: Processing host **Devbox**, worker URL `http://WORKER_IP:8080` or `http://HOSTNAME.local:8080`, paste the token, then Check reachability.

Plain HTTP to a private LAN address is allowed by `NSAllowsLocalNetworking`.

```bash
curl -sS "http://WORKER_IP:8080/v1/health"
curl -sS -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"query":"quarterly revenue","collection":"documents","limit":5,"qdrant_url":"https://QDRANT_HOST","qdrant_api_key":"QDRANT_API_KEY"}' \
  "http://WORKER_IP:8080/v1/search"
```

A timeout is bind, firewall, or the wrong address. HTTP 401 is a token mismatch.

## VPN or Tailscale

Use the standalone Tailscale client on the app machine, not the App Store build. Install Tailscale on the worker as well. Turn MagicDNS on. The app still only stores a URL.

Bind the worker to `tailscale ip -4` when only the tailnet should connect, or to `0.0.0.0` when the LAN must connect too. A non-loopback bind requires a token.

MagicDNS: `http://worker:8080` if the node is named `worker`. The longer name is `http://worker.TAILNET.ts.net:8080`. Check it with `ping` or `curl`. `host` and `nslookup` on macOS can skip system DNS.

`tailscale serve` can terminate HTTPS and forward to loopback:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:8080
```

That requires the worker to listen on `127.0.0.1` or `0.0.0.0`. A tailnet-only bind will not receive the forward. Do not use Funnel. The worker stays private.

`NSAllowsLocalNetworking` does not cover `*.ts.net`. The app plist allows insecure HTTP for `ts.net` and its subdomains. A `100.64.0.0/10` address is not a LAN address. Prefer the MagicDNS name or Serve HTTPS.

If `tailscale status` says the peer is **via DERP**, large uploads go through a shared relay. Prefer the LAN profile when you are on the same network.

Example grant, so only your tailnet can open the worker port:

```json
{
  "tagOwners": {
    "tag:chunky-worker": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:chunky-worker"],
      "ip": ["tcp:8080"]
    }
  ]
}
```

Use `tcp:443` as well if you enable Serve HTTPS.

```bash
tailscale ping worker
curl -sS "http://worker:8080/v1/health"
curl -sS -H "Authorization: Bearer TOKEN" "http://worker:8080/v1/models"
```

## Profiles

The app starts with Wired LAN, Wi-Fi, and Tailscale. Fill in the URL and token. Selecting a profile only edits the form. Use applies it to the next upload, and to Retrieval when Devbox ingest is Qdrant Cloud.

| Profile | Typical URL | When |
| --- | --- | --- |
| Wired LAN | `http://WORKER_IP:8080` | Same switched network. Usually the fastest path |
| Wi-Fi | `http://WORKER_IP:8080` or `http://HOSTNAME.local:8080` | Same LAN over wireless. Prefer this when the VPN path is relayed |
| Tailscale | `http://worker:8080` or `https://worker.TAILNET.ts.net` | Off the LAN, or you want one stable name |

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Check reachability times out | Bind is loopback or a different NIC. The firewall denies the app machine. Wrong address. The VPN is down |
| HTTP 401 | The Keychain token does not match `CHUNKY_WORKER_TOKEN` or the token file |
| `/v1/health` works, jobs fail | Token first, then vLLM and Ollama on worker loopback |
| ATS error | HTTP to a name that is not a LAN host. Use a LAN address, the `ts.net` exception, or Serve HTTPS |
| MagicDNS does not resolve | MagicDNS is off, or the VPN is disconnected |
| Slow upload | The VPN path is relayed. Switch to the LAN profile |
| One path works and another does not | The worker is bound to only one of those addresses |
| Ollama or granite answers from the app machine | Those servers must stay on worker loopback. Only port 8080 should be reachable |
