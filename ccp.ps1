# ccp -- claude YOLO mode routed through copilot-api on http://localhost:4141.
# PATH-mounted standalone script (no profile required). Works the same in PS5.1,
# PS7, and any host: drop it under %LOCALAPPDATA%\gc2cc\bin\ (added to user PATH
# by gc2cc/install.ps1), and `ccp ...` resolves from any shell.
$base      = 'http://localhost:4141'
$taskName  = 'gc2cc-copilot-api'
$taskPath  = '\gc2cc\'

function Test-Proxy {
    try { Invoke-WebRequest "$base/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop | Out-Null; $true } catch { $false }
}

if (-not (Test-Proxy)) {
    $t = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Error "[ccp] task '$taskPath$taskName' not registered. Install: irm https://bakapiano.github.io/gc2cc/install.ps1 | iex"
        return
    }
    Write-Host "[ccp] proxy not reachable on $base; starting task..." -ForegroundColor Yellow
    try { Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop } catch {
        Write-Error "[ccp] Start-ScheduledTask failed: $_"
        return
    }
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Proxy) { $ready = $true; break }
    }
    if (-not $ready) {
        Write-Error "[ccp] task started but proxy still not up after 30s. Logs: $env:LOCALAPPDATA\gc2cc\logs\copilot-api.log"
        return
    }
    Write-Host "[ccp] proxy ready." -ForegroundColor Green
}

# [1m] suffix is consumed by Claude Code locally (case-insensitive match to enable 1M-context
# UI/budget) and stripped by bakapiano/copilot-api before forwarding to GitHub Copilot.
$models = @(
    @{ id = 'claude-opus-4.7[1m]';      small = 'claude-haiku-4.5'       },
    @{ id = 'claude-opus-4.7';          small = 'claude-haiku-4.5'       },
    @{ id = 'gemini-3.1-pro-preview';   small = 'gemini-3-flash-preview' },
    @{ id = 'claude-sonnet-4.5';        small = 'claude-haiku-4.5'       },
    @{ id = 'claude-opus-4.5';          small = 'claude-haiku-4.5'       },
    @{ id = 'claude-haiku-4.5';         small = 'claude-haiku-4.5'       },
    @{ id = 'gpt-5.2';                  small = 'gpt-5-mini'             },
    @{ id = 'gpt-5-mini';               small = 'gpt-5-mini'             },
    @{ id = 'gemini-2.5-pro';           small = 'gemini-3-flash-preview' },
    @{ id = 'gemini-3-flash-preview';   small = 'gemini-3-flash-preview' },
    @{ id = 'gpt-4.1';                  small = 'gpt-4o-mini'            }
)

Write-Host ''
Write-Host 'Pick a model:' -ForegroundColor Cyan
for ($i = 0; $i -lt $models.Count; $i++) {
    Write-Host ('  [{0,2}] {1}' -f ($i + 1), $models[$i].id)
}
$pick = Read-Host 'Number (default 1)'
if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
$idx = [int]$pick - 1
if ($idx -lt 0 -or $idx -ge $models.Count) { Write-Error '[ccp] invalid choice'; return }
$main  = $models[$idx].id
$small = $models[$idx].small

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
