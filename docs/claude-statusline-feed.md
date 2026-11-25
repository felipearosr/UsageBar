---
summary: "UsageBar's opt-in Claude Code statusLine feed: what it captures, how it replaces the throttled OAuth usage poll, and its account binding."
read_when:
  - Changing Claude source routing, the statusLine capture command, or the observation store
  - Debugging Claude 429s or stale Claude numbers on Linux
---

# Claude Code statusLine feed (UsageBar)

Fork-only. Upstream shipped this as #2769 and removed it in #3006 before a release; UsageBar restores the Core and CLI
parts for Linux, where `/api/oauth/usage` 429s even at one request every five minutes per machine. The macOS settings
UI and managed installer were not restored: the feed is turned on in `config.json` and wired by hand.

## Why

Measured on 2026-10-28 with two machines on one account and `linux/claude-usage-ratelimit-probe.py`: with one machine
silent for 25 minutes, the other, sending one request every five minutes, still got 429 on 2 of 5 requests. Responses
come back in 30–50 ms with `Retry-After: 0` and no rate-limit headers. Coordinating machines cannot fix that; avoiding
the request can. Claude Code receives the same windows on every Messages API response and passes them to the
`statusLine` command, so reading them costs nothing.

## What is captured

`codexbar claude statusline capture` reads at most 1 MiB of statusLine JSON from stdin and keeps only
`rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage` in 0...100, `resets_at` as a plausible Unix
epoch). It stores them with the capture time, a hash of `CLAUDE_CONFIG_DIR` (the profile), and a hash of the account
UUID that Claude Code's own config (`.claude.json`) reports as signed in. Nothing else from the payload is kept: no
session, cwd, model, cost, or raw stdin. With no signed-in account in that config, nothing is written. The command never
prints, so it cannot change the status line.

Observations live at `~/.local/share/CodexBar/claude-statusline/<profile-hash>.json` (directory 0700, file 0600).

## Other places Claude Code reports the same windows

The statusLine command only runs in Claude Code's interactive terminal UI. Tools that drive Claude Code through the
Agent SDK or headless never run it, yet they receive the same windows. With the feed on, `ClaudeUsageFeedHarvester`
(`ClaudeUsageFeedSources.swift`) runs before the fresh read and copies the newest of these into the store when it is
newer than the stored capture, tagged with its `origin`:

| Origin | Read from | Used only when |
| --- | --- | --- |
| `t3code` | The newest `rate_limit_event` in the 16 most recently written logs in `~/.t3/userdata/logs/provider` (last 2 MiB of each). `unifiedWindows.five_hour`/`seven_day` `utilization` is a fraction. | The event's `session_id` names a transcript in this profile's `projects/` whose `session-owner` line is the signed-in account. |

The file's modification time is set to the reading's time, so the extension's health check ages it correctly.
Observations written before origins existed have none and count as the statusLine.

Orca is not read. Its only way to print its last Claude reading, `orca-ide account list --json`, also makes Orca
refresh every provider it knows. Its Antigravity check runs `agy acp` with file token storage, so it never sees the
keyring sign-in and opens a Google sign-in page in Orca's browser. Polling it before each Claude fetch opened that page
over and over. The `orca` and `orca-dev` origins still parse, so captures stored by earlier builds keep their labels.

## How it is used

Opt in with `"statusLineFeed": true` on the `claude` provider entry. It applies to the ambient account in Auto and OAuth
source modes, never to a selected token account. `ClaudeStatusLineFeedRouting` changes the planned chain in two ways:

1. `claude.statusline` goes first: an observation at most 15 minutes old for the current account, with both of its
   windows still current. It answers and no usage request is sent.
2. The planned OAuth step is wrapped. When OAuth throws a usage rate limit (`ClaudeUsageError.isClaudeOAuthUsageRateLimit`)
   and an observation at most 6 hours old exists, that observation answers, with any window whose `resets_at` has
   passed removed. Otherwise the OAuth error and its fallback decision pass through unchanged, so no other failure ever
   shows a stale capture and the rest of the plan runs exactly as before.

An observation is ignored unless its account hash matches the account signed in now, so switching accounts can never
show the previous account's numbers.

Feed snapshots carry the two windows only. Model-scoped weekly limits, extra usage, credits and plan details come back
when an OAuth refresh succeeds.

## How stale numbers look

A stale answer is a success with source `statusline-stale`. The GNOME extension greys a row with that source, the
same way it greys last good numbers it carries forward over a provider error (`mergeStale`). Feed rows answer with
their origin's source label (`statusline`, `t3code`, `orca`, `orca-dev`, and the same with `-stale`), and the card
badges them **statusLine**, **T3 Code**, **Orca** or **Orca dev**, so fed numbers are always labelled with the record
they came from; OAuth rows (source `oauth`) render as before.

## With claude-swap

With claude-swap enabled, `codexbar serve` lists Claude's accounts from `cswap --list --json` instead of fetching the
ambient account (`CLIServeClaudeSwap.swift`). What Claude Code knows about its account then applies to at most one slot:
the one whose email and organization match Claude Code's current `oauthAccount` in `.claude.json` (a plain file read;
never the Keychain). It is never matched by position: with no match, or with two slots sharing that email and
organization, no row changes.

- That slot's `loginMethod` is the plan from `oauthAccount.organizationType` (`claude_max` → `Claude Max`), so the
  extension's plan tag works as it does for the ambient row.
- With the feed on, a capture newer than the slot's `usageFetchedAt` replaces the windows it has and keeps claude-swap's
  others; the row's source becomes `statusline` (or `statusline-stale` past 15 minutes). Its `updatedAt` is the capture
  time only when the capture replaced every window claude-swap had, otherwise claude-swap's older time.
