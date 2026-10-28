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

Measured on 2026-10-28 with two machines on one account and `Scripts/claude_usage_ratelimit_probe.py`: with one machine
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

## How it is used

Opt in with `"statusLineFeed": true` on the `claude` provider entry. It applies to the ambient account in Auto and OAuth
source modes, never to a selected token account. `ClaudeStatusLineFeedRouting` turns the planned chain into:

1. `claude.statusline`: an observation at most 15 minutes old for the current account. No usage request is sent.
2. the planned OAuth step, wrapped so a usage rate limit (`ClaudeUsageError.isClaudeOAuthUsageRateLimit`) falls through;
3. `claude.statusline.stale`: an observation at most 6 hours old, with any window whose `resets_at` has passed removed;
4. the rest of the plan, unchanged.

An observation is ignored unless its account hash matches the account signed in now, so switching accounts can never
show the previous account's numbers. If the stale step has nothing, the OAuth rate-limit error is what surfaces. Other
OAuth failures keep their existing fallback rules.

Feed snapshots carry the two windows only. Model-scoped weekly limits, extra usage, credits and plan details come back
when an OAuth refresh succeeds.

## serve keeps the last good Claude row

Separately from the feed, `serve` keys the ambient Claude row as `claude:account:<account hash>`. Its existing last-good
merge then replaces a failed Claude row with that account's last good row within the stale window, instead of showing an
empty error card. Without a provable signed-in account the key is nil and nothing is substituted.
