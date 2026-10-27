# UsageBar Changelog

Fork-only changes (UsageBar, the Linux port of CodexBar). Upstream changes are in the root `CHANGELOG.md`, which stays
identical to upstream (steipete/CodexBar).

## Unreleased

### Added
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
