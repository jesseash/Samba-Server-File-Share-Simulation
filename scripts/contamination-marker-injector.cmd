@echo off
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0contamination-marker-injector.ps1" %*
