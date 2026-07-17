#Requires -Version 5.1
<#
.SYNOPSIS
    Isolated smoke test for gc2cc service restart handling.

.DESCRIPTION
    Creates a randomly named, manual-start NSSM service exposing a dummy
    /v1/models endpoint. It exercises status.ps1, the NSSM restart/start
    fallback, and the explicit ccp/cxp proxy-restart functions; verifies that
    each restart changes the PID; and always removes the temporary service. It
    never contacts or controls the production gc2cc-copilot-api service.
#>
[CmdletBinding()]
param(
    [ValidateSet('Test','Server')]
    [string] $Mode = 'Test',
    [string] $ServiceName = ('gc2cc-restart-smoke-{0}' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))),
    [ValidateRange(1024, 65535)]
    [int] $Port = (Get-Random -Minimum 49152 -Maximum 60000),
    [string] $MarkerPath = (Join-Path $env:TEMP "$ServiceName.json"),
    [string] $ResultPath = (Join-Path $env:TEMP "$ServiceName-result.json"),
    [switch] $Elevated
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'Server') {
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    [ordered]@{ pid = $PID; startedAt = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $MarkerPath -Encoding UTF8
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $body = [Text.Encoding]::UTF8.GetBytes('{"data":[{"id":"gc2cc-restart-smoke-model"}]}')
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $body.Length
        $context.Response.OutputStream.Write($body, 0, $body.Length)
        $context.Response.Close()
    }
}

if ($ServiceName -notmatch '^gc2cc-restart-smoke-[0-9a-f]{8}$') {
    throw "Unsafe test service name '$ServiceName'; expected gc2cc-restart-smoke-<8 hex chars>."
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsPowerShellExe {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Wait-ForNewPid([int] $OldPid, [int] $TimeoutSeconds = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $MarkerPath) {
            try {
                $newPid = [int]((Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json).pid)
                if ($newPid -gt 0 -and $newPid -ne $OldPid) { return $newPid }
            } catch {}
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw "Service PID did not change from $OldPid within $TimeoutSeconds seconds."
}

function Wait-ForProxy([int] $TimeoutSeconds = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            Invoke-WebRequest "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop | Out-Null
            return
        } catch {}
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw "Test proxy did not become reachable on port $Port within $TimeoutSeconds seconds."
}

function Get-RestartFunctionDefinitions([string] $Path, [string] $InvokeFunction) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Could not parse wrapper '$Path': $($errors[0].Message)" }
    foreach ($name in @('Test-Proxy','Restart-ProxyWithNssm','Restart-ProxyAndWait',$InvokeFunction)) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $functionAst) { throw "Function '$name' not found in '$Path'." }
        $functionAst.Extent.Text
    }
}

if (-not (Test-IsAdmin)) {
    if ($Elevated) { throw 'UAC child did not receive an elevated administrator token.' }
    Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Mode', 'Test',
        '-ServiceName', "`"$ServiceName`"",
        '-Port', $Port,
        '-MarkerPath', "`"$MarkerPath`"",
        '-ResultPath', "`"$ResultPath`"",
        '-Elevated'
    )
    $process = Start-Process (Get-WindowsPowerShellExe) -Verb RunAs -Wait -PassThru -ArgumentList $argList
    if (Test-Path -LiteralPath $ResultPath) {
        Get-Content -LiteralPath $ResultPath -Raw
        Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
    }
    exit $process.ExitCode
}

$nssm = Join-Path $env:LOCALAPPDATA 'gc2cc\bin\nssm.exe'
$statusScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'status.ps1'
$powershell = Get-WindowsPowerShellExe
$installed = $false
$result = [ordered]@{
    serviceName = $ServiceName
    passed = $false
    statusRestartPid = $null
    nssmRestartPid = $null
    ccpRestartPid = $null
    cxpRestartPid = $null
    error = $null
}

try {
    if (-not (Test-Path -LiteralPath $nssm)) { throw "NSSM not found: $nssm" }
    if (-not (Test-Path -LiteralPath $statusScript)) { throw "status.ps1 not found: $statusScript" }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        throw "Refusing to replace existing service '$ServiceName'."
    }
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        throw "Refusing to use occupied test port $Port."
    }

    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    & $nssm install $ServiceName $powershell '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' $PSCommandPath '-Mode' 'Server' '-Port' $Port '-MarkerPath' $MarkerPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "NSSM install failed (exit $LASTEXITCODE)." }
    $installed = $true
    & $nssm set $ServiceName Start SERVICE_DEMAND_START | Out-Null
    & $nssm set $ServiceName AppDirectory $PSScriptRoot | Out-Null
    & $nssm set $ServiceName AppNoConsole 1 | Out-Null
    & $nssm set $ServiceName AppExit Default Exit | Out-Null
    & $nssm start $ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "NSSM start failed (exit $LASTEXITCODE)." }

    $firstPid = Wait-ForNewPid 0
    Wait-ForProxy
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $statusScript -Action restart -ServiceName $ServiceName
    if ($LASTEXITCODE -ne 0) { throw "status.ps1 restart failed (exit $LASTEXITCODE)." }
    $secondPid = Wait-ForNewPid $firstPid
    $result.statusRestartPid = $secondPid

    & $nssm restart $ServiceName | Out-Null
    if ($LASTEXITCODE -ne 0) { & $nssm start $ServiceName | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "NSSM restart/start failed (exit $LASTEXITCODE)." }
    $thirdPid = Wait-ForNewPid $secondPid
    $result.nssmRestartPid = $thirdPid

    $base = "http://127.0.0.1:$Port"
    $proxyService = $ServiceName
    $ccpScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'ccp.ps1'
    foreach ($definition in (Get-RestartFunctionDefinitions $ccpScript 'Invoke-CcpProxyRestart')) {
        Invoke-Expression $definition
    }
    Invoke-CcpProxyRestart
    $fourthPid = Wait-ForNewPid $thirdPid
    $result.ccpRestartPid = $fourthPid

    $cxpScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'cxp.ps1'
    foreach ($definition in (Get-RestartFunctionDefinitions $cxpScript 'Invoke-CxpProxyRestart')) {
        Invoke-Expression $definition
    }
    Invoke-CxpProxyRestart
    $fifthPid = Wait-ForNewPid $fourthPid
    $result.cxpRestartPid = $fifthPid
    $result.passed = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    try {
        if ($installed -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            & $nssm stop $ServiceName confirm | Out-Null
            & $nssm remove $ServiceName confirm | Out-Null
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
                throw "Temporary service '$ServiceName' still exists after cleanup."
            }
        }
    } catch {
        $result.passed = $false
        $cleanupMessage = "Cleanup failed: $($_.Exception.Message)"
        if ($result.error) { $result.error = "$($result.error) $cleanupMessage" } else { $result.error = $cleanupMessage }
    }
    Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue
    $result | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

$result | ConvertTo-Json
if (-not $result.passed) { exit 1 }
