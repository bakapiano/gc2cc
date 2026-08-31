[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$patchScript = Join-Path $repoRoot 'patch-copilot-api.ps1'
$installedRoot = Join-Path $env:LOCALAPPDATA 'gc2cc\npm\global\node_modules\@jeffreycao\copilot-api'
if (-not (Test-Path -LiteralPath $installedRoot)) { throw "Test fixture source not installed: $installedRoot" }

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gc2cc-patch-smoke-' + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $installedRoot -Destination $testRoot -Recurse
try {
    $bundle = Get-ChildItem -LiteralPath (Join-Path $testRoot 'dist') -Filter 'server-*.js' -File
    $text = Get-Content -LiteralPath $bundle.FullName -Raw
    $start = $text.IndexOf('// gc2cc encrypted replay recovery:')
    if ($start -ge 0) {
        $endMarker = 'const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createRecoveringPooledResponsesWebSocketStream(request));'
        $end = $text.IndexOf($endMarker, $start)
        if ($end -lt 0) { throw 'Installed patched fixture has an incomplete recovery block.' }
        $end += $endMarker.Length
        $original = @'
const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createPooledWebSocketStream(request, {
	createChunk: createResponsesWebSocketStreamChunk,
	isTerminalChunk: isTerminalResponsesStreamChunk,
	openErrorMessage: "Failed to create responses websocket",
	streamErrorMessage: "Responses websocket stream error",
	terminalChunkMissingMessage: "Responses websocket ended without a terminal response"
}));
'@
        $text = $text.Substring(0, $start) + $original + $text.Substring($end)
        [System.IO.File]::WriteAllText($bundle.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
    }

    & $patchScript -PackageRoot $testRoot
    $firstHash = (Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash
    & $patchScript -PackageRoot $testRoot
    $secondHash = (Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash
    if ($firstHash -ne $secondHash) { throw 'Patch is not idempotent.' }

    $patched = Get-Content -LiteralPath $bundle.FullName -Raw
    foreach ($required in @(
        'GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES = 32',
        '!outputStarted && isGc2ccEncryptedReplayError',
        'removeOldestGc2ccEncryptedReplayItem',
        'retrying after removing ${removedCount} oldest encrypted item(s)'
    )) {
        if (-not $patched.Contains($required)) { throw "Patched bundle is missing: $required" }
    }
    & node --check $bundle.FullName
    if ($LASTEXITCODE -ne 0) { throw 'Patched JavaScript failed node --check.' }
    Write-Host 'patch-copilot-api smoke test passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
