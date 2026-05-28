#Requires -Version 5.1
<#
.SYNOPSIS
    Installs gc2cc: GitHub Copilot -> Claude Code bridge on Windows.

.DESCRIPTION
    - Installs prereqs (git, node) via winget if missing. (No longer needs bun.)
    - Installs caozhiyuan/copilot-api globally via npm (`@jeffreycao/copilot-api`).
    - Runs the interactive GitHub Copilot device-code auth flow once.
    - Registers a Windows Service `gc2cc-copilot-api` via NSSM that runs the
      proxy as LocalSystem, auto-restarts on crash, and rotates logs natively.
    - Installs @anthropic-ai/claude-code globally.
    - Drops `ccp.ps1` + `ccp.cmd` into %LOCALAPPDATA%\gc2cc\bin\ and adds that
      dir to user PATH so `ccp` works from any shell (PS5.1, PS7, cmd, VSCode).

    Upgrade-safe: removes legacy Scheduled Task (pre-NSSM), legacy bakapiano
    git clone (pre-caozhiyuan), and stops + re-registers the NSSM service so
    re-running install over any prior gc2cc install converges cleanly.

.NOTES
    Requires Administrator (NSSM service registration writes to HKLM and the SCM).
    The script self-elevates via UAC if launched non-elevated. Re-runs are idempotent.
#>
[CmdletBinding()]
param(
    [int]    $Port         = 4141,
    [string] $ServiceName  = 'gc2cc-copilot-api',
    [string] $InstallDir   = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [string] $NpmPackage   = '@jeffreycao/copilot-api@latest',
    [string] $PagesBaseUrl = 'https://bakapiano.github.io/gc2cc',
    # Primary: vendored zip on our own GitHub Release (byte-identical mirror
    # of the upstream zip from nssm.cc, which 503s frequently). Fallback: the
    # upstream URL itself, in case we ever lose the release.
    [string] $NssmZipUrl   = 'https://github.com/bakapiano/gc2cc/releases/download/nssm-2.24/nssm-2.24.zip',
    [string] $NssmUpstreamUrl = 'https://nssm.cc/release/nssm-2.24.zip',
    [string] $UserHome     = $env:USERPROFILE,
    [switch] $SkipAuth,
    [switch] $SkipClaudeCode,
    [switch] $SkipPath,
    # Comma-separated list of CLIs to install: ccp,cxp. Defaults to interactive
    # picker (unless -NonInteractive is set, in which case it defaults to both).
    # Pass 'none' to skip CLI install entirely (proxy-only). Sentinel default
    # '__ASK__' distinguishes "user did not pass the flag" from "user passed
    # empty string" -- a plain [string] $InstallClis = $null silently becomes
    # '' due to PS type coercion, so `$null -eq $InstallClis` never triggers
    # and the menu would be skipped on `irm | iex` (no positional args).
    [string] $InstallClis    = '__ASK__',
    [switch] $NonInteractive
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

# Ask which CLIs to install BEFORE self-elevation. Doing it pre-UAC means the
# prompt appears in the *user's* original shell where they can actually see
# the menu and use the keyboard; the elevated child window often steals focus
# and runs in a fresh non-interactive context. The selection is forwarded to
# the elevated child via -InstallClis.
if ($InstallClis -eq '__ASK__') {
    if ($NonInteractive) {
        $InstallClis = 'ccp,cxp'
    } else {
        Write-Host ''
        Write-Host '[gc2cc] Which CLI wrappers do you want installed?' -ForegroundColor Cyan
        Write-Host '  [1] ccp  -- Claude Code  (claude --dangerously-skip-permissions)'
        Write-Host '  [2] cxp  -- OpenAI Codex CLI  (zero-pollution: isolated CODEX_HOME)'
        Write-Host '  [3] both (default)'
        Write-Host '  [0] none (proxy-only, no wrapper)'
        $pick = Read-Host 'Select [Enter=3]'
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '3' }
        switch ($pick.Trim()) {
            '0' { $InstallClis = 'none' }
            '1' { $InstallClis = 'ccp' }
            '2' { $InstallClis = 'cxp' }
            '3' { $InstallClis = 'ccp,cxp' }
            default {
                Warn "Unrecognized choice '$pick'; defaulting to both."
                $InstallClis = 'ccp,cxp'
            }
        }
        Write-Host ''
    }
}
$cliSet = @($InstallClis -split '[,;\s]+' | Where-Object { $_ -and $_ -ne 'none' } | ForEach-Object { $_.ToLower() })
$WantCcp = $cliSet -contains 'ccp'
$WantCxp = $cliSet -contains 'cxp'

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
                 '-NpmPackage',"`"$NpmPackage`"",
                 '-PagesBaseUrl',$PagesBaseUrl,
                 '-NssmZipUrl',$NssmZipUrl,
                 '-NssmUpstreamUrl',$NssmUpstreamUrl,
                 '-UserHome',"`"$UserHome`"")
    if ($SkipAuth)       { $argList += '-SkipAuth' }
    if ($SkipClaudeCode) { $argList += '-SkipClaudeCode' }
    if ($SkipPath)       { $argList += '-SkipPath' }
    if ($NonInteractive) { $argList += '-NonInteractive' }
    $argList += @('-InstallClis', "`"$InstallClis`"")
    Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return
}

# ---------- 1. layout ----------
$LogDir = Join-Path $InstallDir 'logs'
$BinDir = Join-Path $InstallDir 'bin'

New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir, $BinDir | Out-Null

# Capture elevated install output for post-mortem debugging if anything fails.
$installTranscript = Join-Path $LogDir 'install.log'
try { Start-Transcript -Path $installTranscript -Force -ErrorAction Stop | Out-Null } catch {}
Info "Install root: $InstallDir (elevated as $env:USERNAME, pinned to $UserHome)"

# Aggregate install counter -- fetched only here in the elevated branch so the
# UAC parent + elevated child don't double-count. Pure hit counter: the asset's
# GitHub download count is the metric, no telemetry / no user info collected.
# Best-effort: any failure is silent so an offline install still proceeds.
try {
    Invoke-WebRequest -Uri 'https://github.com/bakapiano/gc2cc/releases/download/install-counter/gc2cc-install-counter.txt' `
        -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop | Out-Null
} catch {}

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
Ensure-Cmd 'node'   { winget install --id OpenJS.NodeJS -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
# git is no longer required (we used to git clone bakapiano), but is harmless
# if already present. Don't install it just for gc2cc.

# ---------- 3. nssm ----------
# Our GitHub Release hosts a vendored copy of nssm-2.24.zip; upstream nssm.cc
# is the fallback because it 503s often.
$nssm = Join-Path $BinDir 'nssm.exe'
if (-not (Test-Path $nssm)) {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $sources = @($NssmZipUrl, $NssmUpstreamUrl)
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

# ---------- 4. install copilot-api globally (replaces the old git clone) ----------
# We install into a *system-wide* npm prefix under $InstallDir so the NSSM
# service running as LocalSystem can always find the CLI on a known path,
# without depending on the user's per-account npm prefix.
$NpmRoot   = Join-Path $InstallDir 'npm'
$NpmGlobal = Join-Path $NpmRoot 'global'
$NpmCache  = Join-Path $NpmRoot 'cache'
New-Item -ItemType Directory -Force -Path $NpmGlobal, $NpmCache | Out-Null

Info "Installing $NpmPackage into $NpmGlobal ..."
# --prefix scopes the global install to our directory. Suppress fund/audit
# noise; -s would also suppress real errors so we keep them.
#
# npm writes warnings (unknown config keys, deprecations) to stderr. PS 5.1
# with ErrorActionPreference=Stop promotes that stderr write to a terminating
# NativeCommandError that kills the install before we can check $LASTEXITCODE.
# Locally relax to Continue and rely on the exit code for the real verdict.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & npm install -g $NpmPackage `
        --prefix $NpmGlobal `
        --cache $NpmCache `
        --no-fund --no-audit 2>&1 | Out-Null
} finally {
    $ErrorActionPreference = $prev
}
if ($LASTEXITCODE -ne 0) {
    Die "npm install $NpmPackage failed (exit=$LASTEXITCODE). See $installTranscript."
}

# The .cmd shim Windows uses; this is what NSSM ultimately exec's via node.exe
$copilotCmd = Join-Path $NpmGlobal 'copilot-api.cmd'
if (-not (Test-Path $copilotCmd)) {
    # Some npm versions on Windows install under node_modules/.bin instead.
    $alt = Join-Path $NpmGlobal 'node_modules\.bin\copilot-api.cmd'
    if (Test-Path $alt) { $copilotCmd = $alt }
}
if (-not (Test-Path $copilotCmd)) { Die "copilot-api shim not found under $NpmGlobal after install" }

# The actual JS entrypoint -- we exec node + this directly under NSSM (cleaner
# process tree than going through a .cmd shim under a service).
$copilotEntry = Join-Path $NpmGlobal 'node_modules\@jeffreycao\copilot-api\dist\main.js'
if (-not (Test-Path $copilotEntry)) {
    # Fallback: walk the .cmd shim to find what it execs.
    $copilotEntry = $null
    Warn "Expected entry $($copilotEntry) not found; service will exec via .cmd shim instead."
}
Ok "copilot-api installed: $copilotCmd"

$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { Die "node.exe not on PATH even after Ensure-Cmd; aborting." }

# ---------- 5. GitHub Copilot auth (interactive, once) ----------
# Token lives under the *invoking* user's home; both bakapiano and caozhiyuan
# use the same default path (~/.local/share/copilot-api/github_token), so an
# existing auth from a previous gc2cc install carries over with no re-login.
$TokenPath = Join-Path $UserHome '.local\share\copilot-api\github_token'
$tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
if (-not $SkipAuth -and -not $tokenOk) {
    Write-Host ''
    Info 'Running GitHub Copilot device-code auth flow...'
    Info 'When prompted, open the URL in a browser and paste the code.'
    Write-Host ''
    # Force HOME/USERPROFILE in case of cross-account UAC elevation, so the
    # token lands in the invoking user's home rather than the admin's.
    $env:USERPROFILE = $UserHome
    $env:HOME        = $UserHome
    & $nodeExe $copilotEntry auth
    $tokenOk = (Test-Path $TokenPath) -and ((Get-Item $TokenPath).Length -gt 0)
    if (-not $tokenOk) { Die "Auth did not complete; token still missing at $TokenPath" }
    Ok 'GitHub token captured.'
} else {
    Ok "Auth token already present at $TokenPath"
}

# ---------- 6. migrate from older gc2cc installs ----------
# 6a. Legacy Scheduled Task (pre-NSSM, eb38450..b0f7874)
foreach ($p in @('\gc2cc\','\')) {
    $task = Get-ScheduledTask -TaskName $ServiceName -TaskPath $p -ErrorAction SilentlyContinue
    if ($task) {
        Info "Removing legacy Scheduled Task '$p$ServiceName' ..."
        try { Stop-ScheduledTask -TaskName $ServiceName -TaskPath $p -ErrorAction SilentlyContinue } catch {}
        try {
            Unregister-ScheduledTask -TaskName $ServiceName -TaskPath $p -Confirm:$false -ErrorAction Stop
            Ok "legacy task at $p removed"
        } catch {
            Warn "Could not remove legacy task '$p$ServiceName': $_"
        }
    }
}
# 6b. Legacy bakapiano git-clone tree + old wrapper scripts. Free disk and
# stop confusing future debugging -- once switched to npm we never go back.
foreach ($legacy in @(
    (Join-Path $InstallDir 'copilot-api'),
    (Join-Path $InstallDir 'run-proxy.ps1'),
    (Join-Path $InstallDir 'run-proxy.vbs')
)) {
    if (Test-Path $legacy) {
        Info "Removing legacy artifact: $legacy"
        Remove-Item -Recurse -Force $legacy -ErrorAction SilentlyContinue
    }
}

# ---------- 7. NSSM service ----------
# Stop & remove any prior gc2cc service (idempotent re-run, including upgrade
# from the previous bun-based service definition -- args + binary change).
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Info "Stopping and removing existing service '$ServiceName' ..."
    & $nssm stop   $ServiceName confirm | Out-Null
    & $nssm remove $ServiceName confirm | Out-Null
    Start-Sleep -Milliseconds 500
}

# Free the port defensively (a stale node/bun could still be squatting).
$squatters = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
foreach ($c in $squatters) {
    $pp = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    Info "Freeing port ${Port}: killing PID=$($c.OwningProcess) name=$($pp.ProcessName)"
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}
if ($squatters) { Start-Sleep -Milliseconds 500 }

Info "Registering service '$ServiceName' (port $Port) via NSSM..."
# Service exec'd: node.exe <copilot-api dist/main.js> start --port <port>
& $nssm install     $ServiceName $nodeExe $copilotEntry start --port $Port | Out-Null
& $nssm set $ServiceName AppDirectory  $InstallDir | Out-Null
& $nssm set $ServiceName DisplayName   'gc2cc Copilot API proxy' | Out-Null
& $nssm set $ServiceName Description   'GitHub Copilot -> OpenAI/Anthropic proxy (caozhiyuan/copilot-api @jeffreycao/copilot-api)' | Out-Null
& $nssm set $ServiceName Start         SERVICE_AUTO_START | Out-Null
& $nssm set $ServiceName ObjectName    LocalSystem | Out-Null
# Service runs as LocalSystem, whose default USERPROFILE points at systemprofile
# and doesn't see ~/.local/share/copilot-api/github_token. Override env so
# Node's os.homedir() resolves to the installing user's home.
& $nssm set $ServiceName AppEnvironmentExtra `
    "USERPROFILE=$UserHome" `
    "HOME=$UserHome" `
    "NODE_OPTIONS=--no-warnings" | Out-Null
# NSSM-native log rotation (5 MB, online, no service restart).
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
# We're elevated here, so plain `npm install -g` would land in the admin
# profile's prefix. Pin npm's prefix to the invoking user's npm dir so
# `claude` / `codex` end up on *their* PATH.
$npmPrefixUser = Join-Path $UserHome 'AppData\Roaming\npm'
if ($env:USERPROFILE -ne $UserHome) {
    $env:npm_config_prefix = $npmPrefixUser
}

function Install-NpmCli {
    param([string]$Pkg, [string]$BinName)
    if (Get-Command $BinName -ErrorAction SilentlyContinue) {
        Ok "$BinName CLI present: $((Get-Command $BinName).Source)"
        return
    }
    Info "Installing $Pkg globally (prefix=$npmPrefixUser)..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & npm --prefix $npmPrefixUser install -g $Pkg 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not (Test-Path (Join-Path $npmPrefixUser "$BinName.cmd"))) {
        Warn "npm install $Pkg reported success but $BinName.cmd not found. Restart your shell."
    } else {
        Ok "$BinName installed: $npmPrefixUser\$BinName.cmd"
    }
}

if ($WantCcp -and -not $SkipClaudeCode) {
    Install-NpmCli -Pkg '@anthropic-ai/claude-code' -BinName 'claude'
}

# ---------- 8b. Codex CLI + isolated CODEX_HOME ----------
# Zero-pollution principle: gc2cc maintains its own CODEX_HOME under InstallDir,
# so the user's ~/.codex/config.toml (if any) is never read or written by cxp.
# The provider definition points at the local copilot-api proxy with the
# Responses wire API (the only one codex supports as of 2025+).
if ($WantCxp) {
    Install-NpmCli -Pkg '@openai/codex' -BinName 'codex'

    $CodexHome = Join-Path $InstallDir 'codex-home'
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $codexCfgPath = Join-Path $CodexHome 'config.toml'
    $codexCfg = @"
# gc2cc-managed Codex config -- DO NOT EDIT BY HAND.
# Activated only when CODEX_HOME points at this directory (set by cxp.ps1).
# Your own ~/.codex/config.toml is unaffected.

model_provider = "gc2cc"
model = "gpt-5.5"
# Quiet sandbox defaults so codex runs interactively without prompting on every
# tool call. Adjust via `cxp` flags or by editing this file if you regenerate.
approval_policy = "on-failure"

[model_providers.gc2cc]
name = "gc2cc copilot-api"
base_url = "http://localhost:$Port/v1"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
requires_openai_auth = false
"@
    Set-Content -Path $codexCfgPath -Value $codexCfg -Encoding UTF8
    Ok "codex config written: $codexCfgPath"
}

# ---------- 9. ccp / cxp wrappers on PATH ----------
if (-not $SkipPath) {
    $wrapperBases = @()
    if ($WantCcp) { $wrapperBases += 'ccp' }
    if ($WantCxp) { $wrapperBases += 'cxp' }

    foreach ($w in $wrapperBases) {
        Info "Deploying $w.ps1 and $w.cmd to $BinDir ..."
        # Prefer same-directory local copies (developer iteration before publish);
        # fall back to fetching from Pages.
        $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
        foreach ($ext in @('ps1','cmd')) {
            $dst = Join-Path $BinDir "$w.$ext"
            $localSrc = if ($scriptRoot) { Join-Path $scriptRoot "$w.$ext" } else { $null }
            if ($localSrc -and (Test-Path $localSrc)) {
                Copy-Item $localSrc $dst -Force
            } else {
                Invoke-WebRequest -Uri "$PagesBaseUrl/$w.$ext" -OutFile $dst -UseBasicParsing
            }
        }
    }

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

    # Strip any legacy gc2cc remnants from $PROFILE. Very old installs put
    # `ccp` (and later `cxp`) into $PROFILE as functions / aliases; the
    # PATH-mounted scripts under $BinDir supersede them, but a function in
    # $PROFILE wins over a PATH command and will silently shadow the new
    # version -- so any reinstall must scrub the profile clean.
    #
    # We strip three shapes, defensively, in case the user has hand-edited:
    #   1. Sentinel block: `# >>> gc2cc ... BEGIN ... # <<< gc2cc ... END`
    #   2. Standalone `function ccp { ... }` / `function cxp { ... }` blocks
    #   3. Single-line `Set-Alias ccp ...` / `New-Alias cxp ...`
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing) {
            $cleaned = $existing
            # 1. Sentinel block (both legacy `gc2cc ccp` and any future cxp variant)
            $cleaned = [Regex]::Replace($cleaned,
                '# >>> gc2cc[^\r\n]*BEGIN[\s\S]*?# <<< gc2cc[^\r\n]*END\r?\n?', '')
            # 2. Standalone function ccp / cxp (multi-line, brace-balanced assumed)
            $cleaned = [Regex]::Replace($cleaned,
                '(?ms)^\s*function\s+(ccp|cxp)\b.*?^\}\s*\r?\n?', '')
            # 3. Set-Alias / New-Alias lines for ccp / cxp
            $cleaned = (($cleaned -split "`r?`n") |
                Where-Object { $_ -notmatch '^\s*(Set-Alias|New-Alias)\s+(-Name\s+)?(ccp|cxp)\b' }) -join "`r`n"
            $cleaned = $cleaned.TrimEnd()
            if ($cleaned -ne $existing.TrimEnd()) {
                Set-Content -Path $profilePath -Value $cleaned -Encoding UTF8
                Info "Removed legacy gc2cc ccp/cxp definitions from $profilePath."
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
Write-Host ('  proxy pkg   : {0}' -f $NpmPackage)
Write-Host ('  proxy entry : {0}' -f $copilotEntry)
Write-Host ('  logs        : {0}' -f $LogDir)
Write-Host ''
$wrapperList = @()
if ($WantCcp) { $wrapperList += 'ccp' }
if ($WantCxp) { $wrapperList += 'cxp' }
if ($wrapperList.Count -gt 0) {
    Write-Host ('  wrappers    : {0}' -f ($wrapperList -join ', '))
    Write-Host '  Open a fresh window, then try:'
    if ($WantCcp) { Write-Host '    ccp          # Claude Code via Copilot' }
    if ($WantCxp) { Write-Host '    cxp          # OpenAI Codex via Copilot' }
} else {
    Write-Host '  wrappers    : (none -- proxy-only install)'
}
Write-Host ''
Write-Host '  Service controls (admin):'
Write-Host ('    Get-Service     {0}' -f $ServiceName)
Write-Host ('    Restart-Service {0}' -f $ServiceName)
Write-Host ('    Stop-Service    {0}' -f $ServiceName)
Write-Host ''
