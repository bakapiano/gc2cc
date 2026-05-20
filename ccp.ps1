# ccp -- claude YOLO mode routed through caozhiyuan/copilot-api on http://localhost:4141.
# PATH-mounted standalone script (no profile required). Works the same in PS5.1,
# PS7, and any host: drop it under %LOCALAPPDATA%\gc2cc\bin\ (added to user PATH
# by gc2cc/install.ps1), and `ccp ...` resolves from any shell.
#
# Usage:
#   ccp [-Model <id>] [claude args...]   Launch claude with chosen model.
#                                        Without -Model, uses defaultModel from
#                                        config if set, otherwise prompts.
#   ccp config                           Interactive: pick default model and
#                                        toggle --dangerously-skip-permissions.
#   ccp upgrade                          Re-run the gc2cc one-liner installer
#                                        (irm | iex from Pages, self-elevates).
#   ccp --help                           Show usage.
#
# Config: ~/.local/share/gc2cc/ccp.json
#   {
#     "defaultModel": "claude-opus-4.7",   // null = always prompt
#     "bypassPermissions": true             // pass --dangerously-skip-permissions
#   }

$base       = 'http://localhost:4141'
$pagesBase  = 'https://bakapiano.github.io/gc2cc'
$configPath = Join-Path $HOME '.local\share\gc2cc\ccp.json'

# ---------- config ----------
function Load-CcpConfig {
    # User-facing keys: defaultModel, bypassPermissions
    # Internal cache keys (managed by Test-UpdateAvailable / Invoke-CcpUpgrade,
    # not surfaced in `ccp config`): updateCheckAt, updateAvailable
    $defaults = @{
        defaultModel      = $null
        bypassPermissions = $true
        updateCheckAt     = $null
        updateAvailable   = $false
    }
    if (-not (Test-Path $configPath)) { return $defaults }
    try {
        $loaded = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning "[ccp] $configPath is invalid JSON; using defaults"
        return $defaults
    }
    foreach ($k in 'defaultModel','bypassPermissions','updateCheckAt','updateAvailable') {
        if ($loaded.PSObject.Properties.Name -contains $k) {
            $defaults[$k] = $loaded.$k
        }
    }
    return $defaults
}

function Save-CcpConfig($cfg) {
    $dir = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

# ---------- update check (24h-cached) ----------
# Use .NET's SHA256 directly rather than Get-FileHash -- some Win11 builds
# ship Microsoft.PowerShell.Utility 3.1.0.0 without the Get-FileHash cmdlet
# (observed on Win11 26100 in the wild).
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToUpper() }
    finally { $sha.Dispose() }
}

function Get-OnlineCcpHash {
    try {
        $resp = Invoke-WebRequest "$pagesBase/ccp.ps1" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        $bytes = $resp.Content
        if ($bytes -isnot [byte[]]) { $bytes = [Text.Encoding]::UTF8.GetBytes($bytes) }
        return Get-Sha256Hex $bytes
    } catch { return $null }
}

function Get-LocalCcpHash {
    if (-not $PSCommandPath -or -not (Test-Path $PSCommandPath)) { return $null }
    return Get-Sha256Hex ([System.IO.File]::ReadAllBytes($PSCommandPath))
}

# Returns $true if the online ccp.ps1 has a different hash than the local one.
# Caches the result in ccp.json for 24h to keep ccp startup snappy. Any network
# error falls back to "no update" silently -- update check shouldn't block ccp.
function Test-UpdateAvailable($cfg) {
    $now = (Get-Date).ToUniversalTime()
    if ($cfg.updateCheckAt) {
        try {
            $lastCheck = [datetime]::Parse($cfg.updateCheckAt).ToUniversalTime()
            if (($now - $lastCheck).TotalHours -lt 24 -and ($now - $lastCheck).TotalHours -ge 0) {
                return [bool]$cfg.updateAvailable
            }
        } catch {}
    }
    $online = Get-OnlineCcpHash
    if (-not $online) { return [bool]$cfg.updateAvailable }  # network down: keep prior state
    $local = Get-LocalCcpHash
    $available = ($local -and ($online -ne $local))
    $cfg.updateCheckAt   = $now.ToString('o')
    $cfg.updateAvailable = $available
    try { Save-CcpConfig $cfg } catch {}  # best-effort; don't fail ccp on disk error
    return $available
}

# ---------- proxy + model discovery ----------
function Test-Proxy {
    try {
        Invoke-WebRequest "$base/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

# Heuristic small/fast model by family. Keeps main and small in the same
# tokenizer space so token accounting stays consistent.
function Pick-Small($id) {
    switch -regex ($id) {
        '^claude-' { return 'claude-haiku-4.5' }
        '^gpt-5'   { return 'gpt-5-mini' }
        '^gpt-4'   { return 'gpt-4o-mini' }
        '^gemini-' { return 'gemini-3-flash-preview' }
        default    { return 'gpt-5-mini' }
    }
}

# Sort key: preferred families bubble to the top, then by id.
function Get-ModelRank($id) {
    switch -regex ($id) {
        '^claude-opus-4\.7'  { return 0 }
        '^claude-opus-4\.6'  { return 1 }
        '^gpt-5\.5'          { return 2 }
        '^gpt-5\.4'          { return 3 }
        '^gpt-5\.3'          { return 4 }
        '^gpt-5\.2'          { return 5 }
        '^claude-sonnet-4\.' { return 6 }
        '^gemini-3\.'        { return 7 }
        '^gemini-'           { return 8 }
        '^claude-haiku-'     { return 9 }
        '^gpt-5-mini'        { return 10 }
        '^gpt-4\.'           { return 11 }
        default              { return 99 }
    }
}

# /v1/models lists everything the upstream Copilot account can see, including
# embeddings and Microsoft-internal routers. This returns just the chat-useful
# subset, with [1m]/-1m/-1m-internal/-high/-xhigh suffixes canonicalized, and
# a separate `base[1m]` entry emitted when the base model has a 1M-capable
# upstream variant. Per caozhiyuan's README warning:
#   "When using with Claude Code, please configure the model ID as
#   `claude-opus-4-6` or `claude-opus-4.6` (without the `[1m]` suffix,
#   exceeding GitHub Copilot's context window limit too much may lead to
#   being banned)."
# So the bare id is always the default (sorted first); the [1m] variant is
# only shown for users who explicitly want 1M context.
function Get-AvailableModels {
    $raw = (Invoke-WebRequest "$base/v1/models" -TimeoutSec 4 -UseBasicParsing).Content
    $drop = @(
        '^accounts/msft/',                       # router shims
        '^text-embedding-',                      # embeddings
        '-embedding\b', '-inference$',           # other embedding namings
        '^gpt-3\.5', '^gpt-4-0', '^gpt-4-o-',    # ancient chat models
        '^gpt-4o-2024-', '^gpt-4o-mini-2024-', '^gpt-4\.1-2025-',  # dated snapshots
        '^gpt-4$',                               # plain gpt-4 (ancient)
        '^gpt-41-copilot$',                      # legacy GH-internal
        '^claude-(opus|sonnet)-4\.5$',           # superseded by 4.6/4.7
        '^gemini-2\.5-'                          # superseded by 3.x
    )
    $dropOwners  = @('Experimental','Fireworks')
    $stripSuffix = '(?:\[1m\]|-1m(?:-internal)?|-(high|xhigh))$'
    $is1mRe      = '(?:\[1m\]|-1m(?:-internal)?)'

    $entries = ($raw | ConvertFrom-Json).data | ForEach-Object {
        if ($dropOwners -contains $_.owned_by) { return }
        foreach ($p in $drop) { if ($_.id -match $p) { return } }
        $clean = $_.id
        while ($clean -match $stripSuffix) { $clean = $clean -replace $stripSuffix, '' }
        [pscustomobject]@{
            id    = $clean
            owner = $_.owned_by
            is1m  = ($_.id -match $is1mRe)
        }
    } | Sort-Object id, is1m -Unique

    $baseModels = $entries | Group-Object id | ForEach-Object { $_.Group[0] }
    $has1m = @{}
    foreach ($e in $entries) { if ($e.is1m) { $has1m[$e.id] = $true } }
    $models = @()
    foreach ($m in $baseModels) {
        $models += [pscustomobject]@{ id = $m.id; owner = $m.owner }
        if ($has1m.ContainsKey($m.id)) {
            $models += [pscustomobject]@{ id = "$($m.id)[1m]"; owner = $m.owner }
        }
    }
    return ,($models | Sort-Object @{e={Get-ModelRank $_.id}}, id)
}

# ---------- subcommands ----------
function Show-Help {
    $cur = Load-CcpConfig
    $curDefault = if ($cur.defaultModel) { $cur.defaultModel } else { '(none -- always prompt)' }
    Write-Host @"
ccp -- Claude Code routed through caozhiyuan/copilot-api on $base

Usage:
  ccp [-Model <id>] [claude args...]   Launch claude. -Model skips the picker.
                                       Without -Model, uses defaultModel from
                                       config or prompts via menu.
  ccp config                           Interactive: pick default model and
                                       toggle --dangerously-skip-permissions.
  ccp upgrade                          Re-run the gc2cc one-liner installer
                                       (will trigger UAC).
  ccp --help                           Show this help.

Config file: $configPath
Current settings:
  defaultModel      = $curDefault
  bypassPermissions = $($cur.bypassPermissions)
"@
}

function Invoke-CcpConfig {
    if (-not (Test-Proxy)) {
        Write-Error "[ccp] copilot-api not reachable at $base. Check: Get-Service gc2cc-copilot-api"
        return
    }
    $config = Load-CcpConfig
    $curDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Current config ($configPath):" -ForegroundColor Cyan
    Write-Host ('  defaultModel      = {0}' -f $curDefault)
    Write-Host ('  bypassPermissions = {0}' -f $config.bypassPermissions)
    Write-Host ''

    $models = Get-AvailableModels
    Write-Host 'Pick a default model (Enter to keep current):' -ForegroundColor Cyan
    Write-Host '  [ 0] (none -- always prompt at ccp launch)'
    for ($i = 0; $i -lt $models.Count; $i++) {
        $marker = if ($config.defaultModel -eq $models[$i].id) { ' *current*' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i + 1), $models[$i].id, $marker)
    }
    $pick = Read-Host 'Number'
    if (-not [string]::IsNullOrWhiteSpace($pick)) {
        $idx = [int]$pick - 1
        if ($idx -eq -1) {
            $config.defaultModel = $null
        } elseif ($idx -ge 0 -and $idx -lt $models.Count) {
            $config.defaultModel = $models[$idx].id
        } else {
            Write-Warning '[ccp] invalid choice; keeping current'
        }
    }

    Write-Host ''
    $bypassDefault = if ($config.bypassPermissions) { 'Y' } else { 'N' }
    $bp = Read-Host ('Bypass permissions (--dangerously-skip-permissions)? [Y/N, default {0}]' -f $bypassDefault)
    if (-not [string]::IsNullOrWhiteSpace($bp)) {
        $config.bypassPermissions = ($bp.Trim() -match '^[Yy]')
    }

    Save-CcpConfig $config
    $newDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Saved to $configPath" -ForegroundColor Green
    Write-Host ('  defaultModel      = {0}' -f $newDefault)
    Write-Host ('  bypassPermissions = {0}' -f $config.bypassPermissions)
}

function Invoke-CcpUpgrade {
    Write-Host "[ccp] Fetching latest installer from $pagesBase/install.ps1 ..." -ForegroundColor Cyan
    $b = (Invoke-WebRequest "$pagesBase/install.ps1" -UseBasicParsing).Content
    if ($b -is [byte[]]) { $b = [Text.Encoding]::UTF8.GetString($b) }
    Invoke-Expression $b
    # Clear the staleness flag -- we just upgraded, so the local ccp.ps1 now
    # matches Pages. Without this, the banner would persist until the 24h TTL
    # naturally expires.
    try {
        $cfg = Load-CcpConfig
        $cfg.updateCheckAt   = (Get-Date).ToUniversalTime().ToString('o')
        $cfg.updateAvailable = $false
        Save-CcpConfig $cfg
    } catch {}
}

# ---------- model picker ----------
function Invoke-ModelPicker {
    $models = Get-AvailableModels
    if (-not $models -or $models.Count -eq 0) {
        Write-Warning '[ccp] no models matched after filtering. Falling back to free-form prompt.'
        $main = Read-Host 'Enter model id'
        if ([string]::IsNullOrWhiteSpace($main)) { return $null }
        return $main
    }
    Write-Host ''
    Write-Host 'Pick a model:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ('  [{0,2}] {1}' -f ($i + 1), $models[$i].id)
    }
    $pick = Read-Host 'Number (default 1)'
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $models.Count) {
        Write-Error '[ccp] invalid choice'
        return $null
    }
    return $models[$idx].id
}

# ---------- claude exec ----------
function Invoke-ClaudeWithModel($mainModel, $cfg, $passthrough) {
    $small = Pick-Small $mainModel
    $env:ANTHROPIC_BASE_URL                       = $base
    $env:ANTHROPIC_AUTH_TOKEN                     = 'dummy'
    $env:ANTHROPIC_MODEL                          = $mainModel
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL           = $mainModel
    $env:ANTHROPIC_SMALL_FAST_MODEL               = $small
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL            = $small
    $env:DISABLE_NON_ESSENTIAL_MODEL_CALLS        = '1'
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'

    $bypassNote = if ($cfg.bypassPermissions) { 'on' } else { 'off' }
    Write-Host ('[ccp] main={0}  small={1}  bypass={2}' -f $mainModel, $small, $bypassNote) -ForegroundColor Cyan
    if ($cfg.bypassPermissions) {
        & claude @passthrough --dangerously-skip-permissions
    } else {
        & claude @passthrough
    }
}

# ---------- dispatch ----------
# Subcommand if it's the first positional. Don't shadow claude flags like
# `--help` to claude -- we want OUR --help to show ccp usage. Use a leading
# `claude-` prefix or `--` separator to bypass, e.g.: `ccp -- --help` would
# forward `--help` to claude.
if ($args.Count -gt 0) {
    switch ($args[0]) {
        '--help'  { Show-Help;        return }
        '-h'      { Show-Help;        return }
        '-Help'   { Show-Help;        return }
        'help'    { Show-Help;        return }
        'config'  { Invoke-CcpConfig; return }
        'upgrade' { Invoke-CcpUpgrade; return }
    }
}

# Default flow: parse `-Model <id>` out of args, the rest go to claude. Accept
# -Model / -model / -Mode / -mode for ergonomic flexibility.
$passthrough = @()
$modelOverride = $null
$skipNext = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($skipNext) { $skipNext = $false; continue }
    $a = $args[$i]
    if ($a -in @('-Model','-model','-Mode','-mode')) {
        if ($i + 1 -ge $args.Count) {
            Write-Error '[ccp] -Model requires a value'
            return
        }
        $modelOverride = $args[$i + 1]
        $skipNext = $true
    } elseif ($a -eq '--') {
        # Explicit separator: everything after goes to claude.
        $passthrough += $args[($i + 1)..($args.Count - 1)]
        break
    } else {
        $passthrough += $a
    }
}

if (-not (Test-Proxy)) {
    Write-Error "[ccp] copilot-api not reachable at $base. Check: Get-Service gc2cc-copilot-api"
    return
}

# First-run wizard: if no config file exists, walk through `ccp config` once
# so a placeholder file gets written. Subsequent ccp launches see the file
# and skip straight to the model picker / default. This works even if the
# user accepts all defaults -- the file itself is the signal.
if (-not (Test-Path $configPath)) {
    Write-Host ''
    Write-Host "[ccp] No config found at $configPath -- first-run setup." -ForegroundColor Cyan
    Write-Host "[ccp] You can re-run this any time with 'ccp config'." -ForegroundColor Cyan
    Invoke-CcpConfig
    Write-Host ''
}

$config = Load-CcpConfig

# Show an upgrade banner if the online ccp.ps1 differs from ours. Check is
# cached for 24h so this adds no per-invocation latency in the common case.
if (Test-UpdateAvailable $config) {
    Write-Host "[ccp] gc2cc has updates available -- run 'ccp upgrade' to refresh" -ForegroundColor Yellow
}

$main = $modelOverride
if (-not $main) { $main = $config.defaultModel }
if (-not $main) {
    $main = Invoke-ModelPicker
    if (-not $main) { return }
}

Invoke-ClaudeWithModel -mainModel $main -cfg $config -passthrough $passthrough
