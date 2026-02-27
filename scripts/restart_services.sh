#!/usr/bin/env bash
# restart_services.sh
# Restarts the Samba daemons (smbd and nmbd).

set -euo pipefail

echo "==> Restarting smbd..."
sudo systemctl restart smbd

echo "==> Restarting nmbd..."
sudo systemctl restart nmbd

echo "==> Checking service status..."
sudo systemctl is-active smbd
sudo systemctl is-active nmbd

echo "==> Samba services restarted successfully."
