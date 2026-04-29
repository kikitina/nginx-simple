# nginx-simple

A minimal Docker Compose stack:

- **nginx** on port `8888` with a `204` response on `/generate_204` (always on).
- Optional **proxy services**: sing-box (hysteria2) + xray (VLESS+Reality+Vision), gated behind a Compose `proxy` profile.

## Prerequisites

1. **Install Docker Engine + Compose plugin** on Ubuntu by following the official guide: <https://docs.docker.com/engine/install/ubuntu/>
2. **Clone this repo:**

   ```bash
   git clone https://github.com/kikitina/nginx-simple.git
   cd nginx-simple
   ```

## Run nginx

```bash
docker compose up -d
```

Verify:

```bash
curl -i http://localhost:8888/generate_204
```

## Add proxy services (sing-box hysteria2 + xray VLESS+Reality+Vision)

```bash
bash setup-proxy.sh
```

The script will prompt for:

- **Subdomain FQDN** (e.g., `proxy.example.com`) — must be a subdomain, not the apex (`example.com`).
- **Cloudflare API token** — scoped to `Zone:Read` + `DNS:Edit` on the relevant zone.
- **Hysteria2 UDP port** (default 443).
- **Reality TCP port** (default 443).
- **Reality target** (default `www.microsoft.com:443`) — pick from <https://www.v2ray-agent.com/archives/1680104902581>. Must support TLS 1.3 + X25519 + h2.

Everything else (UUID, Reality x25519 keypair, short ID, hysteria2 password) is auto-generated. Configs are written to `sing-box/config.json` and `xray/config.json` and bind-mounted into the containers, so they persist across restarts.

### Prerequisites

- A DNS A (and optionally AAAA) record for the subdomain pointing at this VPS.
- UDP/443 (or your chosen `HY2_PORT`) and TCP/443 (or your chosen `REALITY_PORT`) open in the firewall.
- A Cloudflare API token with `Zone:Read` + `DNS:Edit` permissions on the zone.

### TLS cert

The cert is issued via [acme.sh](https://github.com/acmesh-official/acme.sh) running inside a `simple-acme` container, using Cloudflare DNS-01 — only for the subdomain you provided (no apex, no wildcard). Renewal is handled by the same container in daemon mode (no host cron). On a successful renewal, sing-box is restarted automatically via the mounted Docker socket.

Reality does not use a cert — it borrows the TLS handshake from the chosen target SNI.

### After setup

The script prints two share links you can import into NekoBox / v2rayN / Hiddify. Re-running `bash setup-proxy.sh` is a no-op that reprints the links. To regenerate all secrets (and invalidate existing clients):

```bash
bash setup-proxy.sh --force
```

### Env files

The bootstrap writes two env files in the repo root (both `chmod 600`, gitignored):

- `.env` — read by `docker compose` for the port and CF token vars. See `.env.example`.
- `.proxy.env` — full state including generated secrets, sourced by re-runs of `setup-proxy.sh` to reprint share links. See `.proxy.env.example`.

You usually do not need to edit these by hand — re-run `setup-proxy.sh --force` to regenerate. Two exceptions where editing `.env` and re-running `bash setup-proxy.sh` (no `--force`) is enough:

- **`REALITY_DEST`** — change to a different SNI from <https://www.v2ray-agent.com/archives/1680104902581>; the script detects the diff, re-renders `xray/config.json`, and restarts xray. Existing client share links remain valid (only the impersonated SNI changes; clients also need to be updated to the new SNI).
- **`HY2_PORT` / `REALITY_PORT` / `CF_TOKEN`** — re-apply with `docker compose --profile proxy up -d`.

### Operating

- View acme logs: `docker logs simple-acme`
- Force a renewal test: `docker exec simple-acme acme.sh --renew -d <DOMAIN> --ecc --force`
- List managed certs: `docker exec simple-acme acme.sh --list`
- Restart a service after editing its config: `docker compose --profile proxy restart sing-box` (or `xray`)
- Bring everything down: `docker compose --profile proxy down`

### Notes

- Proxy services are gated behind a Compose `proxy` profile, so plain `docker compose up -d` still starts only nginx.
- Mounting `/var/run/docker.sock` into the acme container is effectively root on the host. Acceptable for a single-tenant personal VPS.
- Port mappings default to IPv4 (`0.0.0.0`). For IPv6, change the compose port lines to `[::]:443:443/udp` etc.
- Image tags are `:latest`. To upgrade: `docker compose --profile proxy pull && docker compose --profile proxy up -d`.
