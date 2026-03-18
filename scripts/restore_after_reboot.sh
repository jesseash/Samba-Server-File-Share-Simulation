#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${ROOT_DIR}/k8s"
SERVER_DIR="${ROOT_DIR}/server"
CLIENT_DIR="${ROOT_DIR}/client"

SERVER_IMAGE="local/samba-audit:latest"
CLIENT_IMAGE="local/client:latest"
SERVER_TAR="${SERVER_DIR}/samba-audit-latest.tar"
CLIENT_TAR="${CLIENT_DIR}/client-latest.tar"

NAMESPACE="${NAMESPACE:-default}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

log() { echo "[restore] $*"; }
warn() { echo "[restore][warn] $*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[restore][error] Missing required command: $1"
        exit 1
    }
}

wait_for_k8s() {
    local timeout=120
    local start
    start=$(date +%s)

    while true; do
        if kubectl get nodes >/dev/null 2>&1; then
            return 0
        fi

        if (( $(date +%s) - start > timeout )); then
            echo "[restore][error] Kubernetes API not reachable after ${timeout}s"
            return 1
        fi

        sleep 2
    done
}

import_tar_if_present() {
    local tar_file="$1"
    local image_ref="$2"

    if [[ -f "$tar_file" ]]; then
        log "Importing image tar: ${tar_file}"
        sudo k3s ctr images import "$tar_file" >/dev/null

        if sudo k3s crictl inspecti "$image_ref" >/dev/null 2>&1; then
            log "Image available in k3s: ${image_ref}"
        else
            warn "Imported tar, but could not confirm image ref '${image_ref}' via crictl"
        fi
    else
        warn "Tarball not found: ${tar_file}"
    fi
}

apply_manifests() {
    log "Applying Kubernetes manifests"
    kubectl -n "$NAMESPACE" apply -f "${K8S_DIR}/pvc.yaml"
    kubectl -n "$NAMESPACE" apply -f "${K8S_DIR}/samba-config.yaml"
    kubectl -n "$NAMESPACE" apply -f "${K8S_DIR}/samba-service.yaml"
    kubectl -n "$NAMESPACE" apply -f "${K8S_DIR}/samba-deployment.yaml"
    kubectl -n "$NAMESPACE" apply -f "${K8S_DIR}/clients-deployment.yaml"
}

restart_and_wait() {
    log "Restarting deployments"
    kubectl -n "$NAMESPACE" rollout restart deployment/samba
    kubectl -n "$NAMESPACE" rollout restart deployment/samba-users

    log "Waiting for samba rollout"
    kubectl -n "$NAMESPACE" rollout status deployment/samba --timeout=180s

    log "Waiting for samba-users rollout"
    kubectl -n "$NAMESPACE" rollout status deployment/samba-users --timeout=240s
}

print_summary() {
    log "Current pods"
    kubectl -n "$NAMESPACE" get pods -l app=samba -o wide
    kubectl -n "$NAMESPACE" get pods -l app=samba-users -o wide

    log "Current service"
    kubectl -n "$NAMESPACE" get svc samba -o wide
}

main() {
    require_cmd kubectl
    require_cmd sudo

    log "Repository root: ${ROOT_DIR}"

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet k3s; then
            log "Starting k3s service"
            sudo systemctl start k3s
        else
            log "k3s service already active"
        fi
    else
        warn "systemctl not available; assuming k3s is already running"
    fi

    wait_for_k8s

    if [[ "$FORCE_REBUILD" == "1" ]]; then
        log "FORCE_REBUILD=1 -> running full image rebuild flow"
        bash "${SERVER_DIR}/rebuild-server.sh"
        bash "${CLIENT_DIR}/rebuild-client.sh"
        print_summary
        log "Simulation restore complete (full rebuild path)"
        return 0
    fi

    import_tar_if_present "$SERVER_TAR" "$SERVER_IMAGE"
    import_tar_if_present "$CLIENT_TAR" "$CLIENT_IMAGE"

    apply_manifests
    restart_and_wait
    print_summary

    log "Simulation restore complete"
    log "Tip: run FORCE_REBUILD=1 bash scripts/restore_after_reboot.sh for a full rebuild"
}

main "$@"
