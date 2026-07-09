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

get_wsl_eth0_ipv4() {
  local current_ip

  current_ip="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
  if [[ -n "${current_ip}" ]]; then
    echo "${current_ip}"
    return 0
  fi

  current_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${current_ip}"
}

wait_for_wsl_ip_stability() {
  local timeout=240
  local interval=5
  local required_stable_checks=8
  local stable_checks=0
  local start
  local last_ip=""

  start="$(date +%s)"
  log "Waiting for WSL2 IP stability on eth0 before workload setup"

  while true; do
    local current_ip
    current_ip="$(get_wsl_eth0_ipv4)"

    if [[ -z "${current_ip}" ]]; then
      stable_checks=0
      log "WSL2 IP not available yet on eth0"
    elif [[ "${current_ip}" == "${last_ip}" ]]; then
      stable_checks=$((stable_checks + 1))
      log "WSL2 IP stability check ${stable_checks}/${required_stable_checks} passed (ip=${current_ip})"
      if [[ "${stable_checks}" -ge "${required_stable_checks}" ]]; then
        log "WSL2 IP stability window satisfied (ip=${current_ip})"
        return 0
      fi
    else
      if [[ -n "${last_ip}" ]]; then
        log "WSL2 IP changed on eth0: ${last_ip} -> ${current_ip}"
      else
        log "Detected initial WSL2 eth0 IP: ${current_ip}"
      fi
      last_ip="${current_ip}"
      stable_checks=1
      log "WSL2 IP stability check ${stable_checks}/${required_stable_checks} passed (ip=${current_ip})"
    fi

    if (( $(date +%s) - start > timeout )); then
      fail "WSL2 IP did not stabilize within ${timeout}s"
    fi

    sleep "${interval}"
  done
}

wait_for_runtime_stability() {
  local timeout=300
  local interval=10
  local required_stable_checks=6
  local stable_checks=0
  local start

  start="$(date +%s)"
  log "Waiting for sustained runtime stability before applying workloads"

  while true; do
    local k3s_active=0
    local containerd_ready=0
    local not_ready_nodes=999

    if systemctl is-active --quiet k3s; then
      k3s_active=1
    fi

    if /usr/local/bin/k3s crictl info >/dev/null 2>&1; then
      containerd_ready=1
    fi

    if kubectl get nodes --no-headers >/dev/null 2>&1; then
      not_ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {count++} END {print count+0}')"
    fi

    if [[ "${k3s_active}" -eq 1 && "${containerd_ready}" -eq 1 && "${not_ready_nodes}" -eq 0 ]]; then
      stable_checks=$((stable_checks + 1))
      log "Runtime stability check ${stable_checks}/${required_stable_checks} passed"
      if [[ "${stable_checks}" -ge "${required_stable_checks}" ]]; then
        log "Runtime stability window satisfied"
        return 0
      fi
    else
      stable_checks=0
      log "Runtime not stable yet (k3s_active=${k3s_active}, containerd_ready=${containerd_ready}, not_ready_nodes=${not_ready_nodes})"
    fi

    if (( $(date +%s) - start > timeout )); then
      fail "k3s/containerd/node stability window not reached within ${timeout}s"
    fi

    sleep "${interval}"
  done
}

wait_for_kube_system_core_ready() {
  local timeout=420
  local interval=10
  local required_stable_checks=4
  local stable_checks=0
  local start

  start="$(date +%s)"
  log "Waiting for kube-system CNI/core readiness before workload apply"

  while true; do
    local cni_ready=0
    local flannel_subnet_ready=0
    local coredns_running=0
    local local_path_running=0

    if ls /var/lib/rancher/k3s/agent/etc/cni/net.d/* >/dev/null 2>&1; then
      cni_ready=1
    fi

    if [[ -s /run/flannel/subnet.env ]]; then
      flannel_subnet_ready=1
    fi

    if kubectl -n kube-system get pod --no-headers 2>/dev/null | awk '$1 ~ /^coredns-/ && $3 == "Running" {found=1} END {exit(found?0:1)}'; then
      coredns_running=1
    fi

    if kubectl -n kube-system get pod --no-headers 2>/dev/null | awk '$1 ~ /^local-path-provisioner-/ && $3 == "Running" {found=1} END {exit(found?0:1)}'; then
      local_path_running=1
    fi

    if [[ "${cni_ready}" -eq 1 && "${flannel_subnet_ready}" -eq 1 && "${coredns_running}" -eq 1 && "${local_path_running}" -eq 1 ]]; then
      stable_checks=$((stable_checks + 1))
      log "kube-system stability check ${stable_checks}/${required_stable_checks} passed"
      if [[ "${stable_checks}" -ge "${required_stable_checks}" ]]; then
        log "kube-system CNI/core readiness window satisfied"
        return 0
      fi
    else
      stable_checks=0
      log "kube-system not ready yet (cni_ready=${cni_ready}, flannel_subnet_ready=${flannel_subnet_ready}, coredns_running=${coredns_running}, local_path_running=${local_path_running})"
    fi

    if (( $(date +%s) - start > timeout )); then
      fail "kube-system CNI/core readiness not reached within ${timeout}s"
    fi

    sleep "${interval}"
  done
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
  wait_for_wsl_ip_stability
  wait_for_runtime_stability
  wait_for_kube_system_core_ready
  fix_kubeconfig_server_endpoint
  run_repo_bootstrap
  apply_k8s_manifests_and_verify_backend
  log "WSL post-clone bootstrap complete"
}

main "$@"
