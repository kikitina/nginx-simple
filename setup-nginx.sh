#!/usr/bin/env bash

set -Eeuo pipefail

REPO_OWNER="kikitina"
REPO_NAME="nginx-simple"
REPO_BRANCH="main"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/${REPO_NAME}}"

log() {
  printf '[setup-nginx] %s\n' "$*"
}

fail() {
  printf '[setup-nginx] ERROR: %s\n' "$*" >&2
  exit 1
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "This installer only supports Ubuntu."

  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || fail "Detected '${ID:-unknown}'. This installer only supports Ubuntu."
}

configure_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
    return
  fi

  command -v sudo >/dev/null 2>&1 || fail "sudo is required to install Docker and start the service."
  SUDO="sudo"
}

ensure_download_tools() {
  if command -v curl >/dev/null 2>&1; then
    return
  fi

  log "Installing curl so the bootstrap files can be downloaded."
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl
}

remove_conflicting_packages() {
  local packages=()
  local package

  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "install ok installed"; then
      packages+=("${package}")
    fi
  done

  if ((${#packages[@]} == 0)); then
    return
  fi

  log "Removing conflicting packages: ${packages[*]}"
  ${SUDO} apt-get remove -y "${packages[@]}"
}

install_docker() {
  local arch
  local codename

  log "Installing Docker Engine from Docker's apt repository."
  remove_conflicting_packages

  ${SUDO} apt-get update
  ${SUDO} apt-get install -y ca-certificates curl
  ${SUDO} install -m 0755 -d /etc/apt/keyrings
  ${SUDO} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc

  arch="$(dpkg --print-architecture)"

  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

  ${SUDO} tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  ${SUDO} apt-get update
  ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker Engine and docker compose are already installed."
    return
  fi

  install_docker
}

ensure_docker_running() {
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker; then
      log "Starting Docker service."
      ${SUDO} systemctl enable --now docker
    fi
    return
  fi

  if command -v service >/dev/null 2>&1; then
    log "Starting Docker service."
    ${SUDO} service docker start
    return
  fi

  fail "Unable to start Docker automatically because neither systemctl nor service is available."
}

configure_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    return
  fi

  DOCKER_CMD=(${SUDO} docker)
}

download_project_files() {
  log "Downloading project files into ${INSTALL_DIR}."
  mkdir -p "${INSTALL_DIR}/nginx/conf.d"

  curl -fsSL "${RAW_BASE_URL}/docker-compose.yml" -o "${INSTALL_DIR}/docker-compose.yml"
  curl -fsSL "${RAW_BASE_URL}/nginx/conf.d/default.conf" -o "${INSTALL_DIR}/nginx/conf.d/default.conf"
}

resolve_project_dir() {
  local script_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [[ -f "${script_dir}/docker-compose.yml" && -f "${script_dir}/nginx/conf.d/default.conf" ]]; then
    PROJECT_DIR="${script_dir}"
    log "Using local project files from ${PROJECT_DIR}."
    return
  fi

  ensure_download_tools
  PROJECT_DIR="${INSTALL_DIR}"
  download_project_files
}

launch_nginx() {
  log "Launching nginx with docker compose."
  "${DOCKER_CMD[@]}" compose -f "${PROJECT_DIR}/docker-compose.yml" up -d
}

verify_launch() {
  log "Current container status:"
  "${DOCKER_CMD[@]}" compose -f "${PROJECT_DIR}/docker-compose.yml" ps
  log "nginx should now be reachable at http://localhost:8888/generate_204"
}

main() {
  require_ubuntu
  configure_sudo
  resolve_project_dir
  ensure_docker_installed
  ensure_docker_running
  configure_docker_command
  launch_nginx
  verify_launch
}

main "$@"
