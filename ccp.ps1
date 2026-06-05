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

# Sort key: family bucket first (smaller = higher priority), then version
# descending within bucket (so claude-opus-4.8 outranks 4.7 automatically when
# GitHub rolls out new SKUs -- no ccp edit needed). Final tiebreak is the raw
# id string (handled by the caller's secondary Sort-Object), which keeps
# variants like `-high`/`-xhigh`/`[1m]` clustered next to their base id.
function Get-ModelRank($id) {
    $tier = switch -regex ($id) {
        '^claude-opus-'     { 100; break }
        '^gpt-5(?:\.\d+)?-codex' { 800; break }
        '^gpt-5(?:\.\d+)?-mini'  { 700; break }
        '^gpt-5-mini'       { 700; break }
        '^gpt-5\.'          { 200; break }
        '^claude-sonnet-'   { 300; break }
        '^gemini-3\.'       { 400; break }
        '^gemini-'          { 500; break }
        '^claude-haiku-'    { 600; break }
        '^gpt-4\.'          { 900; break }
        default             { 999 }
    }
    $major = 0; $minor = 0
    if ($id -match '(?:opus|sonnet|haiku|gpt|gemini)-(\d+)(?:\.(\d+))?') {
        $major = [int]$matches[1]
        if ($matches[2]) { $minor = [int]$matches[2] }
    }
    # tier * 10000 keeps families disjoint; (1000 - major*100 - minor) inverts
    # version order so 4.8 sorts before 4.7 under an ascending Sort-Object.
    return $tier * 10000 + (1000 - $major * 100 - $minor)
}

# /v1/models lists everything the upstream Copilot account can see, including
# embeddings and Microsoft-internal routers. We just drop the non-chat noise
# and pass the ids through verbatim.
#
# About the `[1m]` suffix: caozhiyuan/copilot-api PR #231 appends `[1m]` to
# the model id in `/v1/models` whenever the upstream Copilot capability
# reports `max_context_window_tokens === 1_000_000`. Claude Code reads back
# `/\[1m\]/i` on ANTHROPIC_MODEL to switch its UI/budget into 1M-context
# mode, then strips the `[1m]` marker before sending the request -- so an
# id like `claude-opus-4.7-1m-internal[1m]` arrives upstream as the bare
# `claude-opus-4.7-1m-internal`, which is the real 1M-capable SKU.
#
# Earlier revisions of this script stripped `-1m` / `-1m-internal` /
# `-high` / `-xhigh` and emitted a synthesized `<base>[1m]` entry. That
# broke 1M context: Claude Code would send the bare base id (e.g.
# `claude-opus-4.7`), which is the 200k SKU, and the upstream would
# enforce its standard ~168k prompt limit -- exactly the
# `prompt token count exceeds the limit of 168000` error this script
# was supposed to enable users to avoid. Don't reintroduce stripping.
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

    $models = ($raw | ConvertFrom-Json).data | ForEach-Object {
        if ($dropOwners -contains $_.owned_by) { return }
        foreach ($p in $drop) { if ($_.id -match $p) { return } }
        [pscustomobject]@{
            id    = $_.id
            owner = $_.owned_by
            ctx   = $_.capabilities.limits.max_context_window_tokens
        }
    } | Sort-Object id -Unique

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

    # Auto-compact: Claude Code's built-in threshold is derived from the
    # *known* context window of canonical Anthropic model ids. Our routed
    # ids (`claude-opus-4.8`, `claude-opus-4.7-1m-internal[1m]`, `gpt-5.5`,
    # etc.) aren't in that table, so the threshold either never fires or
    # fires at the wrong size. Pin it explicitly via
    # CLAUDE_CODE_AUTO_COMPACT_WINDOW (the binary documents it as "set and
    # takes precedence"), at 80% of the upstream-advertised window.
    #
    # We pull max_context_window_tokens from /v1/models so new SKUs (1m
    # variants, gpt-5.5's 1.05M window, etc.) get the right threshold
    # without ccp edits. Falls back to 200k for unknowns.
    $ctx = $null
    try {
        $entry = (Get-AvailableModels) | Where-Object { $_.id -eq $mainModel } | Select-Object -First 1
        if ($entry -and $entry.ctx) { $ctx = [int]$entry.ctx }
    } catch {}
    if (-not $ctx) { $ctx = 200000 }
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string][int]($ctx * 0.8)

    $bypassNote = if ($cfg.bypassPermissions) { 'on' } else { 'off' }
    Write-Host ('[ccp] main={0}  small={1}  bypass={2}  autoCompactAt={3}' -f $mainModel, $small, $bypassNote, $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) -ForegroundColor Cyan
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
