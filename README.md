# gc2cc

Run **Claude Code** backed by **GitHub Copilot's models** on Windows, with a one-line installer. **No Administrator required.**

What this gives you:

- A per-user **Scheduled Task** (`gc2cc-copilot-api`) that auto-starts at logon, runs hidden in the background, and auto-restarts on failure. It proxies GitHub Copilot's models to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- A `ccp` PowerShell function that picks a model and launches `claude --dangerously-skip-permissions` against the proxy.
- 1M-context support via the `[1m]` suffix trick — the proxy is the [bakapiano/copilot-api fork at `feat/1m-suffix`](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix), which strips the suffix before forwarding so Claude Code locally enables 1M-context mode while Copilot sees the bare model id.

## Install

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 | iex
```

The installer will:

1. Install missing prereqs (`git`, `node`, `bun`) via `winget`.
2. Clone `bakapiano/copilot-api@feat/1m-suffix` into `%LOCALAPPDATA%\gc2cc\copilot-api\` and `bun install`.
3. Prompt you once for **GitHub Copilot device-code auth** (you'll see a URL and a code — open it in a browser, paste the code, authorize). Skipped on re-runs if a token is already present.
4. Register the per-user Scheduled Task `gc2cc-copilot-api` and start it.
5. `npm install -g @anthropic-ai/claude-code`.
6. Append `ccp` to your `$PROFILE` between sentinel markers.

Open a **fresh** PowerShell window after install so the profile reloads.

## Usage

```powershell
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
```

In `ccp`, option **1** (`claude-opus-4.7[1m]`) gives you Opus 4.7 with Claude Code's 1M-context mode enabled locally while the proxy talks to Copilot's `claude-opus-4.7`.

## Task control

```powershell
Get-ScheduledTask -TaskName gc2cc-copilot-api | Get-ScheduledTaskInfo
Stop-ScheduledTask -TaskName gc2cc-copilot-api
Start-ScheduledTask -TaskName gc2cc-copilot-api
```

Logs: `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` (rotated at 5 MB to `copilot-api.prev.log`).

Quick health check + log helper:

```powershell
irm https://bakapiano.github.io/gc2cc/status.ps1 | iex            # show task + reachable models

# or download for arg passing:
irm https://bakapiano.github.io/gc2cc/status.ps1 -OutFile status.ps1
.\status.ps1 -Action restart
.\status.ps1 -Action tail
```

## Updating

Re-run the install one-liner. The script is idempotent — it pulls the latest `feat/1m-suffix`, re-`bun install`s, re-registers the task, and replaces the `ccp` block in your profile in place.

## Uninstall

```powershell
irm https://bakapiano.github.io/gc2cc/uninstall.ps1 | iex
```

Removes the task, the install dir, the global `@anthropic-ai/claude-code` package, and the `ccp` block from your profile.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To use a non-default port or skip steps:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Available switches: `-Port`, `-TaskName`, `-InstallDir`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipProfile`.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\copilot-api\` | bakapiano/copilot-api clone (`feat/1m-suffix`) |
| `%LOCALAPPDATA%\gc2cc\run-proxy.ps1` | wrapper invoked by the Scheduled Task (rotates logs, runs bun) |
| `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` | proxy stdout/stderr (rotated at 5 MB to `.prev.log`) |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| `$PROFILE` | `ccp` function, between `# >>> gc2cc ccp BEGIN` / `# <<< gc2cc ccp END` sentinels |

The task runs as the installing user with `LogonType Interactive` (no stored credential, no admin), so `~/.local/share/copilot-api/github_token` resolves naturally. The trade-off vs a real Windows Service: the task only runs while you're logged in. For a personal dev machine, that's the right thing.

## Credits

- Proxy: [bakapiano/copilot-api](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix) — fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
