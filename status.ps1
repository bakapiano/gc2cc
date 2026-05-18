#Requires -Version 5.1
<#
.SYNOPSIS
    Quick status / log helper for gc2cc.

.EXAMPLE
    irm https://bakapiano.github.io/gc2cc/status.ps1 | iex            # show
    .\status.ps1 -Action restart                                       # restart service
    .\status.ps1 -Action tail                                          # follow logs
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
$Out    = Join-Path $LogDir 'copilot-api.out.log'
$Err    = Join-Path $LogDir 'copilot-api.err.log'

switch ($Action) {
    'show' {
        $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Host "[gc2cc] service '$ServiceName' not installed" -ForegroundColor Red; return }
        $svc | Format-List Name, Status, StartType

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
    'restart' {
        Restart-Service $ServiceName
        Get-Service $ServiceName
    }
    'logs' {
        if (Test-Path $Out) { Write-Host "=== $Out ===" -ForegroundColor Cyan; Get-Content $Out -Tail $Lines }
        if (Test-Path $Err) { Write-Host "=== $Err ===" -ForegroundColor Cyan; Get-Content $Err -Tail $Lines }
    }
    'tail' {
        if (-not (Test-Path $Err) -and -not (Test-Path $Out)) { Write-Host '[gc2cc] no logs yet' -ForegroundColor Yellow; return }
        Get-Content @($Err, $Out | Where-Object { Test-Path $_ }) -Wait -Tail $Lines
    }
}
