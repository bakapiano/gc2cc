#Requires -Version 5.1
<#
.SYNOPSIS
    Installs gc2cc: GitHub Copilot -> Claude Code bridge on Windows.

.DESCRIPTION
    - Installs prereqs (git, node, bun) via winget if missing.
    - Clones bakapiano/copilot-api at branch feat/1m-suffix into %LOCALAPPDATA%\gc2cc\copilot-api.
    - Runs `bun install` and the interactive GitHub Copilot device-code auth flow (once).
    - Registers a Windows Service `gc2cc-copilot-api` via NSSM that runs the proxy
      as LocalSystem, auto-restarts on crash, and rotates logs natively.
    - Installs @anthropic-ai/claude-code globally.
    - Drops `ccp.ps1` + `ccp.cmd` into %LOCALAPPDATA%\gc2cc\bin\ and adds that dir
      to user PATH so `ccp` works from any shell (PS5.1, PS7, VSCode terminal, cmd).

.NOTES
    Requires Administrator (NSSM service registration writes to HKLM and the SCM).
    The script self-elevates via UAC if launched non-elevated. Re-runs are idempotent.
#>
[CmdletBinding()]
param(
    [int]    $Port         = 4141,
    [string] $ServiceName  = 'gc2cc-copilot-api',
    [string] $InstallDir   = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [string] $RepoUrl      = 'https://github.com/bakapiano/copilot-api',
    [string] $RepoBranch   = 'feat/1m-suffix',
    [string] $PagesBaseUrl = 'https://bakapiano.github.io/gc2cc',
    [string] $NssmZipUrl   = 'https://nssm.cc/release/nssm-2.24.zip',
    [string] $NssmChocoUrl = 'https://community.chocolatey.org/api/v2/package/NSSM/2.24.101.20180116',
    [string] $UserHome     = $env:USERPROFILE,
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
    # PowerShell window and the red error flashes by unseen.
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
    Refresh-Path
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }
    Info "Installing prerequisite: $Name"
    & $Install
    Refresh-Path
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Die "$Name still not on PATH after install. Open a fresh PowerShell and re-run."
    }
}

# ---------- 0. self-elevate ----------
# NSSM service ops (install/start/stop/remove) write to HKLM\SYSTEM\...\Services
# and the SCM -- both require admin. If we're not elevated, re-fetch the script
# from Pages and relaunch via UAC. We download rather than try to roundtrip
# $MyInvocation -- with `irm | iex` there is no script path to point at.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Info 'NSSM service registration requires Administrator. Re-launching via UAC...'
    $tmp = Join-Path $env:TEMP ('gc2cc-install-{0}.ps1' -f ([Guid]::NewGuid()))
    # Prefer the on-disk script (testing local edits before publish); fall back
    # to downloading from Pages when invoked via `irm | iex`.
    $localPath = $PSCommandPath
    if (-not $localPath) { $localPath = $MyInvocation.MyCommand.Path }
    if ($localPath -and (Test-Path $localPath)) {
        Copy-Item $localPath $tmp -Force
    } else {
        Invoke-WebRequest -Uri "$PagesBaseUrl/install.ps1" -OutFile $tmp -UseBasicParsing
    }
    # UAC keeps the same SID, so $env:USERPROFILE in the elevated process is
    # still ours -- but we pass it explicitly via -UserHome so callers running
    # `runas /user:OTHER` see the install pinned to the invoking user's home.
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tmp`"",
                 '-Port',$Port,
                 '-ServiceName',$ServiceName,
                 '-InstallDir',"`"$InstallDir`"",
                 '-RepoUrl',$RepoUrl,
                 '-RepoBranch',$RepoBranch,
                 '-PagesBaseUrl',$PagesBaseUrl,
                 '-NssmZipUrl',$NssmZipUrl,
                 '-NssmChocoUrl',$NssmChocoUrl,
                 '-UserHome',"`"$UserHome`"")
    if ($SkipAuth)       { $argList += '-SkipAuth' }
    if ($SkipClaudeCode) { $argList += '-SkipClaudeCode' }
    if ($SkipPath)       { $argList += '-SkipPath' }
    Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return
}

# ---------- 1. layout ----------
$ProxyDir = Join-Path $InstallDir 'copilot-api'
$LogDir   = Join-Path $InstallDir 'logs'
$BinDir   = Join-Path $InstallDir 'bin'

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir, $BinDir | Out-Null

# Capture elevated install output for post-mortem debugging if anything fails.
# Doesn't interfere with normal console output; lives until next install run.
$installTranscript = Join-Path $LogDir 'install.log'
try { Start-Transcript -Path $installTranscript -Force -ErrorAction Stop | Out-Null } catch {}
Info "Install root: $InstallDir (running elevated as $env:USERNAME, install pinned to $UserHome)"

# ---------- 2. prereqs ----------
# winget ships with Win10 1809+ / Win11 by default. If it's somehow missing,
# follow Microsoft's documented recovery: try Add-AppxPackage
# -RegisterByFamilyName first (App Installer present but unregistered), and
# fall back to Microsoft.WinGet.Client + Repair-WinGetPackageManager.
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

# ---------- 3. nssm ----------
# nssm.cc is the official source but flaps with 503s. Fall back to the
# chocolatey CDN nupkg (same NSSM 2.24 build, far more reliable host).
$nssm = Join-Path $BinDir 'nssm.exe'
if (-not (Test-Path $nssm)) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $sources = @($NssmZipUrl, $NssmChocoUrl)
    $downloaded = $false
    foreach ($url in $sources) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Info "Downloading NSSM (try $attempt): $url"
                $zip = Join-Path $env:TEMP ('nssm-gc2cc-{0}.zip' -f ([Guid]::NewGuid()))
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                $tmpDir = Join-Path $env:TEMP ('nssm-gc2cc-{0}' -f ([Guid]::NewGuid()))
                Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
                # Prefer an exe under a path containing the target arch; fall
                # back to the largest nssm.exe in the archive (win64 build is
                # ~336 KB vs ~250 KB for win32).
                $candidates = Get-ChildItem -Path $tmpDir -Recurse -Filter nssm.exe
                $found = $candidates | Where-Object { $_.DirectoryName -like "*\$arch" } | Select-Object -First 1
                if (-not $found) { $found = $candidates | Sort-Object Length -Descending | Select-Object -First 1 }
                if ($found) {
                    Copy-Item $found.FullName $nssm -Force
                    Remove-Item $zip,$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
                    $downloaded = $true; break
                }
                Remove-Item $zip,$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Warn "NSSM download failed (try $attempt of $url): $_"
                Start-Sleep -Seconds 2
            }
        }
        if ($downloaded) { break }
    }
    if (-not $downloaded) { Die "Could not download nssm.exe from any of: $($sources -join '; ')" }
}
Ok "nssm: $nssm"

# ---------- 4. clone or update proxy ----------
if (Test-Path (Join-Path $ProxyDir '.git')) {
    Info "Updating proxy from $RepoUrl@$RepoBranch ..."
    git -C $ProxyDir fetch origin $RepoBranch --quiet
    git -C $ProxyDir reset --hard "origin/$RepoBranch" --quiet
} else {
    Info "Cloning $RepoUrl@$RepoBranch ..."
    # --quiet: without it, git writes "Cloning into '...'" to stderr, and PS 5.1
    # under ErrorActionPreference=Stop promotes that to a terminating
    # NativeCommandError. The fetch line above uses the same flag for the
    # same reason.
    git clone --quiet -b $RepoBranch --depth 1 $RepoUrl $ProxyDir 2>&1 | Out-Null
}

Info 'bun install...'
Push-Location $ProxyDir
try { bun install --silent } finally { Pop-Location }

# ---------- 5. GitHub Copilot auth (interactive, once) ----------
# Auth lives under the *invoking* user's home; the elevated process still has
# our SID so $UserHome resolves correctly. The service later overrides USERPROFILE
# in its env block so LocalSystem can find this same token.
$TokenPath = Join-Path $UserHome '.local\share\copilot-api\github_token'

$tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
if (-not $SkipAuth -and -not $tokenOk) {
    Write-Host ''
    Info 'Running GitHub Copilot device-code auth flow...'
    Info 'When prompted, open the URL in a browser and paste the code.'
    Write-Host ''
    Push-Location $ProxyDir
    try {
        # Force HOME/USERPROFILE so bun (running here as the elevated admin
        # process) writes the token under the invoking user's home, not the
        # admin's profile in case of cross-account elevation.
        $env:USERPROFILE = $UserHome
        $env:HOME        = $UserHome
        bun src/main.ts auth
    } finally { Pop-Location }

    $tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
    if (-not $tokenOk) { Die "Auth did not complete; token still missing at $TokenPath" }
    Ok 'GitHub token captured.'
} else {
    Ok "Auth token already present at $TokenPath"
}

# ---------- 6. migrate from legacy Scheduled Task (pre-NSSM) ----------
$legacyName = 'gc2cc-copilot-api'
foreach ($p in @('\gc2cc\','\')) {
    $task = Get-ScheduledTask -TaskName $legacyName -TaskPath $p -ErrorAction SilentlyContinue
    if ($task) {
        Info "Removing legacy Scheduled Task '$p$legacyName' (superseded by NSSM service)..."
        try { Stop-ScheduledTask -TaskName $legacyName -TaskPath $p -ErrorAction SilentlyContinue } catch {}
        try {
            Unregister-ScheduledTask -TaskName $legacyName -TaskPath $p -Confirm:$false -ErrorAction Stop
            Ok "legacy task at $p removed"
        } catch {
            Warn "Could not remove legacy task '$p$legacyName': $_"
        }
    }
}
# Old per-task wrapper script is unused now.
$legacyWrapper = Join-Path $InstallDir 'run-proxy.ps1'
if (Test-Path $legacyWrapper) { Remove-Item $legacyWrapper -Force -ErrorAction SilentlyContinue }
$legacyVbs = Join-Path $InstallDir 'run-proxy.vbs'
if (Test-Path $legacyVbs)     { Remove-Item $legacyVbs     -Force -ErrorAction SilentlyContinue }

# ---------- 7. NSSM service ----------
$bunExe = (Get-Command bun -ErrorAction SilentlyContinue).Source
if (-not $bunExe) { $bunExe = Join-Path $UserHome '.bun\bin\bun.exe' }
if (-not (Test-Path $bunExe)) { Die "bun.exe not found (tried PATH and $UserHome\.bun\bin\bun.exe)" }

# Stop & remove any prior service (idempotent re-run)
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Info "Stopping and removing existing service '$ServiceName' ..."
    & $nssm stop   $ServiceName confirm | Out-Null
    & $nssm remove $ServiceName confirm | Out-Null
    Start-Sleep -Milliseconds 500
}

# Free the port defensively (a stale bun could still be squatting after a crash)
$squatters = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($c in $squatters) {
    $pp = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    Info "Freeing port ${Port}: killing PID=$($c.OwningProcess) name=$($pp.ProcessName)"
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}
if ($squatters) { Start-Sleep -Milliseconds 500 }

Info "Registering service '$ServiceName' (port $Port) via NSSM..."
& $nssm install     $ServiceName $bunExe 'src/main.ts' start --port $Port | Out-Null
& $nssm set $ServiceName AppDirectory  $ProxyDir | Out-Null
& $nssm set $ServiceName DisplayName   'gc2cc Copilot API proxy' | Out-Null
& $nssm set $ServiceName Description   'GitHub Copilot -> OpenAI/Anthropic-compatible proxy (bakapiano/copilot-api, feat/1m-suffix)' | Out-Null
& $nssm set $ServiceName Start         SERVICE_AUTO_START | Out-Null
& $nssm set $ServiceName ObjectName    LocalSystem | Out-Null
# Service runs as LocalSystem, whose default USERPROFILE points at systemprofile
# and doesn't see ~/.local/share/copilot-api/github_token. Override env so
# Node's os.homedir() resolves to the installing user's home.
& $nssm set $ServiceName AppEnvironmentExtra "USERPROFILE=$UserHome" "HOME=$UserHome" | Out-Null
# Logs: rotate at 5 MB online (no service restart), keep rotated copies in place.
& $nssm set $ServiceName AppStdout         (Join-Path $LogDir 'copilot-api.log') | Out-Null
& $nssm set $ServiceName AppStderr         (Join-Path $LogDir 'copilot-api.log') | Out-Null
& $nssm set $ServiceName AppRotateFiles    1 | Out-Null
& $nssm set $ServiceName AppRotateOnline   1 | Out-Null
& $nssm set $ServiceName AppRotateBytes    5242880 | Out-Null
# Auto-restart on crash with a 1s throttle.
& $nssm set $ServiceName AppExit Default Restart | Out-Null
& $nssm set $ServiceName AppRestartDelay 1000 | Out-Null

Start-Service -Name $ServiceName

# Wait for /v1/models
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest "http://localhost:$Port/v1/models" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) {
    Warn "Service did not become reachable on port $Port within 30s. Check logs:"
    Warn "  $LogDir\copilot-api.log"
    Die  "Service '$ServiceName' is registered but not responding."
}
Ok "Service running: http://localhost:$Port"

# ---------- 8. Claude Code CLI ----------
# We're elevated here, so a `npm install -g` would install into the admin's
# %AppData%\npm rather than the invoking user's. Detect cross-account
# elevation by comparing the elevated env to $UserHome, and pin npm's prefix
# to the user's npm dir so `claude` lands on *their* PATH.
if (-not $SkipClaudeCode) {
    $npmPrefixUser = Join-Path $UserHome 'AppData\Roaming\npm'
    if ($env:USERPROFILE -ne $UserHome) {
        $env:npm_config_prefix = $npmPrefixUser
    }
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Ok "claude CLI present: $((Get-Command claude).Source)"
    } else {
        Info "Installing @anthropic-ai/claude-code globally (prefix=$npmPrefixUser)..."
        & npm --prefix $npmPrefixUser install -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $npmPrefixUser 'claude.cmd'))) {
            Warn 'npm install reported success but claude.cmd not found. Restart your shell and try `ccp`.'
        } else {
            Ok "claude installed: $npmPrefixUser\claude.cmd"
        }
    }
}

# ---------- 9. ccp on PATH ----------
if (-not $SkipPath) {
    Info "Deploying ccp.ps1 and ccp.cmd to $BinDir ..."
    Invoke-WebRequest -Uri "$PagesBaseUrl/ccp.ps1" -OutFile (Join-Path $BinDir 'ccp.ps1') -UseBasicParsing
    Invoke-WebRequest -Uri "$PagesBaseUrl/ccp.cmd" -OutFile (Join-Path $BinDir 'ccp.cmd') -UseBasicParsing

    # Add $BinDir to user PATH (HKCU\Environment of the *invoking* user, not
    # the admin we elevated to). When elevated to a different account we have
    # to use the registry SID hive directly; for same-user UAC the standard
    # [Environment]::SetEnvironmentVariable('Path',...,'User') is correct.
    if ($env:USERPROFILE -eq $UserHome) {
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
    } else {
        Warn "Cross-account elevation detected. Manually add $BinDir to PATH of $UserHome."
    }
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
                Info "Removed legacy gc2cc block from $profilePath."
            }
        }
    }
}

# ---------- 10. summary ----------
Write-Host ''
Ok 'gc2cc install complete.'
Write-Host ''
Write-Host ('  service     : {0}' -f $ServiceName)
Write-Host ('  proxy URL   : http://localhost:{0}' -f $Port)
Write-Host ('  proxy repo  : {0}' -f $ProxyDir)
Write-Host ('  logs        : {0}' -f $LogDir)
Write-Host ''
Write-Host '  ccp is now on PATH for new shells (PS5.1, PS7, cmd, VSCode terminal).'
Write-Host '  Open a fresh window, then try:'
Write-Host '    ccp          # pick a Copilot-backed model, then claude'
Write-Host ''
Write-Host '  Service controls (admin):'
Write-Host ('    Get-Service     {0}' -f $ServiceName)
Write-Host ('    Restart-Service {0}' -f $ServiceName)
Write-Host ('    Stop-Service    {0}' -f $ServiceName)
Write-Host ''
