#!/usr/bin/env bash
# configure_samba.sh
# Creates share directories, sets permissions, and applies the smb.conf template.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PUBLIC_SHARE="/srv/samba/public_share"
PRIVATE_SHARE="/srv/samba/private_share"
SMB_CONF_SRC="$REPO_ROOT/config/smb.conf"
SMB_CONF_DEST="/etc/samba/smb.conf"

echo "==> Creating share directories..."
sudo mkdir -p "$PUBLIC_SHARE" "$PRIVATE_SHARE"

echo "==> Ensuring 'sambashare' group exists..."
if ! getent group sambashare &>/dev/null; then
    sudo groupadd sambashare
fi

echo "==> Setting permissions on share directories..."
# Public share: world-readable/writable, owned by nobody
sudo chown nobody:nogroup "$PUBLIC_SHARE"
sudo chmod 0775 "$PUBLIC_SHARE"

# Private share: owned by root, accessible only to the sambashare group
sudo chown root:sambashare "$PRIVATE_SHARE"
sudo chmod 0770 "$PRIVATE_SHARE"

echo "==> Backing up existing smb.conf (if any)..."
if [ -f "$SMB_CONF_DEST" ]; then
    sudo cp "$SMB_CONF_DEST" "${SMB_CONF_DEST}.bak.$(date +%Y%m%d%H%M%S)"
fi

echo "==> Applying Samba configuration from $SMB_CONF_SRC..."
sudo cp "$SMB_CONF_SRC" "$SMB_CONF_DEST"

echo "==> Validating Samba configuration..."
sudo testparm -s

echo "==> Configuration complete. Run scripts/restart_services.sh to apply changes."
