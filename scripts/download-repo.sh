#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# download-repo.sh
#
# Downloads all pre-built dependency files (deb packages and base image)
# from a remote file repository into the correct local folders.
#
# Populates:
#   ubuntu-base-image/       - Ubuntu 24.04 Docker base image tarball
#   client/minimal-debs/     - CIFS client .deb packages
#   server/minimal-debs/     - Samba server .deb packages
#
# Usage:
#   BASE_URL=https://your-actual-host.example.com bash scripts/download-repo.sh
#   bash scripts/download-repo.sh
#
# The remote folder structure is assumed to mirror this repo:
#   <BASE_URL>/ubuntu-base-image/ubuntu-24.04.tar
#   <BASE_URL>/client/minimal-debs/<file>
#   <BASE_URL>/server/minimal-debs/<file>
# =============================================================================

BASE_URL="${BASE_URL:-https://YOUR-REPO-HOST-PLACEHOLDER.example.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_IMAGE_DIR="${REPO_ROOT}/ubuntu-base-image"
CLIENT_DEBS_DIR="${REPO_ROOT}/client/minimal-debs"
SERVER_DEBS_DIR="${REPO_ROOT}/server/minimal-debs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

die() {
  echo -e "${RED}ERROR:${NC} $*" >&2
  exit 1
}

info() {
  echo -e "${CYAN}INFO:${NC} $*"
}

warn() {
  echo -e "${YELLOW}WARN:${NC} $*"
}

success() {
  echo -e "${GREEN}OK:${NC} $*"
}

strip_trailing_slash() {
  local input="$1"
  echo "${input%/}"
}

download_file() {
  local url="$1"
  local dest_path="$2"

  wget --show-progress --continue --output-document="${dest_path}" "${url}"
}

list_remote_files() {
  local remote_dir="$1"
  local filename_regex="$2"
  local html

  html="$(wget -qO- "${remote_dir}/")" || return 1

  printf '%s\n' "${html}" \
    | grep -Eo 'href="[^"]+"' \
    | sed -E 's/^href="([^"]+)"$/\1/' \
    | while IFS= read -r href; do
      [[ -z "${href}" ]] && continue
      [[ "${href}" == */ ]] && continue
      [[ "${href}" == \?* ]] && continue
      [[ "${href}" == \#* ]] && continue

      href="${href%%\?*}"
      href="${href%%\#*}"

      local filename="${href##*/}"
      [[ -z "${filename}" ]] && continue

      if [[ "${filename}" =~ ${filename_regex} ]]; then
        echo "${filename}"
      fi
    done \
    | sort -u
}

download_folder_from_index() {
  local remote_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local filename_regex="$4"

  mkdir -p "${dest_dir}"

  info "Discovering files in ${remote_dir}/"
  mapfile -t files < <(list_remote_files "${remote_dir}" "${filename_regex}")

  if [[ "${#files[@]}" -eq 0 ]]; then
    die "No matching files found at ${remote_dir}/. Ensure directory listing is enabled and URL is correct."
  fi

  echo "------------------------------------------------------------"
  echo ">>> ${label} (${#files[@]} files)"

  local idx=1
  local total="${#files[@]}"
  for filename in "${files[@]}"; do
    printf "${CYAN}[%3d/%3d]${NC} %s\n" "${idx}" "${total}" "${filename}"
    download_file "${remote_dir}/${filename}" "${dest_dir}/${filename}"
    idx=$((idx + 1))
  done

  success "Folder complete: ${dest_dir}"
  echo
}

usage_if_placeholder() {
  if [[ "${BASE_URL}" == *"PLACEHOLDER"* ]]; then
    warn "BASE_URL is using the placeholder value:"
    warn "  ${BASE_URL}"
    echo
    warn "Set BASE_URL to your actual host, for example:"
    warn "  BASE_URL=https://your-actual-host.example.com bash scripts/download-repo.sh"
    echo
    read -r -p "Continue anyway (for URL structure testing)? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || die "Aborted."
  fi
}

main() {
  command -v wget >/dev/null 2>&1 || die "wget is required but not installed."

  BASE_URL="$(strip_trailing_slash "${BASE_URL}")"
  usage_if_placeholder

  local client_remote="${BASE_URL}/client/minimal-debs"
  local server_remote="${BASE_URL}/server/minimal-debs"
  local base_image_remote="${BASE_URL}/ubuntu-base-image/ubuntu-24.04.tar"

  echo
  echo "============================================================"
  echo "  Samba CIFS Sim — Dependency Downloader"
  echo "  BASE_URL: ${BASE_URL}"
  echo "============================================================"
  echo

  echo "------------------------------------------------------------"
  echo ">>> Ubuntu base image"
  mkdir -p "${BASE_IMAGE_DIR}"
  info "Downloading ubuntu-24.04.tar -> ${BASE_IMAGE_DIR}"
  download_file "${base_image_remote}" "${BASE_IMAGE_DIR}/ubuntu-24.04.tar"
  success "ubuntu-24.04.tar downloaded"
  echo

  download_folder_from_index \
    "${client_remote}" \
    "${CLIENT_DEBS_DIR}" \
    "CLIENT minimal-debs" \
    '(\\.deb|Packages\\.gz)$'

  download_folder_from_index \
    "${server_remote}" \
    "${SERVER_DEBS_DIR}" \
    "SERVER minimal-debs" \
    '(\\.deb|Packages\\.gz)$'

  echo "============================================================"
  success "All downloads complete"
  echo "  Base image  : ${BASE_IMAGE_DIR}/ubuntu-24.04.tar"
  echo "  Client debs : ${CLIENT_DEBS_DIR}"
  echo "  Server debs : ${SERVER_DEBS_DIR}"
  echo
  echo "You can now run:"
  echo "  bash client/rebuild-client.sh"
  echo "  bash server/rebuild-server.sh"
  echo "============================================================"
}

main "$@"
