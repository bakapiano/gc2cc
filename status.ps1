#Requires -Version 5.1
<#
.SYNOPSIS
    Quick status / log helper for gc2cc.

.EXAMPLE
    irm https://bakapiano.github.io/gc2cc/status.ps1 | iex    # show
    .\status.ps1 -Action restart                              # restart service (UAC)
    .\status.ps1 -Action tail                                 # follow logs
#>
[CmdletBinding()]
param(
    [ValidateSet('show','restart','logs','tail')]
    [string] $Action      = 'show',
    [string] $ServiceName = 'gc2cc-copilot-api',
    [string] $InstallDir  = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [int]    $Port        = 4141,
    [int]    $Lines       = 50
)

$LogDir = Join-Path $InstallDir 'logs'
$Log    = Join-Path $LogDir 'copilot-api.log'

function Show-Status {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Host "[gc2cc] service '$ServiceName' not installed" -ForegroundColor Red; return }
    $svc | Select-Object Name, Status, StartType | Format-List

    try {
        $r = Invoke-WebRequest "http://localhost:$Port/v1/models" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        Write-Host "[gc2cc] proxy responding on port $Port" -ForegroundColor Green
        $models = ($r.Content | ConvertFrom-Json).data
        if ($models) {
            Write-Host 'available models:'
            $models | ForEach-Object { "  - $($_.id)" }
        }
    } catch {
        Write-Host "[gc2cc] proxy NOT reachable on port $Port : $_" -ForegroundColor Red
    }
}

switch ($Action) {
    'show'    { Show-Status }
    'restart' {
        # Restart-Service needs admin. Let it throw if the user isn't elevated --
        # the SCM error is more informative than anything we'd wrap it with.
        Restart-Service -Name $ServiceName
        Get-Service -Name $ServiceName | Select-Object Name, Status
    }
    'logs' {
        if (Test-Path $Log) {
            Write-Host "=== $Log ===" -ForegroundColor Cyan
            Get-Content $Log -Tail $Lines
        }
        # NSSM online rotation names rotated files like copilot-api.log-<timestamp>.
        $rotated = Get-ChildItem $LogDir -Filter 'copilot-api.log-*' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($rotated) {
            Write-Host "=== $($rotated.FullName) ===" -ForegroundColor Cyan
            Get-Content $rotated.FullName -Tail $Lines
        }
    }
    'tail' {
        if (-not (Test-Path $Log)) { Write-Host '[gc2cc] no log yet' -ForegroundColor Yellow; return }
        Get-Content $Log -Wait -Tail $Lines
    }
}
