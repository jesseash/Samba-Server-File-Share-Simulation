#!/usr/bin/env bash
# create_samba_user.sh
# Creates a Linux system account (login-shell-less) and adds it to Samba.

set -euo pipefail

if [ -z "${1:-}" ]; then
    read -r -p "Enter new Samba username: " SAMBA_USER
else
    SAMBA_USER="$1"
fi

if [ -z "$SAMBA_USER" ]; then
    echo "ERROR: Username cannot be empty." >&2
    exit 1
fi

echo "==> Creating system account '$SAMBA_USER' (no login shell)..."
if id "$SAMBA_USER" &>/dev/null; then
    echo "    System account '$SAMBA_USER' already exists, skipping useradd."
else
    sudo useradd -M -s /usr/sbin/nologin "$SAMBA_USER"
fi

echo "==> Adding '$SAMBA_USER' to the 'sambashare' group..."
sudo usermod -aG sambashare "$SAMBA_USER"

echo "==> Setting Samba password for '$SAMBA_USER'..."
sudo smbpasswd -a "$SAMBA_USER"
sudo smbpasswd -e "$SAMBA_USER"

echo "==> Samba user '$SAMBA_USER' created and enabled."
