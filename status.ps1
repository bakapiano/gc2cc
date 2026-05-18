#Requires -Version 5.1
<#
.SYNOPSIS
    Quick status / log helper for gc2cc.

.EXAMPLE
    irm https://bakapiano.github.io/gc2cc/status.ps1 | iex    # show
    .\status.ps1 -Action restart                              # restart task
    .\status.ps1 -Action tail                                 # follow logs
#>
[CmdletBinding()]
param(
    [ValidateSet('show','restart','logs','tail')]
    [string] $Action      = 'show',
    [string] $TaskName    = 'gc2cc-copilot-api',
    [string] $InstallDir  = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [int]    $Port        = 4141,
    [int]    $Lines       = 50
)

$LogDir = Join-Path $InstallDir 'logs'
$Log    = Join-Path $LogDir 'copilot-api.log'
$Prev   = Join-Path $LogDir 'copilot-api.prev.log'

switch ($Action) {
    'show' {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $t) { Write-Host "[gc2cc] task '$TaskName' not installed" -ForegroundColor Red; return }
        $info = $t | Get-ScheduledTaskInfo
        $t    | Select-Object TaskName, State | Format-List
        $info | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns | Format-List

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
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}
        Start-Sleep -Seconds 1
        Start-ScheduledTask -TaskName $TaskName
        Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State
    }
    'logs' {
        if (Test-Path $Log)  { Write-Host "=== $Log ===" -ForegroundColor Cyan; Get-Content $Log -Tail $Lines }
        if (Test-Path $Prev) { Write-Host "=== $Prev ===" -ForegroundColor Cyan; Get-Content $Prev -Tail $Lines }
    }
    'tail' {
        if (-not (Test-Path $Log)) { Write-Host '[gc2cc] no log yet' -ForegroundColor Yellow; return }
        Get-Content $Log -Wait -Tail $Lines
    }
}
