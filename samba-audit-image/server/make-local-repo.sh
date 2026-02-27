#!/usr/bin/env bash
set -euo pipefail

# This script lives in .../samba-audit-image/server/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_DIR="${SCRIPT_DIR}/minimal-debs"

sudo apt-get update
sudo apt-get install -y dpkg-dev

pushd "${DEB_DIR}" >/dev/null
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
popd >/dev/null

echo "Created ${DEB_DIR}/Packages.gz"
