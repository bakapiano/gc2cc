@echo off
rem cmd.exe shim: invoke cxp.ps1 via Windows PowerShell (always present).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cxp.ps1" %*
