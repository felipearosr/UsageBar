# UsageBar Changelog

Fork-only changes (UsageBar, the Linux port of CodexBar). Upstream changes are in the root `CHANGELOG.md`, which stays
identical to upstream (steipete/CodexBar).

## Unreleased

### Added
- Provider Accounts: a key or cookie provider with several token accounts (OpenRouter, Copilot, Cursor, z.ai and the rest) shows one row per account on its card, each with its own Quota windows, reset times, an **active** marker, "updated X ago" and its own error, so one bad key no longer hides the others. `codexbar serve` answers `GET /usage?accounts=all` with one row per account (`accountId`, `accountSource`, `accountLabel`, `active`, `updatedAt`) and lists `providerAccountRows` on `/health`; plain `/usage` and providers with one account are unchanged, and an extension talking to an older CLI keeps single-account cards.
- Provider Accounts: managed Codex accounts show as rows on the Codex card next to the everyday Codex login, which is marked **active**. A managed account that is the everyday login shows once, and a failing managed account shows its error on its own row only. Each managed row reads its own Codex home and never the everyday login's personal access token. Without managed accounts the Codex card is unchanged. (#168)
- CLI: `codexbar codex-accounts list [--json]` now runs on Linux. It lists managed Codex accounts (one CodexBar-owned Codex home per account) without credential contents and marks the one matching the system Codex login. `codex-accounts promote` stays macOS-only and says so. (#167)
- Claude: opt-in Claude Code statusLine feed (`"statusLineFeed": true` on the `claude` provider in config.json). Pipe your statusLine payload to `codexbar claude statusline capture`; a capture from the last 15 minutes replaces the throttled `/api/oauth/usage` request, and when OAuth is rate limited a capture up to 6 hours old is shown greyed instead of the error, minus windows that have since reset; every other OAuth outcome is unchanged. Captures are bound to the signed-in Claude account. Restored from upstream #2769, which upstream removed in #3006.
- CLI: the install script and the CLI-only `.deb`, `.rpm` and AUR packages install the command as `usagebar`, keeping `codexbar` as its older name, so it's easy to tell apart from upstream's `codexbar`. The install script now installs next to an upstream `codexbar` instead of refusing, and leaves that one alone. The extension and the tray look for `usagebar` before `codexbar`.
- Linux development: add a nested-GNOME dashboard smoke test with deterministic fixtures, rendered-control assertions, interaction checks, logs, and a screenshot artifact.

### Fixed
- Popover: provider errors no longer dump raw messages or JSON into the overview. Each failing row shows a short state (Sign-in expired, Rate limited, Can't reach server, …). One banner above the rows says which providers need you, with **Fix** (opens the login for the first one) and **Details**. Details opens a dialog that groups every issue by what you can do about it, with a plain explanation, since when, Sign in or Retry, and collapsible technical details you can copy.
- Popover: make navigation the header, place refresh status alongside it, and group the compact machine picker and spend summary in one card; retain highlighted machine selections and aligned checkmarks. The machine list opens over the spend summary instead of pushing the popover content down. The spend summary hover now fills the card with an even inset, a subtle outline and a chevron hinting at the cost dashboard.
- Spend: a provider whose local cost scan fails (such as a Claude scan timeout) no longer counts as $0. Its last good report is kept, or else this Machine's synced copy is used, so All machines matches the Machines tab.
- Machines: the tab is now a table of Machines with Today, 30 days and Share columns, a status line per Machine and the total in a tinted band; coverage and provider marks live in each Machine's detail. The note naming the Providers tab's spend scope is gone.
- Claude OAuth: share quota snapshots and a cross-process request lock on Linux; honor shared rate-limit cooldowns even for manual refresh, with exponential backoff and Retry-After support. Cached snapshots exclude reset-credit inventory and credentials.
- OpenCode: fall back to local usage history in Auto mode when browser cookies are unavailable, so the provider reports usage on Linux instead of the macOS-only web error.
- Linux cost dashboard: keep the day-range tabs on-screen by avoiding an overflowing multi-child header allocation.
- Linux overview: move provider reordering from every overview row into a dedicated Providers settings group.
