# Samba Server File Share Simulation — Setup Guide

This guide walks you through deploying the Samba simulation environment on a
Debian/Ubuntu-based Linux system from scratch.

---

## Prerequisites

| Requirement        | Notes                                      |
|--------------------|--------------------------------------------|
| OS                 | Ubuntu 20.04+ or Debian 10+               |
| Privileges         | `sudo` access on the target machine        |
| Network            | Server and clients on the same LAN/VLAN   |

---

## Step 1 — Install Samba

```bash
bash scripts/install_samba.sh
```

This installs the following packages:
- `samba` — SMB/CIFS server daemon
- `samba-common-bin` — Common utilities (`testparm`, `smbpasswd`, etc.)
- `cifs-utils` — Kernel CIFS client utilities for mounting shares

---

## Step 2 — Configure Shares

```bash
bash scripts/configure_samba.sh
```

This script:
1. Creates `/srv/samba/public_share` (world-writable, guest access).
2. Creates `/srv/samba/private_share` (owner-only, password required).
3. Backs up any existing `/etc/samba/smb.conf`.
4. Copies `config/smb.conf` to `/etc/samba/smb.conf`.
5. Runs `testparm` to validate the configuration.

---

## Step 3 — Create a Samba User *(optional, needed for private share)*

```bash
bash scripts/create_samba_user.sh [username]
```

If you omit the username argument, the script prompts interactively.  
The user is created as a **system account** with no login shell and then
registered in the Samba password database (`tdbsam`).

---

## Step 4 — Restart Samba Services

```bash
bash scripts/restart_services.sh
```

Restarts `smbd` (file-sharing daemon) and `nmbd` (NetBIOS name service).

---

## Step 5 — Verify with Tests

```bash
bash tests/share_access_test.sh
```

The test script performs basic sanity checks:
- Checks that `smbd` is running.
- Checks that `nmbd` is running.
- Checks that the share directories exist.
- Uses `smbclient` to list available shares anonymously.

---

## Connecting From Clients

### Linux

```bash
# Mount public share as guest
sudo mount -t cifs //<server_ip>/public_share /mnt/public -o guest,vers=3.0

# Mount private share with credentials
sudo mount -t cifs //<server_ip>/private_share /mnt/private \
    -o username=<samba_user>,vers=3.0
```

### macOS

```
Finder → Go → Connect to Server → smb://<server_ip>/public_share
```

### Windows

```
\\<server_ip>\public_share
\\<server_ip>\private_share
```

---

## Firewall Rules

If `ufw` is active, allow Samba traffic:

```bash
sudo ufw allow samba
```

Samba uses TCP ports **139** and **445**, and UDP ports **137** and **138**.

---

## Troubleshooting

| Symptom                          | Likely cause / fix                                      |
|----------------------------------|---------------------------------------------------------|
| `smbd` not running               | Run `sudo systemctl start smbd`                         |
| Cannot browse shares             | Verify firewall allows Samba; check `nmbd` is running   |
| "Access denied" on private share | Ensure the user is added with `create_samba_user.sh`    |
| Config error on `testparm`       | Review `config/smb.conf` for syntax issues              |

---

## Logs

Samba logs are written to `/var/log/samba/`.

```bash
# Follow smbd log for all clients
sudo tail -f /var/log/samba/log.smbd
```
