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
    $defaults = @{
        defaultModel    = $null
        updateCheckAt   = $null
        updateAvailable = $false
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
        [pscustomobject]@{ id = $clean; owner = $_.owned_by }
    } | Sort-Object id -Unique
    return ,($entries | Sort-Object @{e={Get-ModelRank $_.id}}, id)
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

    Save-CxpConfig $config
    $newDefault = if ($config.defaultModel) { $config.defaultModel } else { '(none -- always prompt)' }
    Write-Host ''
    Write-Host "Saved to $configPath" -ForegroundColor Green
    Write-Host ('  defaultModel = {0}' -f $newDefault)
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
function Invoke-CodexWithModel($mainModel, $passthrough) {
    if (-not (Test-Path (Join-Path $codexHome 'config.toml'))) {
        Write-Error "[cxp] $codexHome\config.toml not found. Re-run the gc2cc installer."
        return
    }
    # Isolation: CODEX_HOME redirects codex to gc2cc-managed config dir, leaving
    # the user's ~/.codex untouched. OPENAI_API_KEY=dummy satisfies the provider's
    # env_key requirement (the proxy doesn't care what we send).
    $env:CODEX_HOME     = $codexHome
    $env:OPENAI_API_KEY = 'dummy'

    Write-Host ('[cxp] model={0}  CODEX_HOME={1}' -f $mainModel, $codexHome) -ForegroundColor Cyan
    # `-c model=<id>` overrides the toml's `model` for this invocation only.
    & codex -c "model=`"$mainModel`"" @passthrough
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

Invoke-CodexWithModel -mainModel $main -passthrough $passthrough
