#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# download-repo.sh
#
# Downloads the samba-ubuntu-depencies.tar release asset from GitHub,
# then extracts directly into the post-clone target directories:
#   - tar: client/minimal-debs-hard-copy/ -> client/minimal-debs/
#   - tar: server/minimal-debs-hard-copy/ -> server/minimal-debs/
#
# Then populates the post-clone directories:
#   ubuntu-base-image/      <- from tar: ubuntu-base-image/
#   client/minimal-debs/   <- from tar: client/minimal-debs-hard-copy/
#   server/minimal-debs/   <- from tar: server/minimal-debs-hard-copy/
#
# After populating, verifies that each target directory contains all files
# from the staging source.
#
# GitHub release:
#   https://github.com/jesseash/Samba-Server-File-Share-Simulation/releases/tag/Samba-dependencies
#
# Usage:
#   bash scripts/download-repo.sh
# =============================================================================

RELEASE_URL="https://github.com/jesseash/Samba-Server-File-Share-Simulation/releases/download/Samba-dependencies/samba-ubuntu-depencies.tar"
TAR_NAME="samba-ubuntu-depencies.tar"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TAR_PATH="${REPO_ROOT}/${TAR_NAME}"

# Directories that are empty after a fresh git clone and need populating
UBUNTU_BASE_IMAGE_DIR="${REPO_ROOT}/ubuntu-base-image"
CLIENT_DEBS_DIR="${REPO_ROOT}/client/minimal-debs"
SERVER_DEBS_DIR="${REPO_ROOT}/server/minimal-debs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

die()     { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info()    { echo -e "${CYAN}INFO:${NC} $*"; }
warn()    { echo -e "${YELLOW}WARN:${NC} $*"; }
success() { echo -e "${GREEN}OK:${NC} $*"; }
fail()    { echo -e "${RED}FAIL:${NC} $*"; }

# ---------------------------------------------------------------------------
# populate_from_tar <label> <tar_prefix> <target_dir> <strip_components>
#   Extracts files directly from the tar archive into the target directory.
# ---------------------------------------------------------------------------
populate_from_tar() {
  local label="$1"
  local tar_prefix="$2"
  local dest="$3"
  local strip_components="$4"

  echo
  echo "------------------------------------------------------------"
  echo ">>> Populating ${label}"

  mkdir -p "${dest}"
  tar -xvf "${TAR_PATH}" \
    --strip-components="${strip_components}" \
    -C "${dest}" \
    "${tar_prefix}"
  success "${label}: $(find "${dest}" -maxdepth 1 -type f | wc -l) files populated -> ${dest}"
}

# ---------------------------------------------------------------------------
# verify_dir_from_tar <label> <populated_dir> <tar_file_prefix>
#   Confirms every tar file in tar_file_prefix exists in populated_dir.
# ---------------------------------------------------------------------------
verify_dir_from_tar() {
  local label="$1"
  local populated="$2"
  local tar_file_prefix="$3"

  echo
  echo "  [CHECK] ${label}"

  local pop_count src_count
  src_count=$(tar -tf "${TAR_PATH}" | grep -E "^${tar_file_prefix}/[^/]+$" | wc -l)
  pop_count=$(find "${populated}"   -maxdepth 1 -type f | wc -l)

  info "  Tar files       : ${src_count}"
  info "  Populated files : ${pop_count}"

  local missing=0
  while IFS= read -r fname; do
    if [[ ! -f "${populated}/${fname}" ]]; then
      warn "  Missing: ${fname}"
      missing=$((missing + 1))
    fi
  done < <(tar -tf "${TAR_PATH}" \
    | grep -E "^${tar_file_prefix}/[^/]+$" \
    | sed -E "s#^${tar_file_prefix}/##" \
    | sort)

  if [[ "${missing}" -eq 0 ]]; then
    success "  ${label}: all ${src_count} files present in ${populated}"
  else
    fail "  ${label}: ${missing} file(s) missing from ${populated}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  command -v wget >/dev/null 2>&1 || die "wget is required but not installed."
  command -v tar  >/dev/null 2>&1 || die "tar is required but not installed."

  echo
  echo "============================================================"
  echo "  Samba CIFS Sim — Dependency Downloader"
  echo "  Release : Samba-dependencies"
  echo "  Asset   : ${TAR_NAME}"
  echo "============================================================"

  # ---- Download ----
  echo
  echo "------------------------------------------------------------"
  echo ">>> Downloading ${TAR_NAME}"
  info "URL  : ${RELEASE_URL}"
  info "Dest : ${TAR_PATH}"
  wget --show-progress --continue --output-document="${TAR_PATH}" "${RELEASE_URL}"
  success "${TAR_NAME} downloaded ($(du -sh "${TAR_PATH}" | cut -f1))"

  # ---- Populate target directories directly from tar ----
  echo
  echo "------------------------------------------------------------"
  echo ">>> Populating target directories from ${TAR_NAME}"

  populate_from_tar \
    "ubuntu-base-image" \
    "ubuntu-base-image/ubuntu-24.04.tar" \
    "${UBUNTU_BASE_IMAGE_DIR}" \
    "1"

  populate_from_tar \
    "client/minimal-debs" \
    "client/minimal-debs-hard-copy" \
    "${CLIENT_DEBS_DIR}" \
    "2"

  populate_from_tar \
    "server/minimal-debs" \
    "server/minimal-debs-hard-copy" \
    "${SERVER_DEBS_DIR}" \
    "2"

  # ---- Verify ----
  echo
  echo "------------------------------------------------------------"
  echo ">>> Verifying populated directories"

  local errors=0

  verify_dir_from_tar \
    "ubuntu-base-image" \
    "${UBUNTU_BASE_IMAGE_DIR}" \
    "ubuntu-base-image" || errors=$((errors + 1))

  verify_dir_from_tar \
    "client/minimal-debs" \
    "${CLIENT_DEBS_DIR}" \
    "client/minimal-debs-hard-copy" || errors=$((errors + 1))

  verify_dir_from_tar \
    "server/minimal-debs" \
    "${SERVER_DEBS_DIR}" \
    "server/minimal-debs-hard-copy" || errors=$((errors + 1))

  echo
  echo "============================================================"
  if [[ "${errors}" -eq 0 ]]; then
    success "All checks passed"
  else
    fail "${errors} check(s) failed — review warnings above"
    exit 1
  fi
  echo
  echo "  Tar file    : ${TAR_PATH}"
  echo "  Base image  : ${UBUNTU_BASE_IMAGE_DIR}"
  echo "  Client debs : ${CLIENT_DEBS_DIR}"
  echo "  Server debs : ${SERVER_DEBS_DIR}"
  echo
  echo "You can now run:"
  echo "  bash client/rebuild-client.sh"
  echo "  bash server/rebuild-server.sh"
  echo "============================================================"
}

main "$@"
