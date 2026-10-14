# UsageBar Changelog

Fork-only changes (UsageBar, the Linux port of CodexBar). Upstream changes are in the root `CHANGELOG.md`, which stays
identical to upstream (steipete/CodexBar).

## Unreleased

### Added
- Linux development: add a nested-GNOME dashboard smoke test with deterministic fixtures, rendered-control assertions, interaction checks, logs, and a screenshot artifact.

### Fixed
- OpenCode: fall back to local usage history in Auto mode when browser cookies are unavailable, so the provider reports usage on Linux instead of the macOS-only web error.
- Linux cost dashboard: keep the day-range tabs on-screen by avoiding an overflowing multi-child header allocation.
- Linux overview: move provider reordering from every overview row into a dedicated Providers settings group.
