# nginx-simple

A minimal Docker Compose stack:

- **nginx** on port `8888` with a `204` response on `/generate_204` (always on).
- Optional **proxy services**: sing-box (hysteria2 + AnyTLS) + xray (VLESS+Reality+Vision), gated behind a Compose `proxy` profile.

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

## Add proxy services (sing-box hysteria2 + AnyTLS + xray VLESS+Reality+Vision)

```bash
bash setup-proxy.sh
```

The script will prompt for:

- **Subdomain FQDN** (e.g., `proxy.example.com`) — must be a subdomain, not the apex (`example.com`).
- **Cloudflare API token** — scoped to `Zone:Read` + `DNS:Edit` on the relevant zone.
- **Hysteria2 UDP port** (default 443).
- **AnyTLS TCP port** (default 8443) — must differ from the Reality TCP port.
- **Reality TCP port** (default 443).
- **Reality target** (default `www.microsoft.com:443`) — must support TLS 1.3 + X25519 + h2. The default is a convenience value, not a long-term recommendation; for better Reality camouflage, scan/select a less-common target near the VPS instead of blindly using popular examples.

Everything else (UUID, Reality x25519 keypair, short ID, hysteria2 password, AnyTLS password) is auto-generated. Configs are written to `sing-box/config.json` and `xray/config.json` and bind-mounted into the containers, so they persist across restarts. AnyTLS requires sing-box `1.12.0` or newer; the Compose stack uses `ghcr.io/sagernet/sing-box:latest`.

### Prerequisites

- A DNS A (and optionally AAAA) record for the subdomain pointing at this VPS.
- UDP/443 (or your chosen `HY2_PORT`), TCP/8443 (or your chosen `ANYTLS_PORT`), and TCP/443 (or your chosen `REALITY_PORT`) open in the firewall.
- A Cloudflare API token with `Zone:Read` + `DNS:Edit` permissions on the zone.

### TLS cert

The cert is issued via [acme.sh](https://github.com/acmesh-official/acme.sh) running inside a `simple-acme` container, using Cloudflare DNS-01 — only for the subdomain you provided (no apex, no wildcard). Renewal is handled by the same container in daemon mode (no host cron). On a successful renewal, sing-box is restarted automatically via the mounted Docker socket.

AnyTLS uses the issued cert. Reality does not use a cert — it borrows the TLS handshake from the chosen target SNI.

This stack uses certificate-based AnyTLS on its own TCP port plus a separate xray Reality service. Some guides run AnyTLS directly inside sing-box Reality on `443/tcp` to avoid a domain/cert and put the whole TCP proxy behind Reality. That is a different topology: it would replace or move the existing xray Reality service because both need the same TCP port.

### After setup

The script prints Hysteria2 and Reality share links, an AnyTLS URI, and an AnyTLS sing-box outbound snippet. Re-running `bash setup-proxy.sh` is a no-op that reprints the links/config. To regenerate all secrets (and invalidate existing clients):

```bash
bash setup-proxy.sh --force
```

AnyTLS client import support varies by app. The generic AnyTLS URI covers the basic password, host, port, and SNI fields; sing-box documents AnyTLS as JSON outbound config, so the script also prints a ready-to-copy outbound object.

### Env files

The bootstrap writes two env files in the repo root (both `chmod 600`, gitignored):

- `.env` — read by `docker compose` for the port and CF token vars. See `.env.example`.
- `.proxy.env` — full state including generated secrets, sourced by re-runs of `setup-proxy.sh` to reprint share links. See `.proxy.env.example`.

You usually do not need to edit these by hand — re-run `setup-proxy.sh --force` to regenerate. Two exceptions where editing `.env` and re-running `bash setup-proxy.sh` (no `--force`) is enough:

- **`REALITY_DEST`** — change to a different SNI target; the script detects the diff, re-renders `xray/config.json`, and restarts xray. Existing client share links remain valid (only the impersonated SNI changes; clients also need to be updated to the new SNI).
- **`HY2_PORT` / `ANYTLS_PORT` / `REALITY_PORT` / `CF_TOKEN`** — re-apply with `docker compose --profile proxy up -d`.

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
