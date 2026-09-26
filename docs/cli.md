---
summary: "CodexBar CLI for fetching usage from the command line."
read_when:
  - "You want to call CodexBar data from scripts or a terminal."
  - "Adding or modifying Commander-based CLI commands."
  - "Aligning menubar and CLI output/behavior."
---

# CodexBar CLI

A lightweight Commander-based CLI that mirrors the menu bar app’s provider fetchers and config file.
Use it when you need usage numbers in scripts, CI, or dashboards without UI.

## Install
- In the app: **Preferences → Advanced → Install CLI**. This symlinks `CodexBarCLI` to `/usr/local/bin/codexbar` and `/opt/homebrew/bin/codexbar`.
- From the repo, after installing `CodexBar.app` in `/Applications`: `./bin/install-codexbar-cli.sh` (same symlink targets).
- Manual: `ln -sf "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI" /usr/local/bin/codexbar`.

### Release tarball install (macOS/Linux)
- Homebrew formula (Linux today): `brew install steipete/tap/codexbar`.
- Download release tarballs from GitHub Releases:
  - macOS: `CodexBarCLI-v<tag>-macos-arm64.tar.gz`, `CodexBarCLI-v<tag>-macos-x86_64.tar.gz`
  - Linux (glibc): `CodexBarCLI-v<tag>-linux-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-x86_64.tar.gz`
  - Linux (static musl): `CodexBarCLI-v<tag>-linux-musl-aarch64.tar.gz`, `CodexBarCLI-v<tag>-linux-musl-x86_64.tar.gz`
- Extract and run `./codexbar` (symlink) or `./CodexBarCLI`.

```
tar -xzf CodexBarCLI-v0.17.0-macos-x86_64.tar.gz
./codexbar --version
./codexbar usage --format json --pretty
```

## Build
- `./Scripts/package_app.sh` (or `./Scripts/compile_and_run.sh`) bundles `CodexBarCLI` into `CodexBar.app/Contents/Helpers/CodexBarCLI`.
- Standalone: `swift build -c release --product CodexBarCLI` (binary at `./.build/release/CodexBarCLI`).
- Dependencies: Swift 6.2+, Commander package (`https://github.com/steipete/Commander`).

## Configuration
CodexBar reads the resolved config file for provider settings, secrets, and ordering. New installs use
`~/.config/codexbar/config.json`; absolute `XDG_CONFIG_HOME` paths and `CODEXBAR_CONFIG` are supported, and existing
`~/.codexbar/config.json` installs keep using the legacy file when no XDG config exists.
See `docs/configuration.md` for the schema.

## Command
- `codexbar` defaults to the `usage` command.
  - `--format text|json` (default: text).
- `codexbar cost` prints local token cost usage for Claude + Codex without web/CLI access.
  - `--format text|json` (default: text).
  - `--refresh` ignores cached scans.
- `codexbar cards` prints a one-shot usage snapshot as a responsive terminal card grid.
  - Reuses the same provider, source, account, credits, and status flags as `codexbar usage`.
  - Account lines and plan badges are included in the card grid by default.
  - `--brief` renders a compact table (Provider / Usage / Reset) instead of the card grid.
  - Stdout is always rendered text; `--json-output` only affects stderr logs (no JSON card payload).
  - Failed providers are summarized in a footer (not rendered as error cards).
  - Honors `$COLUMNS` for layout; falls back to 80 columns. Use `--no-color` for plain output.
  - Kitty, Ghostty, WezTerm, and other truecolor terminals auto-enable enhanced gradients/outlines.
  - Force enhanced mode elsewhere with `CODEXBAR_CARDS_ENHANCED=1`.
  - Exit code is non-zero when any provider fetch fails.
- `codexbar serve` starts a foreground localhost-only HTTP server for usage and cost JSON.
  - `--port <port>` defaults to `8080`.
  - `--refresh-interval <seconds>` defaults to `60` and controls the in-memory response cache TTL.
  - `--request-timeout <seconds>` defaults to `30` and bounds each request before returning `504 Gateway Timeout`; use `0` to keep waiting indefinitely.
  - Provider config is reloaded for each usage/cost request; cache entries are keyed by the loaded config so provider toggles and source changes do not require restarting `serve`.
  - Transient refresh failures fall back to the last good response for up to ten refresh intervals (minimum five minutes) so polling clients do not flicker between data and errors; disabled when `--refresh-interval 0`.
  - v1 binds to `127.0.0.1` only and rejects non-loopback `Host` headers. It does not expose remote bind, auth, CORS, TLS, or daemon mode.
  - Endpoints: `GET /health`, `GET /usage`, `GET /usage?provider=<id|both|all>`, `GET /cost`, `GET /cost?provider=<id|both|all>`, `GET /sync/status`, `POST /sync/push`.
  - `GET /health` returns `{"status":"ok"}` plus a `version` field with the running build (e.g. `"0.37.2"`) when resolvable; clients can compare it against `codexbar --version` to detect a `serve` process still running an older binary after an update.
  - Machine Sync: `GET /sync/status` returns `{"paired": false}` when this Machine isn't in a Sync Group. Otherwise it returns `paired`, `status` (the `codexbar sync status --json` payload built from the local cache, absent until the first read), `refreshedAt` (last successful read of the Sync Server), and `error` when this request's read failed. It reads only local files unless `?refresh=1` asks it to pull new blobs first. `POST /sync/push` runs one push cycle and answers like `codexbar sync push --json`, or `409` when not paired and `502` when the push failed. Concurrent refreshes, and concurrent pushes, share one run.
  - Codex usage responses include every visible Codex account, matching the menu bar switcher.
- `codexbar cache clear` clears local CodexBar caches.
  - `--cookies` removes cached browser-cookie headers from the CodexBar Keychain cache.
  - `--cookies --provider <id>` removes browser-cookie cache entries for that provider, including managed Codex account scopes.
  - `--cost` removes local cost-usage scan caches.
  - `--all` clears both cookies and cost caches. `--provider` is cookie-only and cannot be combined with `--cost` or `--all`.
- `codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>] [--yes]` creates a Machine Sync group (see `docs/machine-sync-protocol.md`).
  - Generates the Sync Group key locally, registers the group on the server, backfills this Machine's Spend, and prints the Pairing Link. The link is the recovery key: store it somewhere safe.
  - `--token` is needed only when the server's `GET /v1/info` reports `enrollment: required`.
  - `http://` servers other than loopback print a warning (the bearer credential would travel unencrypted) and ask for confirmation; non-interactive runs need `--yes`.
  - Settings live in `sync.json` next to `config.json` (mode `0600`); the app and the CLI share its Machine ID.
- `codexbar sync pair <pairing-link> [--name <display-name>] [--yes]` joins an existing Sync Group from another Machine.
  - Checks the server and the key (`GET /v1/info`, then `changes`) before saving anything, so a wrong or mistyped link leaves this Machine unpaired.
  - A `codexbar-sync+http://` link to a host that isn't loopback prints a warning and asks for confirmation; non-interactive runs need `--yes`.
  - Then backfills: one `day-*` blob per UTC day with Spend in the local logs, oldest first, going back no further than the server's `retentionDays` (400 days when the server doesn't say). If the backfill fails partway, the next `sync push` finishes it.
  - Re-pairing after leaving reuses the Machine ID in `sync.json`.
- `codexbar sync push` uploads today's and yesterday's UTC Spend Buckets plus the Machine profile, skipping blobs whose content hasn't changed.
  - Does nothing (and makes no network calls) until `sync create` or `sync pair` has run; exits non-zero with a hint.
  - The first push after `create` or `pair` is the backfill (see above).
  - `profile` is uploaded again whenever the last upload is 2 minutes old or more, even with no new Spend, so the server's Last Seen for an online Machine stays fresh. `coverageStart` never names a day older than the server keeps.
  - Takes an exclusive lock on `sync.lock`; a second concurrent push exits 0 without uploading.
  - Rate limits (`429`), server errors (`5xx`), and network errors back off exponentially from 60 s, capped at 15 minutes.
  - `--format json` prints `{"status":"pushed|locked|backing_off","uploaded":[...],"unchanged":n,"nextAttemptAt":...}`.
- `codexbar sync status [--timezone <iana-id>] [--day-start <hour>] [--json]` shows every Machine in the Sync Group.
  - For each Machine: display name, active (Last Seen under 5 minutes), today's and 30-day Spend (cost, tokens, requests), the 30-day split by provider and model, and Coverage as a date range (`coverageStart` to Last Seen, UTC dates).
  - Days are Reporting Days: the timezone and start hour from `"reportingDay": {"timeZone": "Europe/Berlin", "startHour": 4}` in `sync.json`, else the system timezone starting at midnight. The flags override both for one run.
  - Keeps a decrypted cache in `sync-cache.json` (mode `0600`) with the server's `changes` cursor, so later runs fetch only blobs written since.
  - A blob that fails to decrypt or parse is left out entirely (its older copy too) and listed under the errors until a readable copy replaces it.
  - `--json` prints the same data for other surfaces: `generatedAt`, `reportingDay`, `today`, `machines[]` (with `today`, `last30Days`, `models`, `days`, `coverage`), `total`, and `errors`.
- `codexbar sync install-timer [--uninstall]` runs `sync push` in the background on a Machine without a desktop surface (VPS, SSH devbox).
  - Linux: writes `codexbar-sync-push.service` and `codexbar-sync-push.timer` to `~/.config/systemd/user/` (or `$XDG_CONFIG_HOME/systemd/user/`), then runs `systemctl --user daemon-reload` and `enable --now` on the timer. Pushes start 130-170 s apart (`OnUnitActiveSec=130s`, `RandomizedDelaySec=40s`).
  - No graphical session is needed, but a user timer stops when the user's last session ends. Run `loginctl enable-linger $USER` to keep it going; the command says so when lingering is off.
  - macOS: writes `~/Library/LaunchAgents/com.steipete.codexbar.sync-push.plist` (`StartInterval` 150 s, each run first sleeps 0-20 s) and bootstraps it into `gui/<uid>`, or `user/<uid>` when nobody is logged in at the screen.
  - Requires a paired Machine. Reinstalling replaces the files. The job runs the `codexbar` path that installed it.
  - `CODEXBAR_CONFIG`, `XDG_CONFIG_HOME`, `CODEX_HOME`, and `CLAUDE_CONFIG_DIR`, when set, are written into the job so it reads the same `sync.json` and the same Codex and Claude logs as the shell that installed it.
  - Each push takes the push lock, so the timer coexists with the desktop app or GNOME extension on the same Machine.
  - `--uninstall` stops the job and deletes only those files; `sync.json` and the Sync Group are untouched.
- `codexbar sync link` prints this Machine's Pairing Link on stdout and a warning on stderr: the link is the group key and the recovery key. `--json` prints `{"pairingLink","server"}`.
- `codexbar sync rename <display-name>` saves a new display name in `sync.json` and pushes `profile` right away so other Machines see it on their next read. Unpaired, it only saves the name for the next `pair`.
- `codexbar sync retire <machine-id-or-name>` marks another Machine as retired, for example after a reinstall.
  - Adds it to the group `retired` blob with read-modify-write: `GET` the blob and its ETag, add the entry, `PUT` with `If-Match`. A `412` means another Machine wrote first, so it re-reads and retries (up to 5 times). Other Machines' entries and unknown fields are kept.
  - Retired Machines still count toward totals and show as `retired` in `sync status`. A retired Machine that pushes again shows as active again; retiring it again hides it again.
  - The Machine is matched by Machine ID, else by display name (ignoring case). A name shared by several Machines is refused with their IDs. This Machine can't retire or forget itself; use `leave`.
- `codexbar sync forget <machine-id-or-name> [--yes]` deletes another Machine and all its blobs from the Sync Server (`DELETE /v1/groups/{id}/machines/{machine}`). It asks first; without a terminal, or with JSON output, it needs `--yes`.
- `codexbar sync leave [--yes]` unpairs this Machine: removes the Pairing Link from `sync.json` and deletes `sync-state.json` and `sync-cache.json`. Its data stays on the server, and the Machine ID and name are kept, so `sync pair` with the same link restores the same Machine. It asks first; `--yes` skips the question. Refused while a push holds `sync.lock`.
- `--provider <id|both|all>` (default: enabled providers in config; falls back to defaults when missing).
  - Provider IDs live in the config file (see `docs/configuration.md`).
  - With three or more providers enabled, the default stays scoped to enabled providers; use `--provider all` to query
    every registered provider.
  - `--account <label>` / `--account-index <n>` / `--all-accounts` (token accounts from config, or all visible Codex accounts for Codex; requires a single provider).
  - `--no-credits` (hide Codex credits in text output).
  - `--pretty` (pretty-print JSON).
  - `--status` (fetch provider status pages and include them in output).
  - `--antigravity-plan-debug` (debug: print Antigravity planInfo fields to stderr).
- `--source <auto|web|cli|oauth|api>` (default: `auto`).
    - `auto`: provider-specific fallback order from `docs/providers.md`.
    - `web`: web-only where that provider exposes an explicit web source; no CLI/API fallback. Browser import is macOS-only, while supported providers can use configured manual cookies on Linux.
    - `cli`: CLI/local-helper source where the provider exposes one (for example Codex RPC/PTy, Claude PTY, Kilo CLI fallback, Kiro CLI, local probes).
    - `oauth`: OAuth-backed source where supported (Codex, Claude, Vertex AI).
    - `api`: API-key/token flow when the provider supports it (OpenAI, Claude Admin API, z.ai, Gemini, Alibaba, Copilot, Kilo, Kimi, Kimi K2, MiniMax, Ollama, Warp, OpenRouter, ElevenLabs, Deepgram, Synthetic, DeepSeek, Moonshot, Doubao, Codebuff, Crof, Venice, AWS Bedrock).
    - Output `source` reflects the strategy actually used (`openai-web`, `web`, `oauth`, `api`, `local`, `cli`, or provider CLI label).
    - Codex web: OpenAI web dashboard (usage limits, credits remaining, code review remaining, usage breakdown).
        - `--web-timeout <seconds>` (default: 60)
        - `--web-debug-dump-html` (writes HTML snapshots to `/tmp` when data is missing)
    - Claude web: claude.ai API (session + weekly usage, plus account metadata when available).
    - Command Code web: commandcode.ai browser session cookies on macOS, or a configured manual cookie on Linux, for monthly credit usage.
    - OpenCode Go auto: local SQLite usage on macOS and Linux, with optional manual-cookie web enrichment.
    - Kilo auto: app.kilo.ai API first, then CLI auth fallback (`~/.local/share/kilo/auth.json`) on missing/unauthorized API credentials.
    - Linux: browser-backed `auto`/`web` modes are not supported; local sources and configured manual-cookie paths remain available where documented.
- Global flags: `-h/--help`, `-V/--version`, `-v/--verbose`, `--no-color`, `--log-level <trace|verbose|debug|info|warning|error|critical>`, `--json-output`, `--json-only`.
  - `--json-output`: JSONL logs on stderr (machine-readable).
  - `--json-only`: suppress non-JSON output; errors become JSON payloads.
- `codexbar config validate` checks the resolved config file for invalid fields.
  - `--format text|json`, `--pretty`, and `--json-only` are supported.
  - Warnings keep exit code 0; errors exit non-zero.
- `codexbar config dump` prints the normalized config JSON.

### Token accounts
The CLI reads multi-account tokens from the same resolved config file as the app.
- Select a specific account: `--account <label>` (matches the label/email in the file).
- Select by index (1-based): `--account-index <n>`.
- Fetch all accounts for the provider: `--all-accounts`.
Account selection flags require a single provider (`--provider claude`, etc.).
For Claude, token accounts accept either `sessionKey` cookies or OAuth access tokens (`sk-ant-oat...`).
OAuth usage requires the `user:profile` scope; inference-only tokens will return an error.

### Codex accounts
For Codex, `--all-accounts` and `codexbar serve` enumerate the same visible accounts as the app switcher:
managed Codex accounts from `managed-codex-accounts.json` plus the live system account when present.
Each fetch is scoped to that account's Codex home before the normal Codex web/OAuth/CLI strategy runs, and JSON
payloads include the visible account label in `account`.

### Cost JSON payload
`codexbar cost --format json` emits an array of payloads (one per provider).
- `provider`, `source`, `updatedAt`
- `sessionTokens`, `sessionCostUSD`
- `last30DaysTokens`, `last30DaysCostUSD`
- `daily[]`: `date`, `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`, `modelsUsed`, `modelBreakdowns[]` (`modelName`, `cost`)
- Codex only: `projects[]`: `name`, `path`, `totalTokens`, `totalCost`, `daily[]`, `modelBreakdowns[]`, `sources[]`
- `totals`: `inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, `totalTokens`, `totalCost`

## Example usage
```
codexbar                          # text, respects app toggles
codexbar --provider claude        # force Claude
codexbar --provider all           # query all registered providers
codexbar --format json --pretty   # machine output
codexbar --format json --provider both
codexbar cost                     # local cost usage (default 30-day window + today)
codexbar cost --days 90           # choose a 1...365 day cost window
codexbar cost --provider codex --group-by project
codexbar cost --provider claude --format json --pretty
codexbar serve --port 8080        # localhost HTTP JSON server
codexbar serve --request-timeout 0 # disable serve request deadlines
COPILOT_API_TOKEN=... codexbar --provider copilot --format json --pretty
codexbar --status                 # include status page indicator/description
codexbar --provider codex --source oauth --format json --pretty
codexbar --provider codex --source web --format json --pretty
codexbar --provider codex --all-accounts --format json --pretty
codexbar --provider claude --account steipete@gmail.com
codexbar --provider claude --all-accounts --format json --pretty
codexbar --json-only --format json --pretty
codexbar --provider gemini --source api --format json --pretty
KILO_API_KEY=... codexbar --provider kilo --source api --format json --pretty
MOONSHOT_API_KEY=... codexbar --provider moonshot --source api --format json --pretty
codexbar config validate --format json --pretty
codexbar config dump --pretty
printf '%s' "$OPENAI_ADMIN_KEY" | codexbar config set-api-key --provider openai --stdin
codexbar config enable --provider grok
codexbar cache clear --cookies
codexbar cache clear --cookies --provider claude
codexbar cache clear --all --format json --pretty
```

### Sample output (text)
```
== Codex 0.6.0 (codex-cli) ==
Session: 72% left [========----]
Pace: 12% in deficit | Expected 16% used | Projected empty in 2h 30m
Resets today at 2:15 PM
Weekly: 41% left [====--------]
Pace: 6% in reserve | Expected 47% used | Lasts until reset
Resets Fri at 9:00 AM
Credits: 112.4 left

== Claude Code 2.0.58 (web) ==
Session: 88% left [==========--]
Pace: On pace | Expected 13% used | Lasts until reset
Resets tomorrow at 1:00 AM
Weekly: 63% left [=======-----]
Pace: On pace | Expected 37% used | Runs out in 4d
Resets Sat at 6:00 AM
Sonnet: 95% left [===========-]
Account: user@example.com
Plan: Pro

== Kilo (cli) ==
Credits: 60% left [=======-----]
40/100 credits
Plan: Kilo Pass Pro
Activity: Auto top-up: visa
Note: Using CLI fallback
```

### Sample output (JSON, pretty)
```json
{
  "provider": "codex",
  "version": "0.6.0",
  "source": "openai-web",
  "status": { "indicator": "none", "description": "Operational", "updatedAt": "2025-12-04T17:55:00Z", "url": "https://status.openai.com/" },
  "usage": {
    "primary": { "usedPercent": 28, "windowMinutes": 300, "resetsAt": "2025-12-04T19:15:00Z" },
    "secondary": { "usedPercent": 59, "windowMinutes": 10080, "resetsAt": "2025-12-05T17:00:00Z" },
    "tertiary": null,
    "updatedAt": "2025-12-04T18:10:22Z",
    "identity": {
      "providerID": "codex",
      "accountEmail": "user@example.com",
      "accountOrganization": null,
      "loginMethod": "plus"
    },
    "accountEmail": "user@example.com",
    "accountOrganization": null,
    "loginMethod": "plus"
  },
  "pace": {
    "primary": { "stage": "ahead", "deltaPercent": 12, "expectedUsedPercent": 16, "willLastToReset": false, "etaSeconds": 9000, "summary": "12% in deficit | Expected 16% used | Projected empty in 2h 30m" },
    "secondary": { "stage": "slightlyBehind", "deltaPercent": -6, "expectedUsedPercent": 47, "willLastToReset": true, "summary": "6% in reserve | Expected 47% used | Lasts until reset" }
  },
  "credits": { "remaining": 112.4, "updatedAt": "2025-12-04T18:10:21Z" },
  "antigravityPlanInfo": null,
  "openaiDashboard": {
    "signedInEmail": "user@example.com",
    "codeReviewRemainingPercent": 100,
    "creditEvents": [
      { "id": "00000000-0000-0000-0000-000000000000", "date": "2025-12-04T00:00:00Z", "service": "CLI", "creditsUsed": 123.45 }
    ],
    "dailyBreakdown": [
      {
        "day": "2025-12-04",
        "services": [{ "service": "CLI", "creditsUsed": 123.45 }],
        "totalCreditsUsed": 123.45
      }
    ],
    "updatedAt": "2025-12-04T18:10:21Z"
  }
}
```

## Exit codes
- 0: success
- 2: provider missing (binary not on PATH)
- 3: parse/format error
- 4: CLI timeout
- 1: unexpected failure

## Notes
- CLI uses the config file for enabled providers, ordering, and secrets.
- CLI binary discovery checks explicit overrides, captured login PATH, inherited PATH, and known install paths before falling back to an interactive shell probe.
- Reset lines follow the in-app reset time display setting when available (default: countdown).
- Text output uses ANSI colors when stdout is a rich TTY; disable with `--no-color` or `NO_COLOR`/`TERM=dumb`.
- Copilot CLI queries require an API token via config `apiKey` or `COPILOT_API_TOKEN`.
- OpenAI API charts require an Admin API key for organization costs/usage. Normal API keys can only use the legacy balance fallback.
- Claude Admin API charts require an Anthropic Admin API key (`sk-ant-admin...` or `ANTHROPIC_ADMIN_KEY`).
- Codex CLI `auto` tries the OpenAI web dashboard, then Codex CLI RPC/PTy; the app’s Codex `auto` path prefers OAuth when credentials are present, then CLI.
- Claude CLI `auto` tries web, then CLI PTY; the app’s Claude `auto` path prefers OAuth, then CLI, then web.
- Kilo text output splits identity into `Plan:` and `Activity:` lines; in `--source auto`, resolved CLI fetches add
  `Note: Using CLI fallback`.
- Kilo auto-mode failures include a fallback-attempt summary line in text mode (API attempt then CLI attempt).
- OpenAI web requires a signed-in `chatgpt.com` session in a supported browser or a manual cookie header. No passwords are stored; CodexBar reuses cookies.
- Safari cookie import may require granting CodexBar Full Disk Access (System Settings → Privacy & Security → Full Disk Access).
- The `openaiDashboard` JSON field is normally sourced from the app’s cached dashboard snapshot; `--source auto|web` refreshes it live via WebKit using a per-account cookie store.
- Future: optional `--from-cache` flag to read the menubar app’s persisted snapshot (if/when that file lands).
