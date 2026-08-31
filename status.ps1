#Requires -Version 5.1
<#
.SYNOPSIS
    Quick status / log helper for gc2cc.

.EXAMPLE
    irm https://escapecat.github.io/gc2cc/status.ps1 | iex    # show
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
    [int]    $Lines       = 50,
    # Internal marker used by the UAC child process.
    [switch] $Elevated
)

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $InstallDir 'logs'
$Log    = Join-Path $LogDir 'copilot-api.log'

function Get-WindowsPowerShellExe {
    $candidates = @()
    if ($env:SystemRoot) { $candidates += (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
    if ($env:WINDIR)     { $candidates += (Join-Path $env:WINDIR     'System32\WindowsPowerShell\v1.0\powershell.exe') }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return 'powershell.exe'
}

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

# Only service control needs elevation. Relaunch this action through UAC and
# wait for its real exit code; show/log/tail remain ordinary user operations.
if ($Action -eq 'restart') {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Error "[gc2cc] service '$ServiceName' not installed"
        return
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if ($Elevated) {
            Write-Error '[gc2cc] UAC child did not receive an elevated administrator token.'
            return
        }
        $scriptPath = $PSCommandPath
        if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
        if (-not $scriptPath -or -not (Test-Path -LiteralPath $scriptPath)) {
            Write-Error '[gc2cc] restart needs UAC. Download status.ps1 first, then run it with -Action restart.'
            return
        }

        Write-Host "[gc2cc] restarting '$ServiceName' requires elevation; requesting UAC..." -ForegroundColor Yellow
        try {
            $restartProcess = Start-Process (Get-WindowsPowerShellExe) -Verb RunAs -Wait -PassThru -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$scriptPath`"",
                '-Action', 'restart',
                '-ServiceName', "`"$ServiceName`"",
                '-Elevated'
            ) -ErrorAction Stop
            if ($restartProcess.ExitCode -ne 0) {
                Write-Error "[gc2cc] elevated restart failed (exit $($restartProcess.ExitCode))."
                return
            }
            $svc.Refresh()
            Write-Host "[gc2cc] service '$ServiceName' restarted; status: $($svc.Status)" -ForegroundColor Green
        } catch {
            Write-Error "[gc2cc] service restart was cancelled or failed: $_"
        }
        return
    }
}

switch ($Action) {
    'show'    { Show-Status }
    'restart' {
        Restart-Service -Name $ServiceName -ErrorAction Stop
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
