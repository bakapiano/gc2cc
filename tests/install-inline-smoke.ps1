[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'install.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $installer,
    [ref]$tokens,
    [ref]$errors
)
if ($errors) { throw "install.ps1 has parser errors: $errors" }
$function = $ast.Find(
    {
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-CopilotPatchPath'
    },
    $true
)
if (-not $function) { throw 'Resolve-CopilotPatchPath was not found.' }
$installerSource = Get-Content -LiteralPath $installer -Raw
if (
    $installerSource.IndexOf('function Resolve-CopilotPatchPath') -gt
    $installerSource.IndexOf('$copilotPatch = Resolve-CopilotPatchPath')
) {
    throw 'Resolve-CopilotPatchPath must be defined before installer execution uses it.'
}
Invoke-Expression $function.Extent.Text

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'gc2cc-inline-installer-' + [guid]::NewGuid().ToString('N')
)
$scriptRoot = Join-Path $testRoot 'source'
$installRoot = Join-Path $testRoot 'target'
New-Item -ItemType Directory -Path $scriptRoot, $installRoot | Out-Null
$sibling = Join-Path $scriptRoot 'patch-copilot-api.ps1'
try {
    $inline = Resolve-CopilotPatchPath -ScriptRoot '' -TargetInstallDir $installRoot
    $expectedDownload = Join-Path $installRoot 'patch-copilot-api.ps1'
    if ($inline -ne $expectedDownload) {
        throw "Inline install did not select the download target: $inline"
    }

    $missingSibling = Resolve-CopilotPatchPath `
        -ScriptRoot $scriptRoot `
        -TargetInstallDir $installRoot
    if ($missingSibling -ne $expectedDownload) {
        throw "Missing companion did not select the download target: $missingSibling"
    }

    New-Item -ItemType File -Path $sibling | Out-Null
    $local = Resolve-CopilotPatchPath `
        -ScriptRoot $scriptRoot `
        -TargetInstallDir $installRoot
    if ($local -ne $sibling) { throw "Local companion was not selected: $local" }
    Write-Host 'install inline smoke test passed'
} finally {
    Remove-Item -LiteralPath $sibling -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scriptRoot -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $installRoot -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Force -ErrorAction SilentlyContinue
}
