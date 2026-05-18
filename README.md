# gc2cc

Run **Claude Code** backed by **GitHub Copilot's models** on Windows, with a one-line installer.

What this gives you:

- A Windows Service (`gc2cc-copilot-api`, managed via [NSSM](https://nssm.cc/)) that auto-starts at boot, runs as `LocalSystem` in the background, and auto-restarts on crash. It proxies GitHub Copilot's models to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- A `ccp` command **on user PATH** that picks a model and launches `claude --dangerously-skip-permissions` against the proxy. Works in any shell — PS 5.1, PS 7, VSCode terminal, cmd. No profile editing.
- 1M-context support via the `[1m]` suffix trick — the proxy is the [bakapiano/copilot-api fork at `feat/1m-suffix`](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix), which strips the suffix before forwarding so Claude Code locally enables 1M-context mode while Copilot sees the bare model id.

## Install

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 | iex
```

The installer needs **Administrator** (Windows Services live in `HKLM\SYSTEM\...\Services` + the SCM). When you run the one-liner from a non-elevated shell it self-elevates via UAC — you'll see one prompt and the elevated instance does the work.

The installer will:

1. Self-elevate via UAC if needed (re-fetches `install.ps1` into `%TEMP%` and relaunches `-Verb RunAs`).
2. Install missing prereqs (`git`, `node`, `bun`) via `winget`.
3. Download `nssm.exe` from <https://nssm.cc> into `%LOCALAPPDATA%\gc2cc\bin\`.
4. Clone `bakapiano/copilot-api@feat/1m-suffix` into `%LOCALAPPDATA%\gc2cc\copilot-api\` and `bun install`.
5. Prompt you once for **GitHub Copilot device-code auth** (skipped on re-runs if a token is already present).
6. Register the `gc2cc-copilot-api` Windows Service (LocalSystem, auto-start, crash-restart, online log rotation at 5 MB) and start it.
7. `npm install -g @anthropic-ai/claude-code`.
8. Drop `ccp.ps1` + `ccp.cmd` into `%LOCALAPPDATA%\gc2cc\bin\` and add that dir to your **user PATH** (HKCU).

Open a **fresh** shell after install so PATH refreshes.

### Service account & the GitHub token

The service runs as `LocalSystem`, but Copilot's auth token lives under the *invoking* user's home (`%USERPROFILE%\.local\share\copilot-api\github_token`). The installer sets `nssm AppEnvironmentExtra USERPROFILE=<your-home> HOME=<your-home>` so Node's `os.homedir()` inside the proxy resolves back to your real home — no token copy, no symlinks. Trade-off vs binding the service to your user account: no stored password in LSA, no service breakage when you rotate your password.

## Usage

```powershell
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
ccp -p "say hi"                       # one-shot via claude -p
```

In `ccp`, option **1** (`claude-opus-4.7[1m]`) gives you Opus 4.7 with Claude Code's 1M-context mode enabled locally while the proxy talks to Copilot's `claude-opus-4.7`.

## Service control

```powershell
Get-Service     gc2cc-copilot-api
Restart-Service gc2cc-copilot-api          # needs admin
Stop-Service    gc2cc-copilot-api
Start-Service   gc2cc-copilot-api
```

Or via NSSM directly:

```powershell
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" status  gc2cc-copilot-api
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" restart gc2cc-copilot-api
& "$env:LOCALAPPDATA\gc2cc\bin\nssm.exe" edit    gc2cc-copilot-api   # GUI editor
```

Logs: `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` (NSSM online rotation at 5 MB; older copies are kept as `copilot-api.log-<timestamp>`).

Quick health check + log helper:

```powershell
irm https://bakapiano.github.io/gc2cc/status.ps1 | iex            # show service + reachable models

# or download for arg passing:
irm https://bakapiano.github.io/gc2cc/status.ps1 -OutFile status.ps1
.\status.ps1 -Action restart    # needs admin
.\status.ps1 -Action tail
```

## Updating

Re-run the install one-liner. The script is idempotent — it pulls the latest `feat/1m-suffix`, re-`bun install`s, stops + removes + re-registers the service, and refreshes `ccp.ps1` + `ccp.cmd` under bin. Older installs that put `ccp` in `$PROFILE` get their sentinel block stripped automatically. Older installs that used a Scheduled Task get the task removed before the new service is registered.

## Uninstall

```powershell
irm https://bakapiano.github.io/gc2cc/uninstall.ps1 | iex
```

Self-elevates via UAC, then removes the service, the install dir (including `bin/`), the user-PATH entry, the global `@anthropic-ai/claude-code` package, and any legacy `ccp` block left over in `$PROFILE`. Also best-effort cleans up legacy Scheduled Tasks from pre-NSSM installs.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To override defaults:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Switches: `-Port`, `-ServiceName`, `-InstallDir`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipPath`.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\copilot-api\` | bakapiano/copilot-api clone (`feat/1m-suffix`) |
| `%LOCALAPPDATA%\gc2cc\bin\nssm.exe` | NSSM service wrapper |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.ps1` | model-picker + claude launcher (PowerShell) |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.cmd` | shim for cmd / non-PowerShell shells |
| `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` | proxy stdout/stderr (NSSM rotated at 5 MB) |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| User PATH (HKCU\Environment) | gets `%LOCALAPPDATA%\gc2cc\bin\` appended |
| HKLM\SYSTEM\...\Services\gc2cc-copilot-api | Windows Service entry |

The service runs at boot (no user login required), so it survives sign-out, lock screen, sleep, and reboots — same lifetime as any other Windows Service.

## Credits

- Proxy: [bakapiano/copilot-api](https://github.com/bakapiano/copilot-api/tree/feat/1m-suffix) — fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Service wrapper: [NSSM — the Non-Sucking Service Manager](https://nssm.cc/).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
