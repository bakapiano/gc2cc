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
    - Adds the `ccp` PowerShell function to your $PROFILE (idempotent, sentinel-marked).

.NOTES
    Runs without Administrator. The proxy runs as the installing user, so
    ~/.local/share/copilot-api/github_token resolves naturally.
    Re-runs are idempotent.
#>
[CmdletBinding()]
param(
    [int]    $Port         = 4141,
    [string] $TaskName     = 'gc2cc-copilot-api',
    [string] $InstallDir   = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [string] $RepoUrl      = 'https://github.com/bakapiano/copilot-api',
    [string] $RepoBranch   = 'feat/1m-suffix',
    [string] $PagesBaseUrl = 'https://bakapiano.github.io/gc2cc',
    [switch] $SkipAuth,
    [switch] $SkipClaudeCode,
    [switch] $SkipProfile
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
$WrapperPs1 = Join-Path $InstallDir 'run-proxy.ps1'

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir | Out-Null
Info "Install root: $InstallDir"

# ---------- 2. prereqs ----------
Ensure-Cmd 'winget' { Die 'winget not found. Install "App Installer" from Microsoft Store, then retry.' }
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

# Idempotent: unregister existing task
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Start-Sleep -Milliseconds 300
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
    -Description 'gc2cc copilot-api proxy (bakapiano fork, feat/1m-suffix)' `
    -Action      $action `
    -Trigger     $trigger `
    -Principal   $principal `
    -Settings    $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

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

# ---------- 7. PowerShell profile (ccp) ----------
if (-not $SkipProfile) {
    Info "Installing ccp into $PROFILE ..."
    $snippetUrl = "$PagesBaseUrl/profile-snippet.ps1"
    $snippetTmp = Join-Path $env:TEMP "gc2cc-snippet-$(Get-Random).ps1"
    try {
        Invoke-WebRequest -Uri $snippetUrl -OutFile $snippetTmp -UseBasicParsing
        $snippet = Get-Content $snippetTmp -Raw
    } catch {
        Die "Could not fetch $snippetUrl : $_"
    } finally {
        Remove-Item $snippetTmp -Force -ErrorAction SilentlyContinue
    }

    $profilePath = $PROFILE
    $profileDir  = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir))  { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File      -Force -Path $profilePath | Out-Null }

    $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $existing) { $existing = '' }

    $begin = '# >>> gc2cc ccp BEGIN -- managed by gc2cc installer'
    $end   = '# <<< gc2cc ccp END'

    $pattern  = [Regex]::Escape($begin) + '[\s\S]*?' + [Regex]::Escape($end) + '\r?\n?'
    $stripped = [Regex]::Replace($existing, $pattern, '').TrimEnd()

    if ($stripped -match '(?im)^\s*function\s+ccp\b') {
        Warn 'Detected an existing ccp function in your profile outside the gc2cc block.'
        Warn 'Leaving it alone -- remove it manually if you want gc2cc to take precedence.'
    }

    $block = $begin + "`r`n" + $snippet.TrimEnd() + "`r`n" + $end + "`r`n"
    $final = if ($stripped) { $stripped + "`r`n`r`n" + $block } else { $block }
    Set-Content -Path $profilePath -Value $final -Encoding UTF8
    Ok "Profile updated: $profilePath"
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
Write-Host '  Open a fresh PowerShell window, then try:'
Write-Host '    ccp          # pick a Copilot-backed model, then claude'
Write-Host ''
Write-Host '  Task controls:'
Write-Host ('    Get-ScheduledTask -TaskName {0} | Get-ScheduledTaskInfo' -f $TaskName)
Write-Host ('    Stop-ScheduledTask -TaskName {0}; Start-ScheduledTask -TaskName {0}' -f $TaskName)
Write-Host ''
