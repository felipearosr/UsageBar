# Plan 007: Share Claude quota between Machines (Machine Sync protocol amendment)

> **Status: PROPOSAL — needs the owner's approval before any code.** It amends the Machine Sync protocol, which lists
> syncing Quota as a v1 non-goal (`docs/machine-sync-protocol.md` §1), and it needs a matching change in the Sync
> Server repository (ADR 0003). Decisions to make are listed at the end.

## Problem

Claude quota on Linux now comes from Claude Code's statusLine feed (`docs/claude-statusline-feed.md`). The feed is
local: a Machine only has fresh numbers while a Claude Code session on it is active. An idle laptop still polls
`/api/oauth/usage`, which 429s even at one request every five minutes, and shows stale or missing Claude numbers while
the desktop next to it has fresh ones.

Measured on 2026-10-28 (`linux/claude-usage-ratelimit-probe.py`, two Machines, one account): Anthropic's throttle is
not something Machines can coordinate their way out of. With one Machine silent for 25 minutes the other still got 429
on 2 of 5 requests. So the goal is not a shared request budget. It is **one Machine's fresh observation answering for
the others**, which removes their requests altogether.

## Proposal

### New Machine blob `quota`

One per Machine, rewritten when its content changes, on the existing push cycle (§8.1). Encrypted and padded like every
blob (§5.1).

```json
{
  "v": 1,
  "accounts": [
    {
      "provider": "claude",
      "account": "<the feed's account hash: SHA-256 of the Claude account UUID>",
      "source": "statusline",
      "capturedAt": "2026-10-28T18:10:44Z",
      "fiveHour": { "usedPercent": 42.5, "resetsAt": "2026-10-28T21:00:00Z" },
      "sevenDay": { "usedPercent": 63.0, "resetsAt": "2026-11-02T09:00:00Z" },
      "blockedUntil": "2026-10-28T18:20:00Z"
    }
  ]
}
```

- Only what the local feed or a successful OAuth fetch already produced for the **ambient** account: the two windows,
  the capture time, and the source. Never tokens, email, organization, plan, model-scoped quotas, extra usage, or credits.
- `account` is the same one-way hash the feed already stores. Inside the encrypted blob the Sync Server cannot see it;
  other Machines in the group (the same person) can, which is how they match entries to their own signed-in account.
- `blockedUntil` is optional: the end of this Machine's current OAuth 429 cooldown, if any.
- A Machine with nothing to report deletes nothing; it writes `"accounts": []` only if it previously wrote entries.

### Reading

In `ClaudeStatusLineFeedRouting`, between the local fresh step and OAuth, add `claude.statusline.synced`: the newest
`quota` entry from any Machine for the **current** account hash, at most 15 minutes old by `capturedAt`, with reset
windows dropped. Labelled `statusline-synced` so the card can say which Machine it came from.

Optionally, skip the OAuth step while any Machine's `blockedUntil` for this account is in the future. This only lowers
load; per the measurement above it will not prevent 429s on its own.

Reads reuse §8.3's `changes` poll; no new endpoint.

## Protocol and server changes

1. `docs/machine-sync-protocol.md`:
   - §1: move "Syncing Quota" out of non-goals for the two windows above; keep identities, plans and billing excluded.
   - §5.2: add the `quota` blob.
   - §6.4: name regex becomes `^(profile|quota|retired|day-\d{4}-\d{2}-\d{2})$`.
   - §10: the server additionally learns that a Machine has a `quota` blob and when it changes (write times, padded size).
     Contents stay end-to-end encrypted.
   - §12: add a test vector for a `quota` envelope.
2. Sync Server repository: accept the new name. Retention: `quota` is overwritten in place, so it never accumulates.
3. Feature detection, so new clients work against old servers: add `"features": ["quota-v1"]` to `GET /v1/info`
   (§11 already requires readers to ignore unknown fields). Clients write `quota` only when the server advertises it;
   a `422 invalid_name` disables quota pushes for the session as a fallback.

This stays `/v1`: it adds an optional blob and an optional info field, and old readers skip blobs they don't know.

## Work, in order

1. Protocol doc amendment + test vector (this repo).
2. Sync Server: name regex, `features` in `/v1/info`, tests (server repo).
3. Client push: build the `quota` plaintext from the latest local feed observation / OAuth success; skip unchanged.
4. Client read: `claude.statusline.synced` step and its tests (account mismatch ignored, age limit, reset windows).
5. Optional: shared `blockedUntil` gate on the OAuth step.
6. Machines tab: show "Claude quota from <machine>, N min ago" on the Claude card when the synced step answered.

## Decisions for the owner

1. Approve narrowing the §1 non-goal to allow the two Claude windows (and nothing account-derived)?
2. Feature flag in `/v1/info` (recommended) or a hard server requirement?
3. Include `blockedUntil` (cheap, modest benefit), or leave it out until there is evidence it helps?
4. Should other providers' quota use the same blob later? The shape above allows it via `provider`, but this plan only
   covers Claude.
