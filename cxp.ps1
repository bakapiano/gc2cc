# cxp -- OpenAI Codex CLI routed through caozhiyuan/copilot-api on http://localhost:4141.
# Mirror of ccp.ps1 but for `codex` instead of `claude`. Zero-pollution: uses an
# isolated CODEX_HOME under %LOCALAPPDATA%\gc2cc\codex-home\ so the user's own
# ~/.codex/config.toml (if any) is never touched.
#
# The provider definition lives in $env:CODEX_HOME\config.toml (written by
# install.ps1), pointing at the local copilot-api proxy with wire_api="responses".
#
# Usage:
#   cxp [-Model <id>] [codex args...]
#   cxp config                           Interactive: pick default model.
#   cxp upgrade                          Re-run the gc2cc one-liner installer.
#   cxp --help                           Show usage.

$base       = 'http://localhost:4141'
$pagesBase  = 'https://bakapiano.github.io/gc2cc'
$configPath = Join-Path $HOME '.local\share\gc2cc\cxp.json'
$codexHome  = Join-Path $env:LOCALAPPDATA 'gc2cc\codex-home'

# ---------- config ----------
function Load-CxpConfig {
    # reasoningEfforts: per-model map (id -> effort). Levels are constrained to
    # each model's upstream /v1/models capabilities at config time. Stored as a
    # PSCustomObject when round-tripped through JSON, normalized to a hashtable
    # on load so callers can index/assign uniformly.
    $defaults = @{
        defaultModel     = $null
        reasoningEfforts = @{}
        updateCheckAt    = $null
        updateAvailable  = $false
    }
    if (-not (Test-Path $configPath)) { return $defaults }
    try {
        $loaded = Get-Content $configPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warning "[cxp] $configPath is invalid JSON; using defaults"
        return $defaults
    }
    foreach ($k in 'defaultModel','updateCheckAt','updateAvailable') {
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

function Save-CxpConfig($cfg) {
    $dir = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

# ---------- update check (24h-cached) ----------
function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToUpper() }
    finally { $sha.Dispose() }
}

function Get-OnlineCxpHash {
    try {
        $resp = Invoke-WebRequest "$pagesBase/cxp.ps1" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        $bytes = $resp.Content
        if ($bytes -isnot [byte[]]) { $bytes = [Text.Encoding]::UTF8.GetBytes($bytes) }
        return Get-Sha256Hex $bytes
    } catch { return $null }
}

function Get-LocalCxpHash {
    if (-not $PSCommandPath -or -not (Test-Path $PSCommandPath)) { return $null }
    return Get-Sha256Hex ([System.IO.File]::ReadAllBytes($PSCommandPath))
}

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
    $online = Get-OnlineCxpHash
    if (-not $online) { return [bool]$cfg.updateAvailable }
    $local = Get-LocalCxpHash
    $available = ($local -and ($online -ne $local))
    $cfg.updateCheckAt   = $now.ToString('o')
    $cfg.updateAvailable = $available
    try { Save-CxpConfig $cfg } catch {}
    return $available
}

# ---------- proxy + model discovery ----------
function Test-Proxy {
    try {
        Invoke-WebRequest "$base/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

# Sort key: family bucket first (smaller = higher priority), then version
# descending within bucket (so gpt-5.5 outranks 5.4 automatically when GitHub
# rolls out new SKUs -- no cxp edit needed). cxp's tier order favors OpenAI
# families first since codex is an OpenAI CLI; Anthropic/Gemini come after.
function Get-ModelRank($id) {
    $tier = switch -regex ($id) {
        '^gpt-5(?:\.\d+)?-codex' { 150; break }
        '^gpt-5(?:\.\d+)?-mini'  { 700; break }
        '^gpt-5-mini'       { 700; break }
        '^gpt-5\.'          { 100; break }
        '^claude-opus-'     { 200; break }
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
    return $tier * 10000 + (1000 - $major * 100 - $minor)
}

# Same filter rules as ccp -- the upstream /v1/models is shared. Additional cxp-
# only filter: drop models that don't expose an OpenAI `/v1/responses` endpoint
# (Anthropic-native models do not), since `wire_api = "chat"` is no longer
# supported by codex.
function Get-AvailableModels {
    $raw = (Invoke-WebRequest "$base/v1/models" -TimeoutSec 4 -UseBasicParsing).Content
    $drop = @(
        '^accounts/msft/',
        '^text-embedding-',
        '-embedding\b', '-inference$',
        '^gpt-3\.5', '^gpt-4-0', '^gpt-4-o-',
        '^gpt-4o-2024-', '^gpt-4o-mini-2024-', '^gpt-4\.1-2025-',
        '^gpt-4$',
        '^gpt-41-copilot$',
        '^claude-',                        # cxp-only: no /v1/responses for Claude
        '^lark-',                          # router shim, not chat
        '^gemini-2\.5-'
    )
    $dropOwners  = @('Experimental','Fireworks')
    $stripSuffix = '(?:\[1m\]|-1m(?:-internal)?|-(high|xhigh))$'

    $entries = ($raw | ConvertFrom-Json).data | ForEach-Object {
        if ($dropOwners -contains $_.owned_by) { return }
        foreach ($p in $drop) { if ($_.id -match $p) { return } }
        $clean = $_.id
        while ($clean -match $stripSuffix) { $clean = $clean -replace $stripSuffix, '' }
        [pscustomobject]@{
            id      = $clean
            owner   = $_.owned_by
            efforts = $_.capabilities.supports.reasoning_effort
            ctx     = $_.capabilities.limits.max_context_window_tokens
            maxOut  = $_.capabilities.limits.max_output_tokens
        }
    }
    # Dedup by id explicitly. We can't use `Sort-Object id -Unique` here: with an
    # array-valued property (efforts) it merges the property across the
    # duplicate rows that suffix-stripping creates (e.g. gpt-5.5 + gpt-5.5[1m]
    # collapse to one id), flattening every model's efforts into a single bogus
    # 35-element array. A keyed hashtable keeps the first row's efforts intact.
    $seen = @{}
    $unique = foreach ($e in $entries) {
        if (-not $seen.ContainsKey($e.id)) { $seen[$e.id] = $true; $e }
    }
    return ,($unique | Sort-Object @{e={Get-ModelRank $_.id}}, id)
}

# ---------- subcommands ----------
function Show-Help {
    $cur = Load-CxpConfig
    $curDefault = if ($cur.defaultModel) { $cur.defaultModel } else { '(none -- always prompt)' }
    Write-Host @"
cxp -- OpenAI Codex CLI routed through caozhiyuan/copilot-api on $base

Usage:
  cxp [-Model <id>] [codex args...]    Launch codex. -Model skips the picker.
  cxp config                           Interactive: pick default model.
  cxp upgrade                          Re-run the gc2cc one-liner installer.
  cxp --help                           Show this help.

Isolated CODEX_HOME: $codexHome
  (Your own ~/.codex/config.toml is never touched.)
Config file: $configPath
Current settings:
  defaultModel = $curDefault
"@
}

# Interactive effort picker for one model, constrained to that model's
# upstream-supported levels (capabilities.supports.reasoning_effort from
# /v1/models). The proxy forwards Codex's reasoning.effort untouched, and Codex
# itself passes the -c value through without validating, so the real ceiling is
# the upstream model's own list (e.g. gpt-5.5 supports up to xhigh; gpt-5-mini
# only to high). Returns the chosen effort, or $null for "unset / Codex default".
function Read-EffortChoice($model, $supported, $current) {
    if (-not $supported -or $supported.Count -eq 0) {
        Write-Host ("  ({0} advertises no reasoning_effort levels; skipping)" -f $model) -ForegroundColor DarkGray
        return $current
    }
    Write-Host ''
    Write-Host ("Reasoning effort for {0} (Enter to keep current):" -f $model) -ForegroundColor Cyan
    Write-Host '  [ 0] (unset -- use Codex default)'
    for ($i = 0; $i -lt $supported.Count; $i++) {
        $marker = if ($current -eq $supported[$i]) { ' *current*' } else { '' }
        Write-Host ('  [{0,2}] {1}{2}' -f ($i + 1), $supported[$i], $marker)
    }
    $pick = Read-Host 'Number'
    if ([string]::IsNullOrWhiteSpace($pick)) { return $current }
    $idx = [int]$pick - 1
    if ($idx -eq -1) { return $null }
    if ($idx -ge 0 -and $idx -lt $supported.Count) { return $supported[$idx] }
    Write-Warning '[cxp] invalid effort choice; keeping current'
    return $current
}

function Invoke-CxpConfig {
    if (-not (Test-Proxy)) {
        Write-Error "[cxp] copilot-api not reachable at $base. Check: Get-Service gc2cc-copilot-api"
        return
    }
    $config = Load-CxpConfig
    $curDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Current config ($configPath):" -ForegroundColor Cyan
    Write-Host ('  defaultModel = {0}' -f $curDefault)
    Write-Host ''

    $models = Get-AvailableModels
    Write-Host 'Pick a default model (Enter to keep current):' -ForegroundColor Cyan
    Write-Host '  [ 0] (none -- always prompt at cxp launch)'
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
            Write-Warning '[cxp] invalid choice; keeping current'
        }
    }

    # If a concrete default model is set, let the user pick its reasoning effort,
    # constrained to that model's upstream-supported levels.
    if ($config.defaultModel) {
        if (-not ($config.reasoningEfforts -is [hashtable])) { $config.reasoningEfforts = @{} }
        $cur = $config.reasoningEfforts[$config.defaultModel]
        $selected = $models | Where-Object { $_.id -eq $config.defaultModel } | Select-Object -First 1
        $eff = Read-EffortChoice $config.defaultModel $selected.efforts $cur
        if ($eff) {
            $config.reasoningEfforts[$config.defaultModel] = $eff
        } elseif ($config.reasoningEfforts.ContainsKey($config.defaultModel)) {
            $config.reasoningEfforts.Remove($config.defaultModel)
        }
    }

    Save-CxpConfig $config
    $newDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Saved to $configPath" -ForegroundColor Green
    Write-Host ('  defaultModel = {0}' -f $newDefault)
    if ($config.defaultModel -and $config.reasoningEfforts[$config.defaultModel]) {
        Write-Host ('  reasoningEffort = {0}' -f $config.reasoningEfforts[$config.defaultModel])
    }
}

function Invoke-CxpUpgrade {
    Write-Host "[cxp] Fetching latest installer from $pagesBase/install.ps1 ..." -ForegroundColor Cyan
    $b = (Invoke-WebRequest "$pagesBase/install.ps1" -UseBasicParsing).Content
    if ($b -is [byte[]]) { $b = [Text.Encoding]::UTF8.GetString($b) }
    Invoke-Expression $b
    try {
        $cfg = Load-CxpConfig
        $cfg.updateCheckAt   = (Get-Date).ToUniversalTime().ToString('o')
        $cfg.updateAvailable = $false
        Save-CxpConfig $cfg
    } catch {}
}

# ---------- model picker ----------
function Invoke-ModelPicker {
    $models = Get-AvailableModels
    if (-not $models -or $models.Count -eq 0) {
        Write-Warning '[cxp] no models matched after filtering. Falling back to free-form prompt.'
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
        Write-Error '[cxp] invalid choice'
        return $null
    }
    return $models[$idx].id
}

# ---------- codex exec ----------
function Invoke-CodexWithModel($mainModel, $cfg, $passthrough) {
    if (-not (Test-Path (Join-Path $codexHome 'config.toml'))) {
        Write-Error "[cxp] $codexHome\config.toml not found. Re-run the gc2cc installer."
        return
    }
    # Isolation: CODEX_HOME redirects codex to gc2cc-managed config dir, leaving
    # the user's ~/.codex untouched. OPENAI_API_KEY=dummy satisfies the provider's
    # env_key requirement (the proxy doesn't care what we send).
    $env:CODEX_HOME     = $codexHome
    $env:OPENAI_API_KEY = 'dummy'

    # `-c model=<id>` overrides the toml's `model` for this invocation only.
    # The proxy forwards Codex's reasoning.effort untouched on the /v1/responses
    # path, so an optional `-c model_reasoning_effort=<v>` is the real lever.
    $codexArgs = @("-c", "model=`"$mainModel`"")
    $eff = if ($cfg.reasoningEfforts -is [hashtable]) { $cfg.reasoningEfforts[$mainModel] } else { $null }
    if ($eff) {
        $codexArgs += @("-c", "model_reasoning_effort=`"$eff`"")
    }
    # Codex doesn't know our proxy's models, so its TUI falls back to a built-in
    # context-window guess (~258K) for ids it doesn't recognize. Inject the real
    # limits from /v1/models so `/status` and context tracking are accurate. The
    # bare id carries the 1M ctx here because Get-AvailableModels strips the
    # display-only `[1m]` suffix the proxy adds for 1M models.
    # NB: assign to $models first. Get-AvailableModels returns a comma-wrapped
    # array (`,(...)`); piping it straight into Where-Object passes the whole
    # array as a single $_, so $meta.ctx member-enumerates into an Object[] and
    # breaks the integer division below. Assignment unwraps it to a real list.
    $models = Get-AvailableModels
    $meta = $models | Where-Object { $_.id -eq $mainModel } | Select-Object -First 1
    if ($meta.ctx)    { $codexArgs += @("-c", "model_context_window=$($meta.ctx)") }
    if ($meta.maxOut) { $codexArgs += @("-c", "model_max_output_tokens=$($meta.maxOut)") }
    $effNote = if ($eff) { $eff } else { '(codex default)' }
    $ctxNote = if ($meta.ctx) { '{0}K' -f [int]($meta.ctx / 1000) } else { '?' }
    Write-Host ('[cxp] model={0}  effort={1}  ctx={2}  CODEX_HOME={3}' -f $mainModel, $effNote, $ctxNote, $codexHome) -ForegroundColor Cyan
    & codex @codexArgs @passthrough
}

# ---------- dispatch ----------
if ($args.Count -gt 0) {
    switch ($args[0]) {
        '--help'  { Show-Help;        return }
        '-h'      { Show-Help;        return }
        '-Help'   { Show-Help;        return }
        'help'    { Show-Help;        return }
        'config'  { Invoke-CxpConfig; return }
        'upgrade' { Invoke-CxpUpgrade; return }
    }
}

$passthrough = @()
$modelOverride = $null
$skipNext = $false
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($skipNext) { $skipNext = $false; continue }
    $a = $args[$i]
    if ($a -in @('-Model','-model','-Mode','-mode')) {
        if ($i + 1 -ge $args.Count) {
            Write-Error '[cxp] -Model requires a value'
            return
        }
        $modelOverride = $args[$i + 1]
        $skipNext = $true
    } elseif ($a -eq '--') {
        $passthrough += $args[($i + 1)..($args.Count - 1)]
        break
    } else {
        $passthrough += $a
    }
}

if (-not (Test-Proxy)) {
    Write-Error "[cxp] copilot-api not reachable at $base. Check: Get-Service gc2cc-copilot-api"
    return
}

if (-not (Test-Path $configPath)) {
    Write-Host ''
    Write-Host "[cxp] No config found at $configPath -- first-run setup." -ForegroundColor Cyan
    Write-Host "[cxp] You can re-run this any time with 'cxp config'." -ForegroundColor Cyan
    Invoke-CxpConfig
    Write-Host ''
}

$config = Load-CxpConfig

if (Test-UpdateAvailable $config) {
    Write-Host "[cxp] gc2cc has updates available -- run 'cxp upgrade' to refresh" -ForegroundColor Yellow
}

$main = $modelOverride
if (-not $main) { $main = $config.defaultModel }
if (-not $main) {
    $main = Invoke-ModelPicker
    if (-not $main) { return }
}

Invoke-CodexWithModel -mainModel $main -cfg $config -passthrough $passthrough
