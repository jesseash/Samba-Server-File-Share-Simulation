#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WIN_TARGET_DIRS=(
  "/mnt/c/Container/samba-cifs-sim/scripts"
  "/mnt/c/Container/Samba-File-Share-Simulation/Samba-Server-File-Share-Simulation/scripts"
)
SOURCE_FILES=(
  "${SCRIPT_DIR}/post_clone_windows_setup.ps1"
  "${SCRIPT_DIR}/run_windows_setup.ps1"
  "${SCRIPT_DIR}/run_windows_setup.cmd"
  "${SCRIPT_DIR}/bootstrap_wsl_post_clone.sh"
  "${SCRIPT_DIR}/download-repo.sh"
  "${REPO_ROOT}/client/rebuild-client.sh"
  "${REPO_ROOT}/server/rebuild-server.sh"
  "${REPO_ROOT}/k8s/pvc.yaml"
  "${REPO_ROOT}/k8s/samba-config.yaml"
  "${REPO_ROOT}/k8s/samba-service.yaml"
  "${REPO_ROOT}/k8s/samba-deployment.yaml"
  "${REPO_ROOT}/k8s/clients-deployment.yaml"
)

echo "[update] Source: ${SCRIPT_DIR}"
echo "[update] Targets:"
for win_target_dir in "${WIN_TARGET_DIRS[@]}"; do
  echo "  - ${win_target_dir}"
done

for win_target_dir in "${WIN_TARGET_DIRS[@]}"; do
  mkdir -p "${win_target_dir}"
done

for source_file in "${SOURCE_FILES[@]}"; do
  if [[ ! -f "${source_file}" ]]; then
    echo "[update][error] Missing source file: ${source_file}" >&2
    exit 1
  fi
done

for win_target_dir in "${WIN_TARGET_DIRS[@]}"; do
  win_repo_root="$(cd "${win_target_dir}/.." && pwd)"

  cp "${SCRIPT_DIR}/post_clone_windows_setup.ps1" "${win_target_dir}/post_clone_windows_setup.ps1"
  cp "${SCRIPT_DIR}/run_windows_setup.ps1" "${win_target_dir}/run_windows_setup.ps1"
  cp "${SCRIPT_DIR}/run_windows_setup.cmd" "${win_target_dir}/run_windows_setup.cmd"
  cp "${SCRIPT_DIR}/bootstrap_wsl_post_clone.sh" "${win_target_dir}/bootstrap_wsl_post_clone.sh"
  cp "${SCRIPT_DIR}/download-repo.sh" "${win_target_dir}/download-repo.sh"
  cp "${REPO_ROOT}/client/rebuild-client.sh" "${win_target_dir}/rebuild-client.sh"
  cp "${REPO_ROOT}/server/rebuild-server.sh" "${win_target_dir}/rebuild-server.sh"

  mkdir -p "${win_repo_root}/scripts" "${win_repo_root}/client" "${win_repo_root}/server" "${win_repo_root}/k8s"
  cp "${SCRIPT_DIR}/run_windows_setup.ps1" "${win_repo_root}/scripts/run_windows_setup.ps1"
  cp "${SCRIPT_DIR}/run_windows_setup.cmd" "${win_repo_root}/scripts/run_windows_setup.cmd"
  cp "${SCRIPT_DIR}/download-repo.sh" "${win_repo_root}/scripts/download-repo.sh"
  cp "${REPO_ROOT}/client/rebuild-client.sh" "${win_repo_root}/client/rebuild-client.sh"
  cp "${REPO_ROOT}/server/rebuild-server.sh" "${win_repo_root}/server/rebuild-server.sh"
  if ! cp "${REPO_ROOT}/k8s/pvc.yaml" "${win_repo_root}/k8s/pvc.yaml"; then
    echo "[update][warn] Could not copy ${win_repo_root}/k8s/pvc.yaml (permission denied or read-only path)" >&2
  fi
  if ! cp "${REPO_ROOT}/k8s/samba-config.yaml" "${win_repo_root}/k8s/samba-config.yaml"; then
    echo "[update][warn] Could not copy ${win_repo_root}/k8s/samba-config.yaml (permission denied or read-only path)" >&2
  fi
  if ! cp "${REPO_ROOT}/k8s/samba-service.yaml" "${win_repo_root}/k8s/samba-service.yaml"; then
    echo "[update][warn] Could not copy ${win_repo_root}/k8s/samba-service.yaml (permission denied or read-only path)" >&2
  fi
  if ! cp "${REPO_ROOT}/k8s/samba-deployment.yaml" "${win_repo_root}/k8s/samba-deployment.yaml"; then
    echo "[update][warn] Could not copy ${win_repo_root}/k8s/samba-deployment.yaml (permission denied or read-only path)" >&2
  fi
  if ! cp "${REPO_ROOT}/k8s/clients-deployment.yaml" "${win_repo_root}/k8s/clients-deployment.yaml"; then
    echo "[update][warn] Could not copy ${win_repo_root}/k8s/clients-deployment.yaml (permission denied or read-only path)" >&2
  fi
done

echo "[update] Copied files:"
for win_target_dir in "${WIN_TARGET_DIRS[@]}"; do
  win_repo_root="$(cd "${win_target_dir}/.." && pwd)"
  echo "[update] In ${win_target_dir}:"
  ls -l \
    "${win_target_dir}/post_clone_windows_setup.ps1" \
    "${win_target_dir}/run_windows_setup.ps1" \
    "${win_target_dir}/run_windows_setup.cmd" \
    "${win_target_dir}/bootstrap_wsl_post_clone.sh" \
    "${win_target_dir}/download-repo.sh" \
    "${win_target_dir}/rebuild-client.sh" \
    "${win_target_dir}/rebuild-server.sh"
  echo "[update] In ${win_repo_root}/scripts, ${win_repo_root}/client and ${win_repo_root}/server:"
  ls -l \
    "${win_repo_root}/scripts/run_windows_setup.ps1" \
    "${win_repo_root}/scripts/run_windows_setup.cmd" \
    "${win_repo_root}/scripts/download-repo.sh" \
    "${win_repo_root}/client/rebuild-client.sh" \
    "${win_repo_root}/server/rebuild-server.sh"
done

echo "[update] Windows scripts update complete"
