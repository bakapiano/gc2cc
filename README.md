# gc2cc

Run **Claude Code** backed by **GitHub Copilot's models** on Windows, with a one-line installer. **No Administrator required.**

What this gives you:

- A per-user **Scheduled Task** (`\gc2cc\gc2cc-copilot-api`) that auto-starts at logon, runs hidden in the background, and auto-restarts on failure. It proxies GitHub Copilot's models to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- A `ccp` command **on user PATH** that picks a model and launches `claude --dangerously-skip-permissions` against the proxy. Works in any shell — PS 5.1, PS 7, VSCode terminal, cmd. No profile editing.
- 1M-context support via the `[1m]` suffix trick — the proxy is the [bakapiano/copilot-api fork at `feat/1m-suffix`](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix), which strips the suffix before forwarding so Claude Code locally enables 1M-context mode while Copilot sees the bare model id.

## Install

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 | iex
```

The installer will:

1. Install missing prereqs (`git`, `node`, `bun`) via `winget`.
2. Clone `bakapiano/copilot-api@feat/1m-suffix` into `%LOCALAPPDATA%\gc2cc\copilot-api\` and `bun install`.
3. Prompt you once for **GitHub Copilot device-code auth** (skipped on re-runs if a token is already present).
4. Register the per-user Scheduled Task `\gc2cc\gc2cc-copilot-api` and start it.
5. `npm install -g @anthropic-ai/claude-code`.
6. Drop `ccp.ps1` + `ccp.cmd` into `%LOCALAPPDATA%\gc2cc\bin\` and add that dir to your **user PATH** (HKCU, no admin).

Open a **fresh** shell after install so PATH refreshes.

## Usage

```powershell
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
ccp -p "say hi"                       # one-shot via claude -p
```

In `ccp`, option **1** (`claude-opus-4.7[1m]`) gives you Opus 4.7 with Claude Code's 1M-context mode enabled locally while the proxy talks to Copilot's `claude-opus-4.7`.

## Task control

```powershell
Get-ScheduledTask -TaskName gc2cc-copilot-api -TaskPath \gc2cc\ | Get-ScheduledTaskInfo
Stop-ScheduledTask  -TaskName gc2cc-copilot-api -TaskPath \gc2cc\
Start-ScheduledTask -TaskName gc2cc-copilot-api -TaskPath \gc2cc\
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

Re-run the install one-liner. The script is idempotent — it pulls the latest `feat/1m-suffix`, re-`bun install`s, re-registers the task, and refreshes `ccp.ps1` + `ccp.cmd` under bin. Older installs that put `ccp` in `$PROFILE` get their sentinel block stripped automatically (the PATH-mounted `ccp` supersedes it).

## Uninstall

```powershell
irm https://bakapiano.github.io/gc2cc/uninstall.ps1 | iex
```

Removes the task, the install dir (including bin/), the user-PATH entry, the global `@anthropic-ai/claude-code` package, and any legacy `ccp` block left over in `$PROFILE`.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To override defaults:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Switches: `-Port`, `-TaskName`, `-TaskPath`, `-InstallDir`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipPath`.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\copilot-api\` | bakapiano/copilot-api clone (`feat/1m-suffix`) |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.ps1` | model-picker + claude launcher (PowerShell) |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.cmd` | shim for cmd / non-PowerShell shells |
| `%LOCALAPPDATA%\gc2cc\run-proxy.ps1` | Scheduled Task wrapper (rotates logs, runs bun) |
| `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` | proxy stdout/stderr |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| User PATH (HKCU\Environment) | gets `%LOCALAPPDATA%\gc2cc\bin\` appended |

The task runs as the installing user with `LogonType Interactive` (no stored credential, no admin), so `~/.local/share/copilot-api/github_token` resolves naturally. The trade-off vs a real Windows Service: the task only runs while you're logged in (lock screen / sleep / reboot are all fine — only sign-out kills it). For a personal dev machine, that's the right thing.

## Credits

- Proxy: [bakapiano/copilot-api](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix) — fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
