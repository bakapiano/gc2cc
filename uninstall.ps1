#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall gc2cc: stop and remove the NSSM service, delete %LOCALAPPDATA%\gc2cc,
    optionally uninstall @anthropic-ai/claude-code, strip ccp from $PROFILE.

.NOTES
    Must be run as Administrator. Does not delete the GitHub Copilot auth token at
    ~/.local/share/copilot-api/github_token -- remove it manually for a full reset.
#>
[CmdletBinding()]
param(
    [string] $ServiceName    = 'gc2cc-copilot-api',
    [string] $InstallDir     = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [switch] $KeepInstallDir,
    [switch] $KeepClaudeCode,
    [switch] $KeepProfile
)

$ErrorActionPreference = 'Stop'

function Info ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Yellow }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    [Security.Principal.WindowsPrincipal]::new($id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host '  Uninstaller needs Administrator (service removal). Run from elevated PowerShell.' -ForegroundColor Red
    exit 1
}

$NssmPath = Join-Path $InstallDir 'bin\nssm.exe'

if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    Info "Removing service '$ServiceName'..."
    if (Test-Path $NssmPath) {
        & $NssmPath stop   $ServiceName 2>&1 | Out-Null
        & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
    } else {
        sc.exe stop   $ServiceName 2>&1 | Out-Null
        sc.exe delete $ServiceName 2>&1 | Out-Null
    }
    Ok 'service removed'
} else {
    Warn "service '$ServiceName' not found, skipping"
}

if (-not $KeepInstallDir -and (Test-Path $InstallDir)) {
    Info "Removing $InstallDir ..."
    Remove-Item -Recurse -Force $InstallDir
    Ok 'install dir removed'
}

if (-not $KeepClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Info 'Uninstalling @anthropic-ai/claude-code ...'
        npm uninstall -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        Ok 'claude-code uninstalled'
    } else {
        Warn 'claude CLI not found, skipping'
    }
}

if (-not $KeepProfile) {
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $c = Get-Content $profilePath -Raw
        $begin = '# >>> gc2cc ccp BEGIN -- managed by gc2cc installer'
        $end   = '# <<< gc2cc ccp END'
        $pattern = [Regex]::Escape($begin) + '[\s\S]*?' + [Regex]::Escape($end) + '\r?\n?'
        $new = [Regex]::Replace($c, $pattern, '').TrimEnd()
        if ($new -ne $c.TrimEnd()) {
            Set-Content -Path $profilePath -Value $new -Encoding UTF8
            Ok "profile snippet removed from $profilePath"
        } else {
            Warn "no gc2cc block found in $profilePath"
        }
    }
}

Write-Host ''
Ok 'gc2cc uninstall complete.'
Write-Host ''
Write-Host 'Note: GitHub Copilot auth token at ~/.local/share/copilot-api/github_token was NOT removed.'
Write-Host '      Delete it manually if you want to fully reset.'
