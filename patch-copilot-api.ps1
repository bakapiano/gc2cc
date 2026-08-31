[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageRoot,
    [string] $ExpectedVersion = '1.14.14'
)

$ErrorActionPreference = 'Stop'
$marker = 'gc2cc encrypted replay recovery'
$packageJsonPath = Join-Path $PackageRoot 'package.json'
$distPath = Join-Path $PackageRoot 'dist'
if (-not (Test-Path -LiteralPath $packageJsonPath)) { throw "copilot-api package.json not found: $packageJsonPath" }
$package = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
if ($package.version -ne $ExpectedVersion) { throw "Unsupported copilot-api version '$($package.version)'; expected '$ExpectedVersion'. Refusing to patch an unknown bundle." }
$bundles = @(Get-ChildItem -LiteralPath $distPath -Filter 'server-*.js' -File)
if ($bundles.Count -ne 1) { throw "Expected exactly one copilot-api server bundle under $distPath; found $($bundles.Count)." }
$bundle = $bundles[0]
$source = Get-Content -LiteralPath $bundle.FullName -Raw
if ($source.Contains($marker)) {
    Write-Host "copilot-api encrypted replay recovery already applied: $($bundle.Name)"
    return
}

$old = @'
const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createPooledWebSocketStream(request, {
	createChunk: createResponsesWebSocketStreamChunk,
	isTerminalChunk: isTerminalResponsesStreamChunk,
	openErrorMessage: "Failed to create responses websocket",
	streamErrorMessage: "Responses websocket stream error",
	terminalChunkMissingMessage: "Responses websocket ended without a terminal response"
}));
'@
$new = @'
// gc2cc encrypted replay recovery: retry only a pre-output encrypted-content rejection.
const GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES = 32;
const createRawPooledResponsesWebSocketStream = (request) => createPooledWebSocketStream(request, {
	createChunk: createResponsesWebSocketStreamChunk,
	isTerminalChunk: isTerminalResponsesStreamChunk,
	openErrorMessage: "Failed to create responses websocket",
	streamErrorMessage: "Responses websocket stream error",
	terminalChunkMissingMessage: "Responses websocket ended without a terminal response"
});
const isGc2ccEncryptedReplayItem = (item) => item && typeof item === "object" && ["reasoning", "compaction", "context_compaction"].includes(item.type) && typeof item.encrypted_content === "string" && item.encrypted_content.length > 0;
const isGc2ccEncryptedReplayError = (chunk) => {
	if (!chunk?.data || chunk.data === "[DONE]") return false;
	try {
		const parsed = JSON.parse(chunk.data);
		const message = [parsed.message, parsed.error?.message, parsed.error?.error?.message].filter((value) => typeof value === "string").join(" ");
		return /encrypted content/i.test(message) && /could not be (verified|decrypted|parsed)|decrypt|verif/i.test(message);
	} catch { return false; }
};
const isGc2ccNonSubstantiveResponseChunk = (chunk) => {
	if (!chunk?.data || chunk.data === "[DONE]") return true;
	try {
		const type = JSON.parse(chunk.data).type;
		return type === "response.created" || type === "response.queued" || type === "response.in_progress";
	} catch { return false; }
};
const removeOldestGc2ccEncryptedReplayItem = (request) => {
	const input = request.payload?.input;
	if (!Array.isArray(input)) return null;
	const index = input.findIndex(isGc2ccEncryptedReplayItem);
	if (index < 0) return null;
	return { ...request, payload: { ...request.payload, input: [...input.slice(0, index), ...input.slice(index + 1)] } };
};
const createRecoveringPooledResponsesWebSocketStream = async function* (initialRequest) {
	let request = initialRequest;
	let removedCount = 0;
	while (true) {
		const buffered = [];
		let retryRequest = null;
		let outputStarted = false;
		for await (const chunk of createRawPooledResponsesWebSocketStream(request)) {
			if (!outputStarted && isGc2ccEncryptedReplayError(chunk) && removedCount < GC2CC_MAX_ENCRYPTED_REPLAY_RETRIES) {
				retryRequest = removeOldestGc2ccEncryptedReplayItem(request);
				if (retryRequest) break;
			}
			buffered.push(chunk);
			if (!isGc2ccNonSubstantiveResponseChunk(chunk)) {
				outputStarted = true;
				for (const pending of buffered) yield pending;
				buffered.length = 0;
			}
		}
		if (!retryRequest) {
			for (const pending of buffered) yield pending;
			return;
		}
		removedCount++;
		consola.warn(`gc2cc encrypted replay recovery: retrying after removing ${removedCount} oldest encrypted item(s)`);
		request = retryRequest;
	}
};
const createPooledResponsesWebSocketStream = (request) => createResponsesSafeStream(createRecoveringPooledResponsesWebSocketStream(request));
'@
$occurrences = ([regex]::Matches($source, [regex]::Escape($old))).Count
if ($occurrences -ne 1) { throw "copilot-api bundle structure is unsupported: expected one WebSocket stream anchor, found $occurrences." }
$patched = $source.Replace($old, $new)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($bundle.FullName, $patched, $utf8NoBom)
Write-Host "Applied copilot-api encrypted replay recovery: $($bundle.Name)"
