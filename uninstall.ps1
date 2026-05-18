#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall gc2cc: stop and unregister the Scheduled Task, delete %LOCALAPPDATA%\gc2cc,
    remove the bin\ dir from user PATH, optionally uninstall @anthropic-ai/claude-code,
    strip any legacy ccp block from $PROFILE (older installs put ccp there).

.NOTES
    Does NOT require Administrator. Does not delete the GitHub Copilot auth token at
    ~/.local/share/copilot-api/github_token -- remove it manually for a full reset.
#>
[CmdletBinding()]
param(
    [string] $TaskName       = 'gc2cc-copilot-api',
    [string] $TaskPath       = '\gc2cc\',
    [string] $InstallDir     = (Join-Path $env:LOCALAPPDATA 'gc2cc'),
    [switch] $KeepInstallDir,
    [switch] $KeepClaudeCode,
    [switch] $KeepProfile
)

$ErrorActionPreference = 'Stop'

function Info ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[gc2cc] $m" -ForegroundColor Yellow }

$removedAny = $false
# Current install: \gc2cc\<TaskName>
if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
    Info "Unregistering Scheduled Task '$TaskPath$TaskName'..."
    try { Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop } catch {}
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    Ok 'task unregistered'
    $removedAny = $true
}
# Legacy root-path orphan from older installs (needs admin to delete)
if (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue) {
    Info "Found legacy root-path task '\$TaskName' from older install. Trying to remove..."
    try {
        Stop-ScheduledTask  -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        Ok 'legacy task removed'
        $removedAny = $true
    } catch {
        Warn "Could not remove legacy task '\$TaskName' (admin required)."
        Warn "  Run once as admin:  schtasks /Delete /TN $TaskName /F"
    }
}
if (-not $removedAny) { Warn "no task '$TaskName' found at $TaskPath or \, skipping" }

$BinDir = Join-Path $InstallDir 'bin'

# Remove $BinDir from user PATH (HKCU\Environment -- no admin)
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath) {
    $parts = $userPath -split ';' | Where-Object { $_ -and ($_ -ne $BinDir) }
    $newPath = $parts -join ';'
    if ($newPath -ne $userPath) {
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Ok "removed from user PATH: $BinDir"
    }
}

if (-not $KeepInstallDir -and (Test-Path $InstallDir)) {
    Info "Removing $InstallDir ..."
    Remove-Item -Recurse -Force $InstallDir
    Ok 'install dir removed'
}

if (-not $KeepClaudeCode) {
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        Info 'Uninstalling @anthropic-ai/claude-code ...'
        npm uninstall -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        Ok 'claude-code uninstalled'
    } else {
        Warn 'claude CLI not found, skipping'
    }
}

if (-not $KeepProfile) {
    $profilePath = $PROFILE
    if (Test-Path $profilePath) {
        $c = Get-Content $profilePath -Raw
        $begin = '# >>> gc2cc ccp BEGIN -- managed by gc2cc installer'
        $end   = '# <<< gc2cc ccp END'
        $pattern = [Regex]::Escape($begin) + '[\s\S]*?' + [Regex]::Escape($end) + '\r?\n?'
        $new = [Regex]::Replace($c, $pattern, '').TrimEnd()
        if ($new -ne $c.TrimEnd()) {
            Set-Content -Path $profilePath -Value $new -Encoding UTF8
            Ok "profile snippet removed from $profilePath"
        } else {
            Warn "no gc2cc block found in $profilePath"
        }
    }
}

Write-Host ''
Ok 'gc2cc uninstall complete.'
Write-Host ''
Write-Host 'Note: GitHub Copilot auth token at ~/.local/share/copilot-api/github_token was NOT removed.'
Write-Host '      Delete it manually if you want to fully reset.'
