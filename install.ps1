#Requires -Version 5.1
<#
.SYNOPSIS
    Installs gc2cc: GitHub Copilot -> Claude Code bridge on Windows.

.DESCRIPTION
    - Installs prereqs (git, node, bun) via winget if missing.
    - Clones bakapiano/copilot-api at branch feat/1m-suffix into %LOCALAPPDATA%\gc2cc\copilot-api.
    - Runs `bun install` and the interactive GitHub Copilot device-code auth flow (once).
    - Registers a per-user Scheduled Task `gc2cc-copilot-api` that runs the proxy
      hidden in the background on AtLogOn (auto-restart on failure). No admin needed.
    - Installs @anthropic-ai/claude-code globally.
    - Drops `ccp.ps1` + `ccp.cmd` into %LOCALAPPDATA%\gc2cc\bin\ and adds that dir
      to user PATH so `ccp` works from any shell (PS5.1, PS7, VSCode terminal, cmd).

.NOTES
    Runs without Administrator. The proxy runs as the installing user, so
    ~/.local/share/copilot-api/github_token resolves naturally.
    Re-runs are idempotent.
#>
[CmdletBinding()]
param(
    [int]    $Port         = 4141,
    [string] $TaskName     = 'gc2cc-copilot-api',
    [string] $TaskPath     = '\gc2cc\',
    [string] $InstallDir   = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [string] $RepoUrl      = 'https://github.com/bakapiano/copilot-api',
    [string] $RepoBranch   = 'feat/1m-suffix',
    [string] $PagesBaseUrl = 'https://bakapiano.github.io/gc2cc',
    [switch] $SkipAuth,
    [switch] $SkipClaudeCode,
    [switch] $SkipPath
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- helpers ----------
function Info ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Yellow }
function Die  ($m) {
    # Use throw, not `exit 1`. When this script is run via `irm | iex` the script
    # body executes in the host shell's scope, so `exit` closes the user's whole
    # PowerShell window and the red error flashes by unseen. `throw` raises a
    # terminating error that iex propagates to the caller; the shell survives.
    Write-Host "[gc2cc] $m" -ForegroundColor Red
    throw "[gc2cc] $m"
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$m;$u"
}

function Ensure-Cmd {
    param([string]$Name, [scriptblock]$Install)
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }
    # The current shell's $env:Path is a snapshot from when it was launched.
    # If the cmd was installed after this shell opened, refresh first before
    # assuming it's actually missing.
    Refresh-Path
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }
    Info "Installing prerequisite: $Name"
    & $Install
    Refresh-Path
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Die "$Name still not on PATH after install. Open a fresh PowerShell and re-run."
    }
}

# ---------- 1. layout ----------
$ProxyDir   = Join-Path $InstallDir 'copilot-api'
$LogDir     = Join-Path $InstallDir 'logs'
$BinDir     = Join-Path $InstallDir 'bin'
$WrapperPs1 = Join-Path $InstallDir 'run-proxy.ps1'

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir, $BinDir | Out-Null
Info "Install root: $InstallDir"

# ---------- 2. prereqs ----------
# winget ships with Win10 1809+ / Win11 by default. If it's somehow missing,
# follow Microsoft's documented no-admin recovery: try Add-AppxPackage
# -RegisterByFamilyName first (App Installer present but unregistered), and
# fall back to Microsoft.WinGet.Client + Repair-WinGetPackageManager.
# Docs: https://learn.microsoft.com/en-us/windows/package-manager/winget/
Ensure-Cmd 'winget' {
    Info 'winget not detected; trying Add-AppxPackage -RegisterByFamilyName ...'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch {
        Info 'Register failed; bootstrapping via Microsoft.WinGet.Client (PSGallery, current user scope)...'
        $ProgressPreference = 'SilentlyContinue'
        try { Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null } catch {}
        Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -AcceptLicense
        Repair-WinGetPackageManager
    }
}
Ensure-Cmd 'git'    { winget install --id Git.Git       -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
Ensure-Cmd 'node'   { winget install --id OpenJS.NodeJS -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
Ensure-Cmd 'bun'    { winget install --id Oven-sh.Bun   -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }

# ---------- 3. clone or update proxy ----------
if (Test-Path (Join-Path $ProxyDir '.git')) {
    Info "Updating proxy from $RepoUrl@$RepoBranch ..."
    git -C $ProxyDir fetch origin $RepoBranch --quiet
    git -C $ProxyDir reset --hard "origin/$RepoBranch" --quiet
} else {
    Info "Cloning $RepoUrl@$RepoBranch ..."
    git clone -b $RepoBranch --depth 1 $RepoUrl $ProxyDir 2>&1 | Out-Null
}

Info 'bun install...'
Push-Location $ProxyDir
try { bun install --silent } finally { Pop-Location }

# ---------- 4. GitHub Copilot auth (interactive, once) ----------
$UserHome  = $env:USERPROFILE
$TokenPath = Join-Path $UserHome '.local\share\copilot-api\github_token'

$tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
if (-not $SkipAuth -and -not $tokenOk) {
    Write-Host ''
    Info 'Running GitHub Copilot device-code auth flow...'
    Info 'When prompted, open the URL in a browser and paste the code.'
    Write-Host ''
    Push-Location $ProxyDir
    try { bun src/main.ts auth } finally { Pop-Location }

    $tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
    if (-not $tokenOk) { Die "Auth did not complete; token still missing at $TokenPath" }
    Ok 'GitHub token captured.'
} else {
    Ok "Auth token already present at $TokenPath"
}

# ---------- 5. Scheduled Task ----------
Info "Registering Scheduled Task '$TaskName' (port $Port, AtLogOn, auto-restart)..."

# Fetch the wrapper script that the task executes
Invoke-WebRequest -Uri "$PagesBaseUrl/run-proxy.ps1" -OutFile $WrapperPs1 -UseBasicParsing

# Use the PowerShell that's currently running this script
$pwshPath = (Get-Process -Id $PID).Path

# Idempotent: unregister existing task in our subfolder. (Tasks at root path `\`
# require admin to modify, so we deliberately scope under \gc2cc\.)
if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    Start-Sleep -Milliseconds 300
}

# Best-effort cleanup of legacy root-path task from older installs. This step
# requires admin to delete; if it fails, the orphan is inert (its run-proxy.ps1
# may have been removed) but the user should remove it manually with:
#   schtasks /Delete /TN gc2cc-copilot-api /F   (run as Administrator)
$legacy = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
if ($legacy) {
    try {
        Stop-ScheduledTask  -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        Info 'Removed legacy root-path task.'
    } catch {
        Warn "Legacy root-path task '\\$TaskName' could not be removed (admin required)."
        Warn "  Run once as admin:  schtasks /Delete /TN $TaskName /F"
    }
}

# Stop-ScheduledTask doesn't always reach descendants -- e.g. if a previous run
# crashed mid-way the wrapper pwsh can exit and orphan bun, leaving 4141 squatted.
# Free the port defensively so the new task action can bind.
$squatters = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($c in $squatters) {
    $pp = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    Info "Freeing port ${Port}: killing PID=$($c.OwningProcess) name=$($pp.ProcessName)"
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}
if ($squatters) { Start-Sleep -Milliseconds 500 }

$action = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $WrapperPs1, $Port) `
    -WorkingDirectory $InstallDir

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Limited run level == standard user, no UAC.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -Hidden

Register-ScheduledTask `
    -TaskName    $TaskName `
    -TaskPath    $TaskPath `
    -Description 'gc2cc copilot-api proxy (bakapiano fork, feat/1m-suffix)' `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

# Wait for /v1/models
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest "http://localhost:$Port/v1/models" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) {
    Warn "Task did not become reachable on port $Port within 30s. Check logs:"
    Warn "  $LogDir\copilot-api.log"
    Die  "Task '$TaskName' is registered but not responding."
}
Ok "Task running: http://localhost:$Port"

# ---------- 6. Claude Code CLI ----------
if (-not $SkipClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Ok "claude CLI present: $((Get-Command claude).Source)"
    } else {
        Info 'Installing @anthropic-ai/claude-code globally...'
        npm install -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        Refresh-Path
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
            Warn 'npm install reported success but `claude` not on PATH. Restart your shell and try `ccp`.'
        } else {
            Ok "claude installed: $((Get-Command claude).Source)"
        }
    }
}

# ---------- 7. ccp on PATH ----------
if (-not $SkipPath) {
    Info "Deploying ccp.ps1 and ccp.cmd to $BinDir ..."
    Invoke-WebRequest -Uri "$PagesBaseUrl/ccp.ps1" -OutFile (Join-Path $BinDir 'ccp.ps1') -UseBasicParsing
    Invoke-WebRequest -Uri "$PagesBaseUrl/ccp.cmd" -OutFile (Join-Path $BinDir 'ccp.cmd') -UseBasicParsing

    # Add $BinDir to user PATH (HKCU\Environment -- no admin), idempotently.
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($null -eq $userPath) { $userPath = '' }
    $parts = $userPath -split ';' | Where-Object { $_ }
    if ($parts -notcontains $BinDir) {
        $newPath = (($parts + $BinDir) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Ok "Added to user PATH: $BinDir"
    } else {
        Ok "user PATH already contains $BinDir"
    }
    # Pull into current session too so `ccp` works right now without reopening.
    if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

    # Migration: strip any legacy gc2cc sentinel block from $PROFILE. A
    # function defined there would shadow the new PATH-mounted ccp.ps1.
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing) {
            $begin   = '# >>> gc2cc ccp BEGIN -- managed by gc2cc installer'
            $end     = '# <<< gc2cc ccp END'
            $pattern = [Regex]::Escape($begin) + '[\s\S]*?' + [Regex]::Escape($end) + '\r?\n?'
            $cleaned = [Regex]::Replace($existing, $pattern, '').TrimEnd()
            if ($cleaned -ne $existing.TrimEnd()) {
                Set-Content -Path $profilePath -Value $cleaned -Encoding UTF8
                Info "Removed legacy gc2cc block from $profilePath (now superseded by PATH)."
            }
        }
    }
}

# ---------- 8. summary ----------
Write-Host ''
Ok 'gc2cc install complete.'
Write-Host ''
Write-Host ('  task        : {0}' -f $TaskName)
Write-Host ('  proxy URL   : http://localhost:{0}' -f $Port)
Write-Host ('  proxy repo  : {0}' -f $ProxyDir)
Write-Host ('  logs        : {0}' -f $LogDir)
Write-Host ''
Write-Host '  ccp is now on PATH for new shells (PS5.1, PS7, cmd, VSCode terminal).'
Write-Host '  Open a fresh window, then try:'
Write-Host '    ccp          # pick a Copilot-backed model, then claude'
Write-Host ''
Write-Host '  Task controls:'
Write-Host ('    Get-ScheduledTask -TaskName {0} -TaskPath {1} | Get-ScheduledTaskInfo' -f $TaskName, $TaskPath)
Write-Host ('    Stop-ScheduledTask -TaskName {0} -TaskPath {1}; Start-ScheduledTask -TaskName {0} -TaskPath {1}' -f $TaskName, $TaskPath)
Write-Host ''
