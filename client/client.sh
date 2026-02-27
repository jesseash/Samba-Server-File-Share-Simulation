#!/bin/bash
set -e

###############################################################################
# DIAGNOSTIC: STARTUP
###############################################################################
echo "[INFO] Client starting on $(hostname)"
echo "[INFO] Current time: $(date -Iseconds)"
echo "[INFO] Environment:"
echo "------------------------------------------------------------"
echo "Hostname: $(hostname)"
echo "Pod name: ${POD_NAME:-unknown}"
echo "------------------------------------------------------------"

###############################################################################
# WAIT FOR SAMBA SERVICE (NO nc REQUIRED)
###############################################################################
echo "[INFO] Waiting for Samba service on port 445..."

while ! timeout 1 bash -c "echo > /dev/tcp/samba.default.svc.cluster.local/445" 2>/dev/null; do
    echo "[WAIT] Samba not ready yet..."
    sleep 2
done

echo "[OK] Samba is reachable on port 445"

###############################################################################
# PREPARE MOUNT DIRECTORY
###############################################################################
mkdir -p /mnt/samba

###############################################################################
# CIFS MOUNT (AUTH VIA USERNAME MAP)
###############################################################################
echo "[INFO] Attempting CIFS mount..."

while ! mount -t cifs //samba.default.svc.cluster.local/share /mnt/samba \
    -o "username=$(hostname),password=,vers=3.0,noperm"; do
    echo "[WAIT] CIFS mount failed, retrying..."
    sleep 2
done

echo "[OK] Mounted //samba.default.svc.cluster.local/share on /mnt/samba"

###############################################################################
# INITIAL FILE CREATION
###############################################################################
if ls -A /mnt/samba >/dev/null 2>&1; then
    echo "[INFO] Share already contains files"
else
    echo "[INFO] Initializing share with first file"
    echo "Initial file from $(hostname)" > /mnt/samba/$(hostname)-init-$(date +%s).txt
fi

###############################################################################
# MAIN LOOP
###############################################################################
echo "[INFO] Entering main loop..."

while true; do
    action=$((RANDOM % 3))

    case $action in
        0)
            file="/mnt/samba/$(hostname)-write-$(date +%s).txt"
            echo "[WRITE] Creating file: $file"
            echo "User $(hostname) wrote this file at $(date -Iseconds)" > "$file"
            ;;
        1)
            echo "[READ] Listing directory contents"
            ls -l /mnt/samba >/dev/null 2>&1
            ;;
        2)
            echo "[DELETE] Removing all files"
            rm -f /mnt/samba/* 2>/dev/null || true
            ;;
    esac

    sleep $((RANDOM % 5 + 1))
done
