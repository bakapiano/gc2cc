# ccp -- claude YOLO mode routed through caozhiyuan/copilot-api on http://localhost:4141.
# PATH-mounted standalone script (no profile required). Works the same in PS5.1,
# PS7, and any host: drop it under %LOCALAPPDATA%\gc2cc\bin\ (added to user PATH
# by gc2cc/install.ps1), and `ccp ...` resolves from any shell.
$base = 'http://localhost:4141'

try {
    $raw = (Invoke-WebRequest "$base/v1/models" -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop).Content
} catch {
    Write-Error "[ccp] copilot-api not reachable at $base. Check: Get-Service gc2cc-copilot-api"
    return
}

# /v1/models lists everything the upstream Copilot account can see, including
# embeddings and Microsoft-internal routers. Trim the menu to what's actually
# useful as a chat backend.
#
# Filter rules (in order):
#   - Drop owned_by Experimental / Fireworks (router shims, not chat-usable).
#   - Drop ids that look like embedding models or routers by name.
#   - Drop legacy / snapshotted variants (date suffixes, prior generations).
#   - Strip the [1m]/-1m/-1m-internal/-high/-xhigh suffixes the proxy advertises:
#     the [1m] suffix exists so Claude Code's UI marks the model as 1M-capable,
#     and -high/-xhigh reflect server-side reasoning effort -- neither should
#     be in our chosen ANTHROPIC_MODEL id. Per caozhiyuan's README:
#       "When using with Claude Code, please configure the model ID as
#       `claude-opus-4-6` or `claude-opus-4.6` (without the `[1m]` suffix,
#       exceeding GitHub Copilot's context window limit too much may lead to
#       being banned)."
#     The proxy still gates 1M behavior on the underlying model's capabilities,
#     so dropping the suffix doesn't lose anything functional.
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
$dropOwners = @('Experimental','Fireworks')

$stripSuffix = '(?:\[1m\]|-1m(?:-internal)?|-(high|xhigh))$'
$is1m        = '(?:\[1m\]|-1m(?:-internal)?)'

# First pass: filter, then canonicalize ids to their base (stripping
# [1m]/-1m/-1m-internal/-high/-xhigh) so the same upstream model isn't
# listed multiple times under server-side reasoning-effort or 1M variants.
$entries = ($raw | ConvertFrom-Json).data | ForEach-Object {
    if ($dropOwners -contains $_.owned_by) { return }
    foreach ($p in $drop) { if ($_.id -match $p) { return } }
    # caozhiyuan/copilot-api's /v1/models adds a `[1m]` marker on top of any
    # model whose upstream id already ends in `-1m`/`-1m-internal`, so we need
    # multiple passes to canonicalize ids like `claude-opus-4.6-1m[1m]`.
    $clean = $_.id
    while ($clean -match $stripSuffix) { $clean = $clean -replace $stripSuffix, '' }
    [pscustomobject]@{
        id    = $clean
        owner = $_.owned_by
        is1m  = ($_.id -match $is1m)
    }
} | Sort-Object id, is1m -Unique

# Second pass: for any base id that has a 1M-capable upstream variant,
# add a separate `base[1m]` menu entry. We deliberately do NOT drop the
# base entry -- per caozhiyuan's warning, the bare id is the safer default;
# the [1m] variant is exposed for users who explicitly want 1M context.
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

if (-not $models -or $models.Count -eq 0) {
    Write-Warning '[ccp] no models matched after filtering. Falling back to free-form prompt.'
    $main = Read-Host 'Enter model id'
    if ([string]::IsNullOrWhiteSpace($main)) { return }
} else {
    # Sort: preferred families first, then by id.
    function Rank($id) {
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
    $models = $models | Sort-Object @{e={Rank $_.id}}, id

    Write-Host ''
    Write-Host 'Pick a model:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ('  [{0,2}] {1}' -f ($i + 1), $models[$i].id)
    }
    $pick = Read-Host 'Number (default 1)'
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $models.Count) { Write-Error '[ccp] invalid choice'; return }
    $main = $models[$idx].id
}

# Heuristic small/fast model by family. Prefer in-family small models so the
# main and small share token-count semantics. Fall back to gpt-5-mini.
function Pick-Small($id) {
    switch -regex ($id) {
        '^claude-' { return 'claude-haiku-4.5' }
        '^gpt-5'   { return 'gpt-5-mini' }
        '^gpt-4'   { return 'gpt-4o-mini' }
        '^gemini-' { return 'gemini-3-flash-preview' }
        default    { return 'gpt-5-mini' }
    }
}
$small = Pick-Small $main

# Per caozhiyuan README, set both the main slots and the haiku slot. We
# intentionally pass model ids WITHOUT the [1m] suffix per the author's
# ban-risk warning quoted above.
$env:ANTHROPIC_BASE_URL                       = $base
$env:ANTHROPIC_AUTH_TOKEN                     = 'dummy'
$env:ANTHROPIC_MODEL                          = $main
$env:ANTHROPIC_DEFAULT_SONNET_MODEL           = $main
$env:ANTHROPIC_SMALL_FAST_MODEL               = $small
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL            = $small
$env:DISABLE_NON_ESSENTIAL_MODEL_CALLS        = '1'
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'

Write-Host ('[ccp] main={0}  small={1}' -f $main, $small) -ForegroundColor Cyan
& claude @args --dangerously-skip-permissions
