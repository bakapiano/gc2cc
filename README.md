# gc2cc

Run **Claude Code** backed by **GitHub Copilot's models** on Windows, with a one-line installer.

What this gives you:

- An always-on Windows service (`gc2cc-copilot-api`) that proxies GitHub Copilot's models to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- Two PowerShell shortcuts:
  - `cc`  → `claude --dangerously-skip-permissions`
  - `ccp` → same, but routed through the Copilot proxy with a model picker
- 1M-context support via the `[1m]` suffix trick — the proxy is the [bakapiano/copilot-api fork at `feat/1m-suffix`](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix), which strips the suffix before forwarding so Claude Code locally enables 1M-context mode while Copilot sees the bare model id.

## Install

Open **PowerShell as Administrator** (NSSM service registration requires it), then:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 | iex
```

The installer will:

1. Install missing prereqs (`git`, `node`, `bun`) via `winget`.
2. Download NSSM 2.24 into `%LOCALAPPDATA%\gc2cc\bin\nssm.exe`.
3. Clone `bakapiano/copilot-api@feat/1m-suffix` into `%LOCALAPPDATA%\gc2cc\copilot-api\` and `bun install`.
4. Prompt you once for **GitHub Copilot device-code auth** (you'll see a URL and a code — open it in a browser, paste the code, authorize).
5. Register the Windows service `gc2cc-copilot-api`, set it to auto-start, and start it.
6. `npm install -g @anthropic-ai/claude-code`.
7. Append `cc` / `ccp` to your `$PROFILE` between sentinel markers.

Open a **fresh** PowerShell window after install so the profile reloads.

## Usage

```powershell
cc                                    # plain Claude Code (your normal Anthropic auth)
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
```

In `ccp`, option **1** (`claude-opus-4.7[1m]`) gives you Opus 4.7 with Claude Code's 1M-context mode enabled locally while the proxy talks to Copilot's `claude-opus-4.7`.

## Service control

```powershell
Get-Service gc2cc-copilot-api          # state
Restart-Service gc2cc-copilot-api      # restart
```

Logs: `%LOCALAPPDATA%\gc2cc\logs\copilot-api.{out,err}.log`. Auto-rotated at 5 MB.

Quick health check + log helper:

```powershell
irm https://bakapiano.github.io/gc2cc/status.ps1 | iex                       # show service + reachable models

# or download for arg passing:
irm https://bakapiano.github.io/gc2cc/status.ps1 -OutFile status.ps1
.\status.ps1 -Action restart
.\status.ps1 -Action tail
```

## Updating

Re-run the install one-liner. The script is idempotent — it pulls the latest `feat/1m-suffix`, re-`bun install`s, re-registers the service, and replaces the profile block in place.

## Uninstall

```powershell
irm https://bakapiano.github.io/gc2cc/uninstall.ps1 | iex
```

Removes the service, the install dir, the global `@anthropic-ai/claude-code` package, and the `cc`/`ccp` block from your profile.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To use a non-default port or skip steps:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Available switches: `-Port`, `-ServiceName`, `-InstallDir`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipProfile`.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\copilot-api\` | bakapiano/copilot-api clone (`feat/1m-suffix`) |
| `%LOCALAPPDATA%\gc2cc\bin\nssm.exe` | NSSM service wrapper |
| `%LOCALAPPDATA%\gc2cc\logs\` | proxy stdout/stderr (rotated at 5 MB) |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| `$PROFILE` | `cc`/`ccp` functions, between `# >>> gc2cc` / `# <<< gc2cc` sentinels |

The service runs as `LocalSystem` with `USERPROFILE` redirected to the installing user's home directory, so the proxy finds the GitHub token at the right `~/.local/share/copilot-api/github_token`.

## Credits

- Proxy: [bakapiano/copilot-api](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix) — fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Service wrapper: [NSSM](https://nssm.cc/).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
