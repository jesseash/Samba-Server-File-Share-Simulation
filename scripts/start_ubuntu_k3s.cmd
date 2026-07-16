@echo off
REM Start a persistent WSL session for the Ubuntu-k3s distribution.
REM This opens a new window and runs Ubuntu-k3s
REM so users can connect to it and WSL will not shut it down.
start "Ubuntu-k3s" wsl.exe -d Ubuntu-k3s
