@echo off
rem cmd.exe shim: invoke ccp.ps1 via Windows PowerShell (always present).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ccp.ps1" %*
