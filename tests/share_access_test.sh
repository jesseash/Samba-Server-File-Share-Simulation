#!/usr/bin/env bash
# share_access_test.sh
# Smoke tests to verify the Samba simulation environment is correctly set up.
#
# Usage:
#   bash tests/share_access_test.sh [server_ip]
#
# If server_ip is omitted, 127.0.0.1 (localhost) is used.

set -euo pipefail

SERVER="${1:-127.0.0.1}"
PUBLIC_SHARE_DIR="/srv/samba/public_share"
PRIVATE_SHARE_DIR="/srv/samba/private_share"
PASS=0
FAIL=0

_pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
_fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "========================================"
echo "  Samba Share Access Test"
echo "  Target server: $SERVER"
echo "========================================"

# 1. Check smbd is running
if systemctl is-active --quiet smbd; then
    _pass "smbd service is active"
else
    _fail "smbd service is NOT active (run: sudo systemctl start smbd)"
fi

# 2. Check nmbd is running
if systemctl is-active --quiet nmbd; then
    _pass "nmbd service is active"
else
    _fail "nmbd service is NOT active (run: sudo systemctl start nmbd)"
fi

# 3. Check public share directory exists
if [ -d "$PUBLIC_SHARE_DIR" ]; then
    _pass "Public share directory exists: $PUBLIC_SHARE_DIR"
else
    _fail "Public share directory MISSING: $PUBLIC_SHARE_DIR (run: bash scripts/configure_samba.sh)"
fi

# 4. Check private share directory exists
if [ -d "$PRIVATE_SHARE_DIR" ]; then
    _pass "Private share directory exists: $PRIVATE_SHARE_DIR"
else
    _fail "Private share directory MISSING: $PRIVATE_SHARE_DIR (run: bash scripts/configure_samba.sh)"
fi

# 5. List shares anonymously via smbclient
if command -v smbclient &>/dev/null; then
    if smbclient -L "$SERVER" -N &>/dev/null; then
        _pass "smbclient can list shares on $SERVER anonymously"
    else
        _fail "smbclient failed to list shares on $SERVER (check firewall and Samba config)"
    fi
else
    echo "[SKIP] smbclient not installed — install with: sudo apt-get install -y smbclient"
fi

# 6. Validate smb.conf
if command -v testparm &>/dev/null; then
    if testparm -s &>/dev/null; then
        _pass "testparm: smb.conf is valid"
    else
        _fail "testparm: smb.conf has errors (run: testparm -s)"
    fi
else
    echo "[SKIP] testparm not installed — install Samba first"
fi

echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ]
