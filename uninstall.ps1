#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall gc2cc: stop and remove the NSSM Windows Service, delete
    %LOCALAPPDATA%\gc2cc, remove the bin\ dir from user PATH, optionally
    uninstall @anthropic-ai/claude-code, strip any legacy ccp block from
    $PROFILE, and clean up any legacy Scheduled Task from pre-NSSM installs.

.NOTES
    Self-elevates via UAC -- NSSM service removal requires Administrator.
    Does not delete the GitHub Copilot auth token at
    ~/.local/share/copilot-api/github_token -- remove it manually for a full reset.
#>
[CmdletBinding()]
param(
    [int]    $Port           = 4141,
    [string] $ServiceName    = 'gc2cc-copilot-api',
    [string] $InstallDir     = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [string] $PagesBaseUrl   = 'https://escapecat.github.io/gc2cc',
    [string] $UserHome       = $env:USERPROFILE,
    [switch] $KeepInstallDir,
    [switch] $KeepClaudeCode,
    [switch] $KeepCodex,
    [switch] $KeepProfile
)

$ErrorActionPreference = 'Stop'

function Info ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Yellow }

# ---------- self-elevate ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Info 'NSSM service removal requires Administrator. Re-launching via UAC...'
    $tmp = Join-Path $env:TEMP ('gc2cc-uninstall-{0}.ps1' -f ([Guid]::NewGuid()))
    # Prefer the on-disk script (testing local edits before publish); fall back
    # to downloading from Pages when invoked via `irm | iex`.
    $localPath = $PSCommandPath
    if (-not $localPath) { $localPath = $MyInvocation.MyCommand.Path }
    if ($localPath -and (Test-Path $localPath)) {
        Copy-Item $localPath $tmp -Force
    } else {
        Invoke-WebRequest -Uri "$PagesBaseUrl/uninstall.ps1" -OutFile $tmp -UseBasicParsing
    }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tmp`"",
                 '-Port',$Port,
                 '-ServiceName',$ServiceName,
                 '-InstallDir',"`"$InstallDir`"",
                 '-PagesBaseUrl',$PagesBaseUrl,
                 '-UserHome',"`"$UserHome`"")
    if ($KeepInstallDir) { $argList += '-KeepInstallDir' }
    if ($KeepClaudeCode) { $argList += '-KeepClaudeCode' }
    if ($KeepCodex)      { $argList += '-KeepCodex' }
    if ($KeepProfile)    { $argList += '-KeepProfile' }
    Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return
}

$BinDir = Join-Path $InstallDir 'bin'
$nssm   = Join-Path $BinDir 'nssm.exe'

# ---------- NSSM service ----------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Info "Stopping and removing service '$ServiceName' ..."
    if (Test-Path $nssm) {
        & $nssm stop   $ServiceName confirm | Out-Null
        & $nssm remove $ServiceName confirm | Out-Null
    } else {
        # NSSM gone but service still registered: fall back to sc.exe.
        sc.exe stop   $ServiceName | Out-Null
        sc.exe delete $ServiceName | Out-Null
    }
    Ok 'service removed'
} else {
    Warn "no service '$ServiceName' found, skipping"
}

# ---------- legacy Scheduled Task cleanup (pre-NSSM installs) ----------
foreach ($p in @('\gc2cc\','\')) {
    $task = Get-ScheduledTask -TaskName $ServiceName -TaskPath $p -ErrorAction SilentlyContinue
    if ($task) {
        Info "Found legacy Scheduled Task '$p$ServiceName'. Removing..."
        try { Stop-ScheduledTask -TaskName $ServiceName -TaskPath $p -ErrorAction SilentlyContinue } catch {}
        try {
            Unregister-ScheduledTask -TaskName $ServiceName -TaskPath $p -Confirm:$false -ErrorAction Stop
            Ok "legacy task at $p removed"
        } catch {
            Warn "Could not remove legacy task at '$p': $_"
        }
    }
}

# ---------- port sweep ----------
# Stop + remove doesn't always kill bun (NSSM kills the tree, but a manual
# `nssm stop` race + orphan after a crash can leave a stale listener).
$squatters = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($c in $squatters) {
    Info "Freeing port ${Port}: killing PID=$($c.OwningProcess)"
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}
if ($squatters) { Start-Sleep -Milliseconds 500 }

# ---------- user PATH ----------
# Remove $BinDir from the invoking user's PATH (HKCU\Environment).
if ($env:USERPROFILE -eq $UserHome) {
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ -and ($_ -ne $BinDir) }
        $newPath = $parts -join ';'
        if ($newPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Ok "removed from user PATH: $BinDir"
        }
    }
} else {
    Warn "Cross-account elevation; PATH not modified for $UserHome (remove $BinDir manually)."
}

# ---------- install dir ----------
if (-not $KeepInstallDir -and (Test-Path $InstallDir)) {
    Info "Removing $InstallDir ..."
    Remove-Item -Recurse -Force $InstallDir
    Ok 'install dir removed'
}

# ---------- claude-code CLI ----------
if (-not $KeepClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Info 'Uninstalling @anthropic-ai/claude-code ...'
        npm uninstall -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        Ok 'claude-code uninstalled'
    } else {
        Warn 'claude CLI not found, skipping'
    }
}

# ---------- codex CLI ----------
# The gc2cc-managed CODEX_HOME lives inside $InstallDir and is wiped with it;
# only the npm-global `@openai/codex` binary needs separate uninstall here.
if (-not $KeepCodex) {
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        Info 'Uninstalling @openai/codex ...'
        npm uninstall -g '@openai/codex' 2>&1 | Out-Null
        Ok 'codex uninstalled'
    } else {
        Warn 'codex CLI not found, skipping'
    }
}

# ---------- $PROFILE cleanup ----------
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
        }
    }
}

Write-Host ''
Ok 'gc2cc uninstall complete.'
Write-Host ''
Write-Host 'Note: GitHub Copilot auth token at ~/.local/share/copilot-api/github_token was NOT removed.'
Write-Host '      Delete it manually if you want to fully reset.'
