#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROXY_ENV_FILE="${SCRIPT_DIR}/.proxy.env"
COMPOSE_ENV_FILE="${SCRIPT_DIR}/.env"
SINGBOX_CONFIG="${SCRIPT_DIR}/sing-box/config.json"
XRAY_CONFIG="${SCRIPT_DIR}/xray/config.json"

XRAY_IMAGE="teddysun/xray:latest"
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:latest"
ACME_IMAGE="neilpang/acme.sh:latest"

FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--force]

Bootstraps sing-box (hysteria2) and xray (VLESS+Reality+Vision) on top of the
existing nginx Docker Compose stack. On first run, prompts for domain and
Cloudflare API token, generates secrets, issues a TLS cert via acme.sh+DNS-01,
and brings up the proxy services.

Re-running with no flags is a no-op that reprints the share links.
--force regenerates all secrets (invalidates existing clients).
USAGE
      exit 0 ;;
    *) echo "Unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

log() { printf '[setup-proxy] %s\n' "$*"; }
fail() { printf '[setup-proxy] ERROR: %s\n' "$*" >&2; exit 1; }

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "This installer only supports Ubuntu."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "Detected '${ID:-unknown}'. Ubuntu only."
}

configure_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then SUDO=""; return; fi
  command -v sudo >/dev/null 2>&1 || fail "sudo is required."
  SUDO="sudo"
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    fail "Docker (with the compose plugin) is not installed. See https://docs.docker.com/engine/install/ubuntu/"
  fi
  if ! docker info >/dev/null 2>&1; then
    if ${SUDO} docker info >/dev/null 2>&1; then
      DOCKER_PREFIX=(${SUDO})
    else
      fail "Cannot run docker. Is the daemon running?"
    fi
  else
    DOCKER_PREFIX=()
  fi
}

dc() { "${DOCKER_PREFIX[@]}" docker compose --profile proxy "$@"; }
d()  { "${DOCKER_PREFIX[@]}" docker "$@"; }

require_openssl() {
  command -v openssl >/dev/null 2>&1 || fail "openssl is required (apt-get install openssl)."
}

print_share_links() {
  cat <<LINKS

================================================================
Share links (import into NekoBox / v2rayN / Hiddify):

Hysteria2:
  hysteria2://${HY2_PASS}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}&alpn=h3&obfs=salamander&obfs-password=${HY2_OBFS_PASS}#hy2-${DOMAIN}

VLESS + Reality + Vision:
  vless://${UUID}@${DOMAIN}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#reality-${DOMAIN}

Secrets are persisted in ${PROXY_ENV_FILE} (mode 600).
================================================================
LINKS
}

already_bootstrapped() {
  [[ -f "${PROXY_ENV_FILE}" && -f "${SINGBOX_CONFIG}" && -f "${XRAY_CONFIG}" ]]
}

prompt_inputs() {
  log "Collecting configuration."

  while :; do
    read -r -p "Subdomain FQDN (e.g., proxy.example.com): " DOMAIN
    DOMAIN="${DOMAIN,,}"
    if [[ ! "${DOMAIN}" =~ ^[a-z0-9-]+(\.[a-z0-9-]+){2,}$ ]]; then
      echo "  Must be at least 3 dot-separated labels (subdomain.domain.tld)." >&2
      continue
    fi
    break
  done
  log "Using domain: ${DOMAIN}"
  log "NOTE: cert will be issued ONLY for ${DOMAIN} (no apex, no wildcard)."

  while :; do
    read -r -p "Cloudflare API Token (Zone:Read + DNS:Edit on the zone): " CF_TOKEN
    [[ -n "${CF_TOKEN}" ]] && break
    echo "  Token cannot be empty." >&2
  done

  read -r -p "Hysteria2 UDP port [443]: " HY2_PORT
  HY2_PORT="${HY2_PORT:-443}"

  read -r -p "Reality TCP port [443]: " REALITY_PORT
  REALITY_PORT="${REALITY_PORT:-443}"

  read -r -p "Reality target host:port [www.microsoft.com:443]
  (pick one from https://www.v2ray-agent.com/archives/1680104902581 — must support TLS 1.3 + X25519 + h2): " REALITY_DEST
  REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"
  REALITY_SNI="${REALITY_DEST%%:*}"
}

preflight() {
  log "Pre-flight checks."

  if command -v ss >/dev/null 2>&1; then
    if ${SUDO} ss -lntu "( sport = :${HY2_PORT} )" 2>/dev/null | tail -n +2 | grep -qE 'udp.*:'"${HY2_PORT}"'\b'; then
      fail "UDP port ${HY2_PORT} is already in use."
    fi
    if ${SUDO} ss -lntu "( sport = :${REALITY_PORT} )" 2>/dev/null | tail -n +2 | grep -qE 'tcp.*:'"${REALITY_PORT}"'\b'; then
      fail "TCP port ${REALITY_PORT} is already in use."
    fi
  else
    log "ss not found; skipping port check."
  fi

  if command -v dig >/dev/null 2>&1; then
    local resolved
    resolved="$(dig +short "${DOMAIN}" | head -n1)"
    if [[ -z "${resolved}" ]]; then
      log "WARNING: ${DOMAIN} does not resolve. DNS-01 issuance will still work,"
      log "         but clients won't reach the server until the A/AAAA record is set."
    else
      log "${DOMAIN} resolves to ${resolved}."
    fi
  fi
}

generate_secrets() {
  log "Generating secrets (UUID, Reality keypair, short ID, hy2 password)."
  d pull "${XRAY_IMAGE}" >/dev/null

  UUID="$(d run --rm "${XRAY_IMAGE}" xray uuid | tr -d '\r\n')"
  [[ -n "${UUID}" ]] || fail "Failed to generate UUID."

  local x25519_out
  x25519_out="$(d run --rm "${XRAY_IMAGE}" xray x25519)"
  # Newer xray prints: "PrivateKey: <key>" and "Password (PublicKey): <key>"
  REALITY_PRIV="$(echo "${x25519_out}" | awk '/^PrivateKey:/ {print $2; exit}' | tr -d '\r')"
  REALITY_PUB="$(echo "${x25519_out}"  | awk '/^Password/    {print $NF; exit}' | tr -d '\r')"
  [[ -n "${REALITY_PRIV}" && -n "${REALITY_PUB}" ]] || fail "Failed to parse x25519 keypair. Raw output: ${x25519_out}"

  SHORT_ID="$(openssl rand -hex 8)"
  HY2_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  HY2_OBFS_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
}

write_env_files() {
  log "Writing ${COMPOSE_ENV_FILE} and ${PROXY_ENV_FILE}."

  umask 077
  cat >"${COMPOSE_ENV_FILE}" <<ENV
HY2_PORT=${HY2_PORT}
REALITY_PORT=${REALITY_PORT}
DOMAIN=${DOMAIN}
CF_TOKEN=${CF_TOKEN}
REALITY_DEST=${REALITY_DEST}
ENV

  cat >"${PROXY_ENV_FILE}" <<ENV
DOMAIN=${DOMAIN}
CF_TOKEN=${CF_TOKEN}
HY2_PORT=${HY2_PORT}
REALITY_PORT=${REALITY_PORT}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
UUID=${UUID}
REALITY_PRIV=${REALITY_PRIV}
REALITY_PUB=${REALITY_PUB}
SHORT_ID=${SHORT_ID}
HY2_PASS=${HY2_PASS}
HY2_OBFS_PASS=${HY2_OBFS_PASS}
ENV
  chmod 600 "${COMPOSE_ENV_FILE}" "${PROXY_ENV_FILE}"
}

render_configs() {
  log "Rendering sing-box and xray configs."
  mkdir -p "${SCRIPT_DIR}/sing-box" "${SCRIPT_DIR}/xray" "${SCRIPT_DIR}/certs" "${SCRIPT_DIR}/acme"

  cat >"${SINGBOX_CONFIG}" <<JSON
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{"name": "u1", "password": "${HY2_PASS}"}],
      "up_mbps": 100,
      "down_mbps": 500,
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASS}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "alpn": ["h3"],
        "certificate_path": "/certs/${DOMAIN}.crt",
        "key_path": "/certs/${DOMAIN}.key"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
JSON

  cat >"${XRAY_CONFIG}" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
JSON
}

issue_cert() {
  log "Starting acme container and issuing cert for ${DOMAIN}."
  d pull "${ACME_IMAGE}" >/dev/null
  dc up -d acme

  # Wait briefly for container to be ready.
  for _ in 1 2 3 4 5; do
    d exec simple-acme true >/dev/null 2>&1 && break
    sleep 1
  done

  log "Installing docker-cli inside acme container (for renewal reload hook)."
  d exec simple-acme apk add --no-cache docker-cli >/dev/null

  d exec simple-acme acme.sh --set-default-ca --server letsencrypt >/dev/null
  # Best-effort account registration (no-op if already registered).
  d exec simple-acme acme.sh --register-account -m "admin@${DOMAIN}" >/dev/null 2>&1 || true

  if d exec simple-acme test -d "/acme.sh/${DOMAIN}_ecc"; then
    log "Cert for ${DOMAIN} already exists in acme state; skipping --issue."
  else
    log "Issuing cert via Cloudflare DNS-01 (this may take ~30-60s)."
    d exec simple-acme acme.sh --issue -d "${DOMAIN}" --dns dns_cf -k ec-256
  fi

  log "Installing cert to /certs and registering reload hook."
  d exec simple-acme acme.sh --installcert -d "${DOMAIN}" \
    --fullchainpath "/certs/${DOMAIN}.crt" \
    --keypath       "/certs/${DOMAIN}.key" \
    --ecc \
    --reloadcmd "docker restart simple-sing-box 2>/dev/null || true"

  ${SUDO} chmod 644 "${SCRIPT_DIR}/certs/${DOMAIN}.crt"
  ${SUDO} chmod 640 "${SCRIPT_DIR}/certs/${DOMAIN}.key"
}

start_services() {
  log "Starting nginx, sing-box, and xray."
  dc up -d nginx sing-box xray
}

main() {
  require_ubuntu
  configure_sudo
  require_docker
  require_openssl

  if already_bootstrapped && [[ "${FORCE}" -ne 1 ]]; then
    log "Already bootstrapped (.proxy.env and configs present)."
    log "Re-run with --force to regenerate secrets (invalidates clients)."
    # shellcheck disable=SC1090
    . "${PROXY_ENV_FILE}"
    local needs_rerender=0
    # Migration: older installs lack HY2_OBFS_PASS.
    if [[ -z "${HY2_OBFS_PASS:-}" ]]; then
      log "Migrating: adding hysteria2 salamander obfs (generating HY2_OBFS_PASS)."
      HY2_OBFS_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
      printf 'HY2_OBFS_PASS=%s\n' "${HY2_OBFS_PASS}" >>"${PROXY_ENV_FILE}"
      needs_rerender=1
    fi
    # Honor edits to .env: if REALITY_DEST changed, re-render xray config and restart.
    if [[ -f "${COMPOSE_ENV_FILE}" ]]; then
      local env_dest
      env_dest="$(grep -E '^REALITY_DEST=' "${COMPOSE_ENV_FILE}" | tail -n1 | cut -d= -f2-)"
      if [[ -n "${env_dest}" && "${env_dest}" != "${REALITY_DEST}" ]]; then
        log "REALITY_DEST in .env (${env_dest}) differs from .proxy.env (${REALITY_DEST}); re-rendering xray config."
        REALITY_DEST="${env_dest}"
        REALITY_SNI="${REALITY_DEST%%:*}"
        sed -i "s|^REALITY_DEST=.*|REALITY_DEST=${REALITY_DEST}|; s|^REALITY_SNI=.*|REALITY_SNI=${REALITY_SNI}|" "${PROXY_ENV_FILE}"
        needs_rerender=1
      fi
    fi
    # Always re-render to pick up template changes (e.g. tightened shortIds, obfs).
    render_configs
    start_services
    if [[ "${needs_rerender}" -eq 1 ]]; then
      log "Restarting sing-box and xray to apply config changes."
      dc restart sing-box xray
    fi
    print_share_links
    exit 0
  fi

  if [[ "${FORCE}" -eq 1 ]] && already_bootstrapped; then
    log "WARNING: --force will regenerate all secrets and invalidate existing clients."
    read -r -p "Type 'yes' to continue: " confirm
    [[ "${confirm}" == "yes" ]] || fail "Aborted."
  fi

  prompt_inputs
  preflight
  generate_secrets
  write_env_files
  render_configs
  issue_cert
  start_services

  log "Done."
  print_share_links
}

main "$@"
