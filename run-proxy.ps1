# Wrapper script executed by the gc2cc-copilot-api Scheduled Task.
# Runs `bun src/main.ts start --port <Port>` with stdout/stderr appended to
# %LOCALAPPDATA%\gc2cc\logs\copilot-api.log. Naive rotation at 5 MB.
[CmdletBinding()]
param(
    [int] $Port = 4141
)

$ErrorActionPreference = 'Continue'

$InstallDir = $PSScriptRoot
$LogDir     = Join-Path $InstallDir 'logs'
$ProxyDir   = Join-Path $InstallDir 'copilot-api'
$Log        = Join-Path $LogDir 'copilot-api.log'
$LogPrev    = Join-Path $LogDir 'copilot-api.prev.log'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if ((Test-Path $Log) -and ((Get-Item $Log).Length -gt 5MB)) {
    Remove-Item $LogPrev -Force -ErrorAction SilentlyContinue
    Move-Item $Log $LogPrev -Force
}

# PATH inside the Scheduled Task context may differ from an interactive shell;
# resolve bun absolutely. winget/Oven-sh.Bun puts bun under %USERPROFILE%\.bun\bin.
$bun = (Get-Command bun -ErrorAction SilentlyContinue).Source
if (-not $bun) { $bun = Join-Path $env:USERPROFILE '.bun\bin\bun.exe' }
if (-not (Test-Path $bun)) {
    "[gc2cc] $(Get-Date -Format o) bun.exe not found (looked at PATH and $env:USERPROFILE\.bun\bin\bun.exe)" |
        Out-File -FilePath $Log -Encoding utf8 -Append
    exit 1
}

Set-Location $ProxyDir
"[gc2cc] $(Get-Date -Format o) starting: $bun src/main.ts start --port $Port" |
    Out-File -FilePath $Log -Encoding utf8 -Append

& $bun src/main.ts start --port $Port *>> $Log
$code = $LASTEXITCODE
"[gc2cc] $(Get-Date -Format o) bun exited with code $code" |
    Out-File -FilePath $Log -Encoding utf8 -Append
exit $code
