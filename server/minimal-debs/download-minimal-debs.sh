#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKGS=(
  ca-certificates
  samba
  samba-vfs-modules
)

echo "DEB_DIR: ${DEB_DIR}"
echo "Packages:"
printf ' - %s\n' "${PKGS[@]}"
echo

echo "=== Reset directory ==="
rm -f "${DEB_DIR}"/*.deb "${DEB_DIR}/Packages" "${DEB_DIR}/Packages.gz"
rm -rf "${DEB_DIR}/partial" "${DEB_DIR}/archives" 2>/dev/null || true
mkdir -p "${DEB_DIR}"
chmod -R u+rwX "${DEB_DIR}"

echo "=== Downloading Samba + dependencies in ubuntu:24.04 ==="
docker run --rm \
  -v "${DEB_DIR}:/out" \
  ubuntu:24.04 bash -euxo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https

    apt-get -y \
      -o Dir::Cache::archives=/out \
      -o Debug::NoLocking=1 \
      --download-only \
      --reinstall \
      install '"$(printf "%q " "${PKGS[@]}")"'

    rm -rf /out/partial || true
    chmod -R a+rX /out
  '

echo "=== Downloaded deb count ==="
ls -1 "${DEB_DIR}"/*.deb | wc -l

echo "=== Sanity check ==="
ls -1 "${DEB_DIR}"/samba_*.deb >/dev/null
echo "OK: samba deb present"
