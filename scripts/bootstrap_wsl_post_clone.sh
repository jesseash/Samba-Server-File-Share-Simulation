#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${REPO_ROOT}/k8s"
NAMESPACE="${NAMESPACE:-default}"

log() {
  echo "[bootstrap] $*"
}

fail() {
  echo "[bootstrap][error] $*" >&2
  exit 1
}

run_with_timeout() {
  local timeout_secs="$1"
  local description="$2"
  shift 2

  log "${description} (timeout: ${timeout_secs}s)"
  timeout --foreground "${timeout_secs}" "$@"
  local exit_code=$?

  if [[ "${exit_code}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${exit_code}" -eq 124 || "${exit_code}" -eq 137 ]]; then
    fail "${description} timed out after ${timeout_secs}s"
  fi
  fail "${description} failed with exit code ${exit_code}"
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
  run_with_timeout 1200 "apt-get update" apt-get update
  run_with_timeout 1800 "apt-get install dependencies" apt-get install -y \
    ca-certificates \
    curl \
    docker.io \
    dpkg-dev \
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
  run_with_timeout 180 "Enable Docker service" systemctl enable --now docker

  if [[ "${primary_user}" != "root" ]] && id -u "${primary_user}" >/dev/null 2>&1; then
    log "Adding ${primary_user} to docker group"
    usermod -aG docker "${primary_user}"
  fi
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log "k3s already installed"
  else
    run_with_timeout 1800 "Install k3s" bash -lc 'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -'
  fi

  run_with_timeout 300 "Enable k3s service" systemctl enable --now k3s
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

fix_kubeconfig_server_endpoint() {
  local kubeconfig="/etc/rancher/k3s/k3s.yaml"

  [[ -f "${kubeconfig}" ]] || return 0

  # Ensure kubeconfig is world-readable so the primary WSL user can run kubectl
  chmod 644 "${kubeconfig}"
  log "kubeconfig permissions set to 644: ${kubeconfig}"
  # Windows-side kubeconfig and port-proxy setup is handled by post_clone_windows_setup.ps1
}

run_repo_bootstrap() {
  cd "${REPO_ROOT}"

  run_with_timeout 1800 "Download dependency archive and populate repo" bash scripts/download-repo.sh

  run_with_timeout 7200 "Build server image" bash server/rebuild-server.sh

  run_with_timeout 7200 "Build client image" bash client/rebuild-client.sh
}

apply_k8s_manifests_and_verify_backend() {
  log "Applying Kubernetes manifests required for service connectivity"

  local required_manifests=(
    "${K8S_DIR}/pvc.yaml"
    "${K8S_DIR}/samba-config.yaml"
    "${K8S_DIR}/samba-service.yaml"
    "${K8S_DIR}/samba-deployment.yaml"
    "${K8S_DIR}/clients-deployment.yaml"
  )

  local manifest
  for manifest in "${required_manifests[@]}"; do
    [[ -f "${manifest}" ]] || fail "Required manifest not found: ${manifest}"
    run_with_timeout 120 "Apply $(basename "${manifest}")" kubectl -n "${NAMESPACE}" apply -f "${manifest}"
  done

  run_with_timeout 300 "Wait for samba rollout" kubectl -n "${NAMESPACE}" rollout status deployment/samba --timeout=300s
  run_with_timeout 360 "Wait for samba-users rollout" kubectl -n "${NAMESPACE}" rollout status deployment/samba-users --timeout=360s

  local samba_pod
  samba_pod="$(kubectl -n "${NAMESPACE}" get pods -l app=samba --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${samba_pod}" ]] || fail "Could not find a running samba pod in namespace '${NAMESPACE}'"

  run_with_timeout 60 "Ensure samba share path exists on PVC" \
    kubectl -n "${NAMESPACE}" exec "${samba_pod}" -- sh -c 'mkdir -p /data/samba && chown -R simadmin:simadmin /data/samba && ls -ld /data /data/samba'

  run_with_timeout 120 "Restart samba-users after samba path repair" kubectl -n "${NAMESPACE}" rollout restart deployment/samba-users
  run_with_timeout 360 "Wait for samba-users rollout after restart" kubectl -n "${NAMESPACE}" rollout status deployment/samba-users --timeout=360s

  run_with_timeout 60 "Validate samba service exists" kubectl -n "${NAMESPACE}" get svc samba

  local endpoint_count
  endpoint_count="$(kubectl -n "${NAMESPACE}" get endpointslice -l kubernetes.io/service-name=samba -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[*]}{"\n"}{end}{end}' 2>/dev/null | sed '/^$/d' | wc -l)"
  if [[ "${endpoint_count}" -eq 0 ]]; then
    fail "samba service has no backend endpoints in namespace '${NAMESPACE}'"
  fi

  log "samba service backend endpoints detected: ${endpoint_count}"
}

main() {
  require_root
  ensure_systemd
  install_packages
  configure_docker
  install_k3s
  wait_for_k3s
  fix_kubeconfig_server_endpoint
  run_repo_bootstrap
  apply_k8s_manifests_and_verify_backend
  log "WSL post-clone bootstrap complete"
}

main "$@"
