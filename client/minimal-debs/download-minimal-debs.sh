#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Packages that the Dockerfile installs. Keeping this list aligned with the Dockerfile
# ensures your offline build won't fail on missing "top-level" packages.
PKGS=(
  ca-certificates
  openssl
  cifs-utils
  smbclient
  samba-common-bin
  python3-samba
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

echo "=== Downloading debs inside a clean ubuntu:24.04 container (captures full dependency closure) ==="
# NOTE: This step requires network access (to populate minimal-debs/).
# After this, your Dockerfile can build with --network=none.
docker run --rm \
  -v "${DEB_DIR}:/out" \
  ubuntu:24.04 bash -euxo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    # Ensure certs etc. are available for downloading.
    apt-get install -y --no-install-recommends ca-certificates apt-transport-https

    # Download packages + dependency closure into /out

    # OLD (can miss top-level .debs if already installed in the container):
    # apt-get -y \
    #   -o Dir::Cache::archives=/out \
    #   -o Debug::NoLocking=1 \
    #   --download-only \
    #   install '"$(printf "%q " "${PKGS[@]}")"'

    # NEW: add --reinstall so APT downloads the .deb files even if already installed
    # (ensures ca-certificates/openssl .debs land in /out reliably)
    apt-get -y \
      -o Dir::Cache::archives=/out \
      -o Debug::NoLocking=1 \
      --download-only \
      --reinstall \
      install '"$(printf "%q " "${PKGS[@]}")"'

    # Avoid permission issues from _apt-owned partial directories
    rm -rf /out/partial || true
    chmod -R a+rX /out
  '

echo "=== Downloaded deb count ==="
ls -1 "${DEB_DIR}"/*.deb | wc -l

echo "=== Example debs ==="
ls -1 "${DEB_DIR}"/*.deb | head -n 20

echo "=== Sanity check: required top-level debs ==="
ls -1 "${DEB_DIR}"/ca-certificates_*.deb >/dev/null
ls -1 "${DEB_DIR}"/openssl_*.deb >/dev/null
echo "OK: ca-certificates + openssl debs present"