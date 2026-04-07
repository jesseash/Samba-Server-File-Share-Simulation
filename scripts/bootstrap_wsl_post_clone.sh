#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  echo "[bootstrap] $*"
}

fail() {
  echo "[bootstrap][error] $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "Run this script as root inside WSL."
  fi
}

ensure_systemd() {
  if [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" != "systemd" ]]; then
    fail "systemd is not active in this WSL distro. Re-run the PowerShell installer after it enables systemd and restarts WSL."
  fi
}

install_packages() {
  log "Installing Ubuntu dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    docker.io \
    git \
    gnupg \
    jq \
    lsb-release \
    rsync \
    sudo \
    tar \
    wget
}

get_primary_user() {
  local user_name

  user_name="$(getent passwd 1000 | cut -d: -f1 || true)"
  if [[ -n "${user_name}" ]]; then
    echo "${user_name}"
    return 0
  fi

  echo "root"
}

configure_docker() {
  local primary_user

  primary_user="$(get_primary_user)"
  log "Enabling Docker service"
  systemctl enable --now docker

  if [[ "${primary_user}" != "root" ]] && id -u "${primary_user}" >/dev/null 2>&1; then
    log "Adding ${primary_user} to docker group"
    usermod -aG docker "${primary_user}"
  fi
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log "k3s already installed"
  else
    log "Installing k3s"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
  fi

  log "Enabling k3s service"
  systemctl enable --now k3s
}

wait_for_k3s() {
  local timeout=180
  local start

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  start="$(date +%s)"

  log "Waiting for k3s to become ready"
  until kubectl get nodes >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then
      fail "k3s did not become ready within ${timeout} seconds"
    fi
    sleep 2
  done

  kubectl get nodes -o wide
}

run_repo_bootstrap() {
  cd "${REPO_ROOT}"

  log "Downloading dependency archive and populating repo"
  bash scripts/download-repo.sh

  log "Building server image"
  bash server/rebuild-server.sh

  log "Building client image"
  bash client/rebuild-client.sh
}

main() {
  require_root
  ensure_systemd
  install_packages
  configure_docker
  install_k3s
  wait_for_k3s
  run_repo_bootstrap
  log "WSL post-clone bootstrap complete"
}

main "$@"
