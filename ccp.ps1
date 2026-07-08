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
$script:ccpPipelineInput = if ($MyInvocation.ExpectingInput) { @($input) } else { $null }
# The proxy (copilot-api) reads reasoning effort from ITS OWN config here, keyed
# by bare model id. The NSSM service runs as LocalSystem but install.ps1 pins
# HOME/USERPROFILE to this user, so os.homedir() resolves to $HOME -- we can
# write this file without elevation; only restarting the service needs UAC.
$proxyConfigPath = Join-Path $HOME '.local\share\copilot-api\config.json'
$proxyService    = 'gc2cc-copilot-api'

# ---------- config ----------
function Load-CcpConfig {
    # User-facing keys: defaultModel, bypassPermissions, reasoningEfforts
    # Internal cache keys (managed by Test-UpdateAvailable / Invoke-CcpUpgrade,
    # not surfaced in `ccp config`): updateCheckAt, updateAvailable
    #
    # reasoningEfforts: per-model map (bare id -> effort). Source of truth for
    # what ccp projects into the proxy's config.json modelReasoningEfforts.
    # Normalized to a hashtable on load (JSON round-trips it as PSCustomObject).
    $defaults = @{
        defaultModel      = $null
        bypassPermissions = $true
        reasoningEfforts  = @{}
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
    if ($loaded.PSObject.Properties.Name -contains 'reasoningEfforts' -and $loaded.reasoningEfforts) {
        $map = @{}
        foreach ($p in $loaded.reasoningEfforts.PSObject.Properties) { $map[$p.Name] = $p.Value }
        $defaults['reasoningEfforts'] = $map
    }
    return $defaults
}

function Save-CcpConfig($cfg) {
    $dir = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

# Project a per-model reasoning effort into the proxy's config.json and reload
# the proxy so it takes effect. The proxy caches config in memory and only
# re-reads on (re)start, so changing the value requires a service restart --
# which needs admin. To keep normal launches UAC-free, this is a no-op when the
# proxy already has the desired value (the common case once configured).
#
# Writing the file itself needs no elevation (it lives under $HOME); only the
# Restart-Service is elevated, and only when something actually changed.
function Sync-ProxyReasoningEffort($bareId, $effort) {
    if (-not $bareId -or -not $effort) { return }
    if (-not (Test-Path $proxyConfigPath)) {
        Write-Warning "[ccp] proxy config not found at $proxyConfigPath; cannot set effort. Is the proxy installed?"
        return
    }
    try {
        $raw = Get-Content $proxyConfigPath -Raw -ErrorAction Stop
        $proxyCfg = $raw | ConvertFrom-Json
    } catch {
        Write-Warning "[ccp] proxy config is unreadable/invalid JSON; skipping effort sync: $_"
        return
    }

    # Normalize modelReasoningEfforts (PSCustomObject from JSON) into a hashtable.
    $efforts = @{}
    if ($proxyCfg.PSObject.Properties.Name -contains 'modelReasoningEfforts' -and $proxyCfg.modelReasoningEfforts) {
        foreach ($p in $proxyCfg.modelReasoningEfforts.PSObject.Properties) { $efforts[$p.Name] = $p.Value }
    }

    if ($efforts[$bareId] -eq $effort) {
        return  # already in sync -- no write, no restart, no UAC
    }
    $efforts[$bareId] = $effort

    # Merge back and write. Re-serialize the whole config so we preserve every
    # other field (auth, providers, extraPrompts, etc.).
    if ($proxyCfg.PSObject.Properties.Name -contains 'modelReasoningEfforts') {
        $proxyCfg.modelReasoningEfforts = $efforts
    } else {
        $proxyCfg | Add-Member -NotePropertyName 'modelReasoningEfforts' -NotePropertyValue $efforts
    }
    try {
        $proxyCfg | ConvertTo-Json -Depth 20 | Set-Content -Path $proxyConfigPath -Encoding UTF8
    } catch {
        Write-Warning "[ccp] failed to write proxy config: $_"
        return
    }

    Write-Host ("[ccp] proxy reasoning effort {0} = {1}; restarting service (UAC)..." -f $bareId, $effort) -ForegroundColor Cyan
    try {
        Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile','-Command',"Restart-Service $proxyService"
        ) -ErrorAction Stop
    } catch {
        Write-Warning "[ccp] service restart was cancelled or failed; effort is written but not yet live: $_"
        return
    }
    # Wait briefly for the proxy to come back so the subsequent claude launch
    # doesn't race a not-yet-listening service.
    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Proxy) { break }
        Start-Sleep -Milliseconds 300
    }
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
            # Prefer claude_model_id: copilot-api (PR #231) moved the `[1m]`
            # 1M-context marker out of the top-level `id` and into this field.
            # Claude Code only switches into 1M mode when ANTHROPIC_MODEL carries
            # `[1m]`, so this is the id we must surface, store, and launch with.
            # Note ctx alone is not enough to decide (gpt-5.5 is 1.05M, not 1M);
            # trust the proxy's field. Falls back to the bare id when unset.
            id      = if ($_.claude_model_id) { $_.claude_model_id } else { $_.id }
            owner   = $_.owned_by
            ctx     = $_.capabilities.limits.max_context_window_tokens
            efforts = $_.capabilities.supports.reasoning_effort
        }
    } | Sort-Object id -Unique

    return ,($models | Sort-Object @{e={Get-ModelRank $_.id}}, id)
}

# The model id Claude Code actually sends to the proxy on /v1/messages is the
# ANTHROPIC_MODEL value with the trailing `[1m]` marker stripped (Claude strips
# `/\[1m\]/i` before sending). The proxy's modelReasoningEfforts map is keyed by
# that bare id, so effort config must use it too.
function Get-BareModelId($id) {
    return ($id -replace '\[1m\]$', '')
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
  ccp ccsm                             Register ccp as a launchable CLI in
                                       ccsm (~/.ccsm/config.json).
  ccp --help                           Show this help.

Config file: $configPath
Current settings:
  defaultModel      = $curDefault
  bypassPermissions = $($cur.bypassPermissions)
"@
}

# Interactive effort picker for one model, constrained to that model's
# upstream-supported list (capabilities.supports.reasoning_effort from
# /v1/models). Returns the chosen effort, or $null for "unset / proxy default".
# $supported is the model's effort array; $current is the stored value (or $null).
function Read-EffortChoice($model, $supported, $current) {
    if (-not $supported -or $supported.Count -eq 0) {
        Write-Host ("  ({0} advertises no reasoning_effort levels; skipping)" -f $model) -ForegroundColor DarkGray
        return $current
    }
    Write-Host ''
    Write-Host ("Reasoning effort for {0} (Enter to keep current):" -f $model) -ForegroundColor Cyan
    Write-Host '  [ 0] (unset -- proxy default, "high")'
    for ($i = 0; $i -lt $supported.Count; $i++) {
        $marker = if ($current -eq $supported[$i]) { ' *current*' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i + 1), $supported[$i], $marker)
    }
    $pick = Read-Host 'Number'
    if ([string]::IsNullOrWhiteSpace($pick)) { return $current }
    $idx = [int]$pick - 1
    if ($idx -eq -1) { return $null }
    if ($idx -ge 0 -and $idx -lt $supported.Count) { return $supported[$idx] }
    Write-Warning '[ccp] invalid effort choice; keeping current'
    return $current
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

    # If a concrete default model is set, let the user pick its reasoning effort,
    # constrained to that model's upstream-supported levels. Stored under the
    # bare id (proxy's modelReasoningEfforts key).
    if ($config.defaultModel) {
        if (-not ($config.reasoningEfforts -is [hashtable])) { $config.reasoningEfforts = @{} }
        $bareId   = Get-BareModelId $config.defaultModel
        $selected = $models | Where-Object { $_.id -eq $config.defaultModel } | Select-Object -First 1
        $eff = Read-EffortChoice $config.defaultModel $selected.efforts $config.reasoningEfforts[$bareId]
        if ($eff) {
            $config.reasoningEfforts[$bareId] = $eff
        } elseif ($config.reasoningEfforts.ContainsKey($bareId)) {
            $config.reasoningEfforts.Remove($bareId)
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
    if ($config.defaultModel) {
        $bareId = Get-BareModelId $config.defaultModel
        if ($config.reasoningEfforts[$bareId]) {
            Write-Host ('  reasoningEffort   = {0}' -f $config.reasoningEfforts[$bareId])
        }
    }

    # Project the chosen effort into the proxy and reload it so the change takes
    # effect (the proxy caches config in memory; only a reload/restart picks it up).
    if ($config.defaultModel) {
        $bareId = Get-BareModelId $config.defaultModel
        if ($config.reasoningEfforts[$bareId]) {
            Sync-ProxyReasoningEffort $bareId $config.reasoningEfforts[$bareId]
        }
    }
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

# ---------- ccsm integration ----------
# Register this wrapper (ccp.cmd) as a CLI in ccsm's config.json so ccsm's
# Launch page can spawn it directly. ccsm already knows how to run a .cmd via
# its shell:'direct' strategy (cmd.exe /d /s /c <path>), and uses the `type`
# field (claude/codex) to pick the matching resume templates. If ccsm is
# running, update through its own /api/config so the live backend owns the
# write. If it is offline, write ~/.ccsm/config.json directly. CCSM_HOME is
# honoured in both paths.
function Get-CcsmHome {
    if ($env:CCSM_HOME) { return $env:CCSM_HOME }
    return (Join-Path $HOME '.ccsm')
}

function Get-CcsmPreferredPort {
    $cfg = Join-Path (Get-CcsmHome) 'config.json'
    if (Test-Path $cfg) {
        try {
            $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.port) { return [int]$j.port }
        } catch {}
    }
    return 7777
}

function Test-CcsmHealth([int]$Port) {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        $j = $r.Content | ConvertFrom-Json
        return ($j.name -eq '@bakapiano/ccsm')
    } catch {
        return $false
    }
}

function Get-RunningCcsmPort {
    $preferred = Get-CcsmPreferredPort
    $ports = @($preferred)
    for ($i = 1; $i -le 9; $i++) { $ports += ($preferred + $i) }

    foreach ($port in $ports) {
        if (Test-CcsmHealth $port) { return $port }
    }
    return $null
}

function Set-CcsmCliEntry($cfg, $entry, [string]$id) {
    $existing = @()
    if (($cfg.PSObject.Properties.Name -contains 'clis') -and $cfg.clis) {
        $existing = @($cfg.clis | Where-Object { $_.id -ne $id })
    }
    $clis = @($existing + $entry)
    if ($cfg.PSObject.Properties.Name -contains 'clis') {
        $cfg.clis = $clis
    } else {
        $cfg | Add-Member -NotePropertyName 'clis' -NotePropertyValue $clis
    }
    return $cfg
}

function Save-CcsmCliEntry($ccsmHome, $ccsmCfg, $entry, [string]$id) {
    $runningPort = Get-RunningCcsmPort
    if ($runningPort) {
        $baseUrl = "http://localhost:$runningPort"
        Write-Host "[ccp] ccsm is running on port $runningPort; updating config through /api/config." -ForegroundColor Cyan
        try {
            $cfg = (Invoke-WebRequest -Uri "$baseUrl/api/config" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop).Content | ConvertFrom-Json
            $cfg = Set-CcsmCliEntry $cfg $entry $id
            $json = $cfg | ConvertTo-Json -Depth 50
            Invoke-WebRequest -Uri "$baseUrl/api/config" -Method PUT -Body $json -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
            return "api:$runningPort"
        } catch {
            Write-Error "[ccp] failed to update running ccsm via ${baseUrl}: $_"
            return $null
        }
    }

    if (Test-Path $ccsmCfg) {
        try {
            $cfg = Get-Content $ccsmCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Error "[ccp] $ccsmCfg is invalid JSON; refusing to overwrite. Fix or remove it, then re-run 'ccp ccsm'."
            return $null
        }
    } else {
        New-Item -ItemType Directory -Force -Path $ccsmHome | Out-Null
        $cfg = [pscustomobject]@{}
    }

    $cfg = Set-CcsmCliEntry $cfg $entry $id
    try {
        $json = $cfg | ConvertTo-Json -Depth 50
        [System.IO.File]::WriteAllText($ccsmCfg, $json, (New-Object System.Text.UTF8Encoding $false))
        return 'file'
    } catch {
        Write-Error "[ccp] failed to write ${ccsmCfg}: $_"
        return $null
    }
}

function Invoke-CcpCcsmSetup {
    $ccsmHome = if ($env:CCSM_HOME) { $env:CCSM_HOME } else { Join-Path $HOME '.ccsm' }
    $ccsmCfg  = Join-Path $ccsmHome 'config.json'

    # The .cmd shim sits next to this script (the gc2cc bin dir). Prefer the
    # script's own dir; fall back to the canonical install location.
    $cmdPath = Join-Path $PSScriptRoot 'ccp.cmd'
    if (-not (Test-Path $cmdPath)) {
        $cmdPath = Join-Path $env:LOCALAPPDATA 'gc2cc\bin\ccp.cmd'
    }
    if (-not (Test-Path $cmdPath)) {
        Write-Warning "[ccp] ccp.cmd not found (looked in $PSScriptRoot and %LOCALAPPDATA%\gc2cc\bin). Registering the path anyway: $cmdPath"
    }

    # shell='direct': ccsm's resolveCommand sees the .cmd extension and runs it
    # via cmd.exe /d /s /c, appending resume args after. type='claude' selects
    # Claude-style resume templates (--continue / --resume).
    $entry = [pscustomobject][ordered]@{
        id               = 'ccp'
        name             = 'ccp (gc2cc Claude)'
        command          = $cmdPath
        args             = @()
        resumeLatestArgs = @('--continue')
        resumePickerArgs = @('--resume')
        shell            = 'direct'
        type             = 'claude'
    }

    $saveMode = Save-CcsmCliEntry $ccsmHome $ccsmCfg $entry 'ccp'
    if (-not $saveMode) { return }

    Write-Host ''
    Write-Host "[ccp] Registered 'ccp' as a ccsm CLI." -ForegroundColor Green
    Write-Host ('  config : {0}' -f $ccsmCfg)
    Write-Host ('  command: {0}' -f $cmdPath)
    Write-Host  '  type   : claude (resume: --continue / --resume)'
    Write-Host ''
    if ($saveMode -like 'api:*') {
        Write-Host "[ccp] ccsm is still running; refresh the ccsm page if the Launch picker is already open." -ForegroundColor Yellow
    } else {
        Write-Host "[ccp] Start ccsm to see it on the Launch page." -ForegroundColor Yellow
    }
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
function Invoke-ClaudeWithModel($mainModel, $cfg, $passthrough, $stdinInput) {
    # Normalize the requested model against the live catalog by *bare* id, so a
    # stored default or `-Model` value like `claude-opus-4-8` adopts the proxy's
    # canonical surfaced id `claude-opus-4-8[1m]`. That `[1m]` marker is the only
    # thing that flips Claude Code into 1M-context mode; a config written before
    # the proxy moved the marker into `claude_model_id` would otherwise launch in
    # 200k. We also capture the matched entry's ctx here and reuse it for the
    # auto-compact window below (one /v1/models round-trip, not two).
    $ctx = $null
    try {
        $bare  = Get-BareModelId $mainModel
        $entry = (Get-AvailableModels) | Where-Object { (Get-BareModelId $_.id) -eq $bare } | Select-Object -First 1
        if ($entry) {
            $mainModel = $entry.id
            if ($entry.ctx) { $ctx = [int]$entry.ctx }
        }
    } catch {}

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
    # ctx (max_context_window_tokens) was already resolved above from the same
    # /v1/models lookup that normalized the model id, so new SKUs (1m variants,
    # gpt-5.5's 1.05M window, etc.) get the right threshold without ccp edits.
    # Falls back to 200k for unknowns.
    if (-not $ctx) { $ctx = 200000 }
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string][int]($ctx * 0.8)

    # Reasoning effort: stored per bare model id. The proxy reads it from its
    # own config.json (client-sent thinking is ignored), so make sure the proxy
    # is in sync before launching. No-op (and no UAC) when already correct.
    $bareId = Get-BareModelId $mainModel
    $effort = if ($cfg.reasoningEfforts -is [hashtable]) { $cfg.reasoningEfforts[$bareId] } else { $null }
    if ($effort) {
        Sync-ProxyReasoningEffort $bareId $effort
    }
    $effortNote = if ($effort) { $effort } else { '(proxy default)' }

    # --settings with INLINE JSON survives every forwarding hop (cmd -> batch %*
    # -> powershell -File) intact, but dies on the *last* hop: PowerShell 5.1's
    # native-command argument passing strips the embedded double quotes when it
    # builds claude's real command line, so claude sees `{theme:auto}` and aborts
    # with "Invalid JSON provided to --settings". This bites when ccsm launches
    # ccp and injects `--settings {"theme":"auto"}`. A file PATH has no quotes to
    # mangle, and claude's `--settings <file-or-json>` accepts a path -- so spill
    # any inline-JSON value to a temp file and pass that instead. (`--settings=`
    # joined form and already-a-path values are left untouched.)
    for ($pi = 0; $pi -lt $passthrough.Count; $pi++) {
        $tok = [string]$passthrough[$pi]
        $val = $null; $valIdx = -1
        if ($tok -eq '--settings' -and ($pi + 1) -lt $passthrough.Count) {
            $val = [string]$passthrough[$pi + 1]; $valIdx = $pi + 1
        } elseif ($tok -like '--settings=*') {
            $val = $tok.Substring('--settings='.Length); $valIdx = $pi
        }
        if ($null -ne $val -and $val.TrimStart().StartsWith('{')) {
            try {
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccp-settings-$PID.json")
                [System.IO.File]::WriteAllText($tmp, $val, (New-Object System.Text.UTF8Encoding $false))
                if ($valIdx -eq $pi) { $passthrough[$pi] = "--settings=$tmp" }
                else { $passthrough[$valIdx] = $tmp }
            } catch {}
        }
    }

    $bypassNote = if ($cfg.bypassPermissions) { 'on' } else { 'off' }
    Write-Host ('[ccp] main={0}  small={1}  effort={2}  bypass={3}  autoCompactAt={4}' -f $mainModel, $small, $effortNote, $bypassNote, $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) -ForegroundColor Cyan
    if ($cfg.bypassPermissions) {
        if ($null -ne $stdinInput) {
            $stdinInput | & claude @passthrough --dangerously-skip-permissions
        } else {
            & claude @passthrough --dangerously-skip-permissions
        }
    } else {
        if ($null -ne $stdinInput) {
            $stdinInput | & claude @passthrough
        } else {
            & claude @passthrough
        }
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
        'ccsm'    { Invoke-CcpCcsmSetup; return }
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

Invoke-ClaudeWithModel -mainModel $main -cfg $config -passthrough $passthrough -stdinInput $script:ccpPipelineInput
