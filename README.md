# Samba Server File Share Simulation

A simulation project that mirrors the file structure, scripts, and local dependencies of a Samba file-sharing server environment on Linux.

## Overview

This project provides a complete, reproducible setup for a Samba file server simulation, including:

- **Installation** scripts for Samba packages
- **Configuration** of shared directories and Samba settings
- **User management** for both system and Samba accounts
- **Service management** to start/stop/restart Samba daemons
- **Public and private** share directories
- **Documentation** for step-by-step setup and usage
- **Tests** to validate share access

## Repository Structure

```
Samba-Server-File-Share-Simulation/
├── README.md
├── config/
│   └── smb.conf               # Example Samba configuration file
├── docs/
│   └── setup_guide.md         # Step-by-step setup guide
├── scripts/
│   ├── install_samba.sh       # Install Samba packages
│   ├── configure_samba.sh     # Configure shares and apply smb.conf
│   ├── create_samba_user.sh   # Create a Samba user account
│   └── restart_services.sh    # Restart smbd/nmbd services
├── shares/
│   ├── public_share/          # Publicly accessible share directory
│   │   └── .gitkeep
│   └── private_share/         # Password-protected share directory
│       └── .gitkeep
└── tests/
    └── share_access_test.sh   # Smoke test for share accessibility
```

## Quick Start

1. **Install Samba:**
   ```bash
   bash scripts/install_samba.sh
   ```

2. **Configure shares:**
   ```bash
   bash scripts/configure_samba.sh
   ```

3. **Create a Samba user** *(required for private share access)*:
   ```bash
   bash scripts/create_samba_user.sh
   ```

4. **Restart Samba services:**
   ```bash
   bash scripts/restart_services.sh
   ```

5. **Run tests:**
   ```bash
   bash tests/share_access_test.sh
   ```

## Connecting to Shares

| Share          | Path                            | Access      |
|----------------|---------------------------------|-------------|
| public_share   | `\\<server_ip>\public_share`   | Guest/open  |
| private_share  | `\\<server_ip>\private_share`  | Credentials |

### Linux client example
```bash
# Mount public share
sudo mount -t cifs //<server_ip>/public_share /mnt/public -o guest

# Mount private share
sudo mount -t cifs //<server_ip>/private_share /mnt/private -o username=<samba_user>
```

### Windows client
Open **File Explorer** and type `\\<server_ip>` in the address bar.

## Requirements

- Ubuntu 20.04+ / Debian 10+ (or compatible distro with `apt`)
- `sudo` privileges
- `samba`, `samba-common-bin`, `cifs-utils` (installed by `install_samba.sh`)

## License

MIT