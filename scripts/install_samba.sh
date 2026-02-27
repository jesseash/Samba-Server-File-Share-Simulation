#!/usr/bin/env bash
# install_samba.sh
# Installs Samba and supporting packages on Debian/Ubuntu-based systems.

set -euo pipefail

echo "==> Updating package index..."
sudo apt-get update -y

echo "==> Installing Samba packages..."
sudo apt-get install -y samba samba-common-bin cifs-utils

echo "==> Verifying Samba installation..."
samba --version

echo "==> Samba installation complete."
