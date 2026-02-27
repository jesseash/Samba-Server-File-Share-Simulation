#!/usr/bin/env bash
set -euo pipefail

DEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKGS=( samba )

echo "DEB_DIR: ${DEB_DIR}"
echo "PKGS: ${PKGS[*]}"
echo

echo "=== Reset directory ==="
rm -f "${DEB_DIR}"/*.deb "${DEB_DIR}/Packages" "${DEB_DIR}/Packages.gz" "${DEB_DIR}/package-list.txt"
rm -rf "${DEB_DIR}/partial" "${DEB_DIR}/archives" "${DEB_DIR}/.tmp" 2>/dev/null || true
mkdir -p "${DEB_DIR}"
chmod -R u+rwX "${DEB_DIR}"

echo "=== Ensure host has required tools ==="
sudo apt-get update
sudo apt-get install -y apt-rdepends dpkg-dev

echo "=== Compute dependency closure (apt-rdepends) ==="
apt-rdepends "${PKGS[@]}" \
  | sed -n 's/^\([^ ][^ ]*\)$/\1/p' \
  | grep -vE '^(PreDepends:|Depends:|Recommends:|Suggests:|Conflicts:|Breaks:|Replaces:|Enhances:|Provides:)$' \
  | grep -vE '^\s*$' \
  | sort -u \
  > "${DEB_DIR}/package-list.txt"

echo "Total packages in closure: $(wc -l < "${DEB_DIR}/package-list.txt")"

echo "=== Download all packages in closure ==="
tmp="${DEB_DIR}/.tmp"
rm -rf "${tmp}"
mkdir -p "${tmp}"
pushd "${tmp}" >/dev/null

xargs -a "${DEB_DIR}/package-list.txt" -r apt-get download

popd >/dev/null

shopt -s nullglob
mv "${tmp}"/*.deb "${DEB_DIR}/"
shopt -u nullglob
rm -rf "${tmp}"

echo "=== Build Packages.gz ==="
cd "${DEB_DIR}"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

echo "=== Summary ==="
echo "Downloaded debs: $(ls -1 "${DEB_DIR}"/*.deb 2>/dev/null | wc -l)"
ls -lah "${DEB_DIR}" | sed -n '1,120p'
