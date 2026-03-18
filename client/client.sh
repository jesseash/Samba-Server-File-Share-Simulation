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

if [[ -n "${POD_NAME:-}" ]]; then
    CLIENT_ID="c-${POD_NAME##*-}"
else
    CLIENT_ID="c-$(hostname)"
fi

# NetBIOS name must be <= 15 characters
CLIENT_ID="${CLIENT_ID:0:15}"
echo "[INFO] Client ID for SMB identity: ${CLIENT_ID}"

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
# CIFS MOUNT HELPER
###############################################################################
do_mount() {
    # Unmount if something is already mounted (best-effort)
    umount -l /mnt/samba 2>/dev/null || true
    mount -t cifs //samba.default.svc.cluster.local/share /mnt/samba \
    -o "username=${CLIENT_ID},password=,vers=3.0,noperm,netbiosname=${CLIENT_ID}"
}

ensure_mounted() {
    # Test the mount with a simple probe; remount if it is stale or gone
    if ! ls /mnt/samba >/dev/null 2>&1; then
        echo "[REMOUNT] Mount is stale or gone — remounting..."
        while ! do_mount; do
            echo "[WAIT] Remount failed, retrying..."
            sleep 3
        done
        echo "[REMOUNT] Remounted successfully"
    fi
}

###############################################################################
# INITIAL CIFS MOUNT
###############################################################################
echo "[INFO] Attempting CIFS mount..."

while ! do_mount; do
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
    ensure_mounted

    action=$((RANDOM % 3))

    case $action in
        0)
            file="/mnt/samba/$(hostname)-write-$(date +%s).txt"
            echo "[WRITE] Creating file: $file"
            echo "User $(hostname) wrote this file at $(date -Iseconds)" > "$file" || {
                echo "[WARN] Write failed (stale mount?), will remount on next iteration"
                umount -l /mnt/samba 2>/dev/null || true
            }
            ;;
        1)
            echo "[READ] Listing directory contents"
            ls -l /mnt/samba >/dev/null 2>&1 || {
                echo "[WARN] Read failed (stale mount?), will remount on next iteration"
                umount -l /mnt/samba 2>/dev/null || true
            }
            ;;
        2)
            echo "[DELETE] Removing all files"
            rm -f /mnt/samba/* 2>/dev/null || true
            ;;
    esac

    sleep $((RANDOM % 5 + 1))
done
