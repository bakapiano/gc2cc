#Requires -Version 5.1
<#
.SYNOPSIS
    Installs gc2cc: GitHub Copilot -> Claude Code bridge on Windows.

.DESCRIPTION
    - Installs prereqs (git, node, bun) via winget if missing.
    - Clones bakapiano/copilot-api at branch feat/1m-suffix into %LOCALAPPDATA%\gc2cc\copilot-api.
    - Runs `bun install` and the interactive GitHub Copilot device-code auth flow (once).
    - Registers an always-on Windows service "gc2cc-copilot-api" via NSSM on port 4141.
    - Installs @anthropic-ai/claude-code globally.
    - Adds the `ccp` PowerShell function to your $PROFILE (idempotent, sentinel-marked).

.NOTES
    Must be run as Administrator (NSSM service registration).
    Re-runs are idempotent: latest fork pulled, service re-created, profile block replaced.
#>
[CmdletBinding()]
param(
    [int]    $Port         = 4141,
    [string] $ServiceName  = 'gc2cc-copilot-api',
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
function Die  ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    [Security.Principal.WindowsPrincipal]::new($id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$m;$u"
}

function Ensure-Cmd {
    param([string]$Name, [scriptblock]$Install)
    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }
    Info "Installing prerequisite: $Name"
    & $Install
    Refresh-Path
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Die "$Name still not on PATH after install. Open a fresh PowerShell as Administrator and re-run."
    }
}

# ---------- 0. preflight ----------
if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host '  gc2cc installer needs Administrator (NSSM service registration).' -ForegroundColor Red
    Write-Host '  Right-click PowerShell -> Run as Administrator, then paste the same one-liner:' -ForegroundColor Yellow
    Write-Host "    irm $PagesBaseUrl/install.ps1 | iex" -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

$BinDir   = Join-Path $InstallDir 'bin'
$ProxyDir = Join-Path $InstallDir 'copilot-api'
$LogDir   = Join-Path $InstallDir 'logs'
$NssmPath = Join-Path $BinDir 'nssm.exe'

New-Item -ItemType Directory -Force -Path $InstallDir, $BinDir, $LogDir | Out-Null
Info "Install root: $InstallDir"

# ---------- 1. prereqs ----------
Ensure-Cmd 'winget' { Die 'winget not found. Install "App Installer" from Microsoft Store, then retry.' }
Ensure-Cmd 'git'    { winget install --id Git.Git       -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
Ensure-Cmd 'node'   { winget install --id OpenJS.NodeJS -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }
Ensure-Cmd 'bun'    { winget install --id Oven-sh.Bun   -e --silent --accept-package-agreements --accept-source-agreements | Out-Null }

# ---------- 2. NSSM ----------
if (-not (Test-Path $NssmPath)) {
    Info 'Downloading NSSM 2.24...'
    $zip = Join-Path $env:TEMP "nssm-$(Get-Random).zip"
    Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
    $extract = Join-Path $env:TEMP "nssm-extract-$(Get-Random)"
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $src  = Get-ChildItem -Path $extract -Recurse -Filter 'nssm.exe' | Where-Object { $_.FullName -match "\\$arch\\" } | Select-Object -First 1
    if (-not $src) { Die 'nssm.exe not found in downloaded archive' }
    Copy-Item -Path $src.FullName -Destination $NssmPath -Force
    Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
    Ok "NSSM at $NssmPath"
} else {
    Ok 'NSSM already present'
}

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

# ---------- 5. NSSM service ----------
$BunExe = (Get-Command bun).Source
Info "Registering Windows service '$ServiceName' (port $Port)..."

if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
    & $NssmPath stop   $ServiceName 2>&1 | Out-Null
    & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}

& $NssmPath install $ServiceName $BunExe 2>&1 | Out-Null
& $NssmPath set $ServiceName AppParameters       "src/main.ts start --port $Port" 2>&1 | Out-Null
& $NssmPath set $ServiceName AppDirectory        $ProxyDir 2>&1 | Out-Null
& $NssmPath set $ServiceName AppStdout           (Join-Path $LogDir 'copilot-api.out.log') 2>&1 | Out-Null
& $NssmPath set $ServiceName AppStderr           (Join-Path $LogDir 'copilot-api.err.log') 2>&1 | Out-Null
& $NssmPath set $ServiceName AppRotateFiles      1 2>&1 | Out-Null
& $NssmPath set $ServiceName AppRotateBytes      5242880 2>&1 | Out-Null
& $NssmPath set $ServiceName Start               SERVICE_AUTO_START 2>&1 | Out-Null
& $NssmPath set $ServiceName DisplayName         'gc2cc copilot-api proxy' 2>&1 | Out-Null
& $NssmPath set $ServiceName Description         'OpenAI/Anthropic-compatible proxy in front of GitHub Copilot (bakapiano fork, feat/1m-suffix).' 2>&1 | Out-Null

# Service runs as LocalSystem; point USERPROFILE at the installing user so the proxy
# finds the GitHub token at ~/.local/share/copilot-api/github_token.
& $NssmPath set $ServiceName AppEnvironmentExtra "USERPROFILE=$UserHome" "NODE_ENV=production" 2>&1 | Out-Null

& $NssmPath start $ServiceName 2>&1 | Out-Null

# wait for /v1/models
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        Invoke-WebRequest "http://localhost:$Port/v1/models" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) {
    Warn "Service did not become reachable on port $Port within 30s. Check logs:"
    Warn "  $LogDir\copilot-api.err.log"
    Die  "Service '$ServiceName' is registered but not responding."
}
Ok "Service running: http://localhost:$Port"

# ---------- 6. Claude Code CLI ----------
if (-not $SkipClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Ok "claude CLI present: $((Get-Command claude).Source)"
    } else {
        Info 'Installing @anthropic-ai/claude-code globally...'
        npm install -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        Refresh-Path
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
            Warn 'npm install reported success but `claude` not on PATH. Restart your shell and try `cc`.'
        } else {
            Ok "claude installed: $((Get-Command claude).Source)"
        }
    }
}

# ---------- 7. PowerShell profile (ccp) ----------
if (-not $SkipProfile) {
    Info "Installing ccp into $PROFILE ..."
    $snippetUrl = "$PagesBaseUrl/profile-snippet.ps1"
    try {
        $snippet = (Invoke-WebRequest -Uri $snippetUrl -UseBasicParsing).Content
    } catch {
        Die "Could not fetch $snippetUrl : $_"
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
Write-Host ('  service     : {0}' -f $ServiceName)
Write-Host ('  proxy URL   : http://localhost:{0}' -f $Port)
Write-Host ('  proxy repo  : {0}' -f $ProxyDir)
Write-Host ('  logs        : {0}' -f $LogDir)
Write-Host ''
Write-Host '  Open a fresh PowerShell window, then try:'
Write-Host '    ccp          # pick a Copilot-backed model, then claude'
Write-Host ''
Write-Host '  Service controls (Administrator PowerShell):'
Write-Host ('    Get-Service {0}' -f $ServiceName)
Write-Host ('    Restart-Service {0}' -f $ServiceName)
Write-Host ''
