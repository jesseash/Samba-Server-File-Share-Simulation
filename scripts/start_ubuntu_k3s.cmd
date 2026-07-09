@echo off
REM Start a persistent WSL session for the Ubuntu-k3s distribution.
REM This opens a new window and runs a long-lived sleep loop to keep the distro running
REM so users can connect to it and WSL will not shut it down.
start "Ubuntu-k3s" wsl.exe -d Ubuntu-k3s -- bash -lc "trap 'exit 0' TERM INT; while true; do sleep 86400; done"
