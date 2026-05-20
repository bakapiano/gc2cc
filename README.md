# gc2cc

Run **Claude Code** backed by **GitHub Copilot's models** on Windows, with a one-line installer.

What this gives you:

- A Windows Service (`gc2cc-copilot-api`, managed via [NSSM](https://nssm.cc/)) that auto-starts at boot, runs as `LocalSystem` in the background, and auto-restarts on crash. It proxies GitHub Copilot to an OpenAI/Anthropic-compatible endpoint on `http://localhost:4141`.
- A `ccp` command **on user PATH** that picks a model and launches `claude --dangerously-skip-permissions` against the proxy. Works in any shell — PS 5.1, PS 7, VSCode terminal, cmd. No profile editing.
- The model menu is **built dynamically** from the proxy's `/v1/models` — restart the service and any new Copilot model (gpt-5.5, gpt-5.6, claude-opus-4.8, …) shows up automatically. No need to bump `ccp.ps1`.
- The proxy is [`caozhiyuan/copilot-api`](https://github.com/caozhiyuan/copilot-api) (a.k.a. `@jeffreycao/copilot-api` on npm) — the actively maintained fork of `ericc-ch/copilot-api`. Translates between Anthropic Messages / OpenAI Chat Completions / OpenAI Responses APIs so 1M-context Claude models, gpt-5.5 / 5.4 / 5.3-codex, and Anthropic-native features (`interleaved-thinking`, `advanced-tool-use`, `context-management`) all work end-to-end through Claude Code.

## Install

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 | iex
```

The installer needs **Administrator** (Windows Services live in `HKLM\SYSTEM\...\Services` + the SCM). Run the one-liner from a normal shell — it self-elevates via UAC, you'll see one prompt, and the elevated instance does the work.

The installer will:

1. Self-elevate via UAC if needed (re-fetches `install.ps1` into `%TEMP%` and relaunches `-Verb RunAs`).
2. Install missing prereqs (`node`, `winget`) — `git` and `bun` are no longer required.
3. Download `nssm.exe` from our GitHub Release mirror into `%LOCALAPPDATA%\gc2cc\bin\` (with `nssm.cc` as fallback).
4. `npm install -g @jeffreycao/copilot-api@latest` into a private prefix at `%LOCALAPPDATA%\gc2cc\npm\global\` (so the LocalSystem service has a stable path independent of the user's npm prefix).
5. Prompt you once for **GitHub Copilot device-code auth** (skipped on re-runs if a token is already present).
6. Register the `gc2cc-copilot-api` Windows Service (LocalSystem, auto-start, crash-restart, NSSM-native log rotation at 5 MB) and start it.
7. `npm install -g @anthropic-ai/claude-code` into your *user* npm prefix.
8. Drop `ccp.ps1` + `ccp.cmd` into `%LOCALAPPDATA%\gc2cc\bin\` and add that dir to your **user PATH** (HKCU).

Open a **fresh** shell after install so PATH refreshes.

### Re-running install (upgrade-safe)

`install.ps1` is idempotent and tolerates every prior gc2cc layout we've ever shipped:

- **Pre-NSSM Scheduled Task** (`\gc2cc\gc2cc-copilot-api`): stopped and unregistered.
- **NSSM + bakapiano (git clone + bun)**: stale `copilot-api/` and `run-proxy.ps1` are deleted; the service is removed and re-registered to exec `node` on the new npm-installed `@jeffreycao/copilot-api` entrypoint.
- **GitHub Copilot auth token** stays put — both forks use `~/.local/share/copilot-api/github_token`, so you don't re-auth on upgrade.

If you've ever installed gc2cc, you can re-run the one-liner and it converges. No `uninstall.ps1` needed for upgrades.

### Service account & the GitHub token

The service runs as `LocalSystem`, but Copilot's auth token lives under the *invoking* user's home (`%USERPROFILE%\.local\share\copilot-api\github_token`). The installer sets `nssm AppEnvironmentExtra USERPROFILE=<your-home> HOME=<your-home>` so Node's `os.homedir()` inside the proxy resolves back to your real home — no token copy, no symlinks. Trade-off vs binding the service to your user account: no stored password in LSA, no service breakage when you rotate your password.

## Usage

```powershell
ccp                                   # pick a Copilot-backed model, then Claude Code
ccp --resume                          # any extra args are forwarded to claude
ccp -p "say hi"                       # one-shot via claude -p
ccp -Model gpt-5.5 -p "..."           # skip the picker; -Model accepts -model/-Mode/-mode too
ccp -- --help                         # `--` forwards the rest to claude (so `ccp --help` stays ccp)
ccp --help                            # show ccp usage + current settings

ccp config                            # interactive: pick default model + toggle bypass-permissions
ccp upgrade                           # re-run the gc2cc one-liner installer (UAC will pop)
```

Settings live in `~/.local/share/gc2cc/ccp.json`:

```json
{
  "defaultModel": "claude-opus-4.7",
  "bypassPermissions": true
}
```

- `defaultModel`: skip the picker and use this id on plain `ccp`. Set to `null` (or use `ccp config` → `[0]`) to always prompt.
- `bypassPermissions`: pass `--dangerously-skip-permissions` to claude. Default `true` (the original YOLO behavior). Flip it off if you want claude to ask for tool-use confirmations.

The menu is built fresh from the proxy each time, with these rules:

- Embedding models, Microsoft router shims, and dated snapshots (e.g. `gpt-4o-2024-08-06`) are filtered out.
- The `[1m]`, `-1m-internal`, `-high`, `-xhigh` suffixes are stripped from model ids — see the warning below.
- Preferred families bubble to the top: `claude-opus-4.7` → `gpt-5.5` → `gpt-5.4` → `gemini-3.1-pro` → ...
- The "small/fast" model is picked by family (Claude → `claude-haiku-4.5`, GPT-5 → `gpt-5-mini`, etc).

### Important: do NOT manually pin model ids with `[1m]`

Quoting `caozhiyuan/copilot-api`'s README verbatim:

> When using with Claude Code, please configure the model ID as `claude-opus-4-6` or `claude-opus-4.6` (**without the `[1m]` suffix**, exceeding GitHub Copilot's context window limit too much may lead to **being banned**).

`ccp` already strips the suffix for you. If you hand-edit `settings.json` or override env vars, follow the same rule — the proxy advertises `[1m]` only so Claude Code's UI marks the model as 1M-capable, **not** because you should request it.

GitHub's abuse-detection systems flag bulk/automated Copilot traffic. Use this responsibly:

> Excessive automated or scripted use of Copilot ... may trigger GitHub's abuse-detection systems. You may receive a warning from GitHub Security, and further anomalous activity could result in temporary suspension of your Copilot access.

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

Re-run the install one-liner. The installer always runs `npm install -g @jeffreycao/copilot-api@latest`, so a re-run picks up upstream proxy fixes (the project ships near-daily — check `package.json` version in `%LOCALAPPDATA%\gc2cc\npm\global\node_modules\@jeffreycao\copilot-api\`).

## Uninstall

```powershell
irm https://bakapiano.github.io/gc2cc/uninstall.ps1 | iex
```

Self-elevates via UAC, then removes the service, the install dir (including `bin/` and `npm/`), the user-PATH entry, the global `@anthropic-ai/claude-code` package, and any legacy `ccp` block left over in `$PROFILE`. Also best-effort cleans up legacy Scheduled Tasks from pre-NSSM installs.

The GitHub Copilot auth token at `~\.local\share\copilot-api\github_token` is **not** removed — delete it manually for a full reset.

## Custom args

The `irm | iex` form doesn't accept arguments. To override defaults:

```powershell
irm https://bakapiano.github.io/gc2cc/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -Port 5151 -SkipClaudeCode
```

Switches: `-Port`, `-ServiceName`, `-InstallDir`, `-NpmPackage`, `-SkipAuth`, `-SkipClaudeCode`, `-SkipPath`.

`-NpmPackage` defaults to `@jeffreycao/copilot-api@latest`. Pin a version (`@jeffreycao/copilot-api@1.10.7`) or swap to a different fork (`@somebody-else/copilot-api@latest`) without code changes.

## Layout

| Path | What |
|---|---|
| `%LOCALAPPDATA%\gc2cc\npm\global\` | private npm prefix where `@jeffreycao/copilot-api` is installed |
| `%LOCALAPPDATA%\gc2cc\npm\global\node_modules\@jeffreycao\copilot-api\` | proxy source (after `npm install`) |
| `%LOCALAPPDATA%\gc2cc\bin\nssm.exe` | NSSM service wrapper |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.ps1` | model-picker + claude launcher (PowerShell) |
| `%LOCALAPPDATA%\gc2cc\bin\ccp.cmd` | shim for cmd / non-PowerShell shells |
| `%LOCALAPPDATA%\gc2cc\logs\copilot-api.log` | proxy stdout/stderr (NSSM rotated at 5 MB) |
| `%LOCALAPPDATA%\gc2cc\logs\install.log` | install transcript (handy when self-elevation fails) |
| `~\.local\share\copilot-api\github_token` | GitHub Copilot auth (created by `copilot-api auth`) |
| User PATH (HKCU\Environment) | gets `%LOCALAPPDATA%\gc2cc\bin\` appended |
| HKLM\SYSTEM\...\Services\gc2cc-copilot-api | Windows Service entry |

The service runs at boot (no user login required), so it survives sign-out, lock screen, sleep, and reboots.

## Credits

- Proxy: [caozhiyuan/copilot-api](https://github.com/caozhiyuan/copilot-api) (npm: [`@jeffreycao/copilot-api`](https://www.npmjs.com/package/@jeffreycao/copilot-api)) — the actively maintained fork of [ericc-ch/copilot-api](https://github.com/ericc-ch/copilot-api).
- Service wrapper: [NSSM — the Non-Sucking Service Manager](https://nssm.cc/).
- Claude Code: [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code).
