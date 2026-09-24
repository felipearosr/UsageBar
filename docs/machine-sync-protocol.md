---
summary: "Machine Sync wire protocol v1: Pairing Link, key derivation, encrypted blobs, and Sync Server HTTP API."
read_when:
  - Implementing the Machine Sync client or a Sync Server
  - Changing what Spend is synced, how it is encrypted, or how Machines pair
  - Reviewing Machine Sync privacy guarantees
---

# Machine Sync protocol (v1)

Status: **draft**. Terms such as Machine, Spend, Spend Bucket, Sync Group, Pairing Link, Sync Server, Enrollment Token, Last Seen, Coverage, and Account Billing are defined in [`CONTEXT.md`](../CONTEXT.md). Background decisions: [ADR 0001](adr/0001-machine-sync-is-end-to-end-encrypted.md) (E2E), [ADR 0002](adr/0002-app-is-sync-server-neutral.md) (server neutrality), [ADR 0003](adr/0003-sync-server-lives-outside-this-repo.md) (server lives elsewhere).

This document is the contract between the CodexBar client and any Sync Server. A server that implements this document is compatible, whoever runs it.

## 1. Goals and non-goals

Goals:

- Every Machine in a Sync Group can show every Machine's Spend, refreshed about every 2.5 minutes.
- The Sync Server can't read Spend, Machine names, providers, or models.
- Self-hosted and hosted servers speak the same protocol.

Non-goals (v1):

- Syncing Quota, Account Billing, project names or paths, provider identities, or raw log content.
- Sync Groups with more than one person (teams), and key rotation.
- Server-side aggregation, alerts, or a web dashboard.

## 2. Pairing Link

```
codexbar-sync://<host>[:<port>][/<base-path>]#<root-key>
codexbar-sync+http://<host>[:<port>][/<base-path>]#<root-key>
```

- `<root-key>`: 32 random bytes, base64url without padding (43 chars). Everything else is derived from it (§3).
- `codexbar-sync://` maps to `https://<host>[:<port>]/<base-path>`. `codexbar-sync+http://` maps to plain `http://` and exists only for loopback or tailnet self-hosting. Clients must warn before using it with a non-loopback host. Blob contents are E2E-encrypted either way, but the bearer credential (§3) would travel in cleartext.
- The key sits in the URL fragment so it never appears in HTTP requests or server logs, even if the link is pasted into a browser.
- The Pairing Link never contains the Enrollment Token. The token is needed only once, to create the group.
- Clients show the link as copyable text and, where the platform supports it, a QR code. The link is the recovery key, so the UI must tell the user to store it somewhere safe.

## 3. Key derivation

All derivations use HKDF-SHA256 with `salt = "codexbar-sync/v1"` (UTF-8) and `ikm = root-key`.

| Output | `info` | Length | Use |
|---|---|---|---|
| `group-id` | `"group-id"` | 16 bytes | Sync Group identifier, sent to the server as base64url (22 chars). |
| `auth-key` | `"auth"` | 32 bytes | Bearer credential. The server stores only `SHA-256(auth-key)`. |
| `enc-key` | `"enc"` | 32 bytes | ChaCha20-Poly1305 key for blobs. Never leaves the Machine. |

Deriving the group ID from the key keeps the Pairing Link short and ensures a link can't point at the wrong group.

## 4. Machine ID

- 16 random bytes, base64url (22 chars), generated when the Machine first pairs.
- Stored once per OS user per computer, in config that the app and the CLI both read, so the two never push as different Machines.
- Only one process pushes at a time on a Machine. Pushers take an exclusive, non-blocking lock file next to the config and skip the cycle if the lock is already held.
- The reserved ID `group` names blobs that belong to the Sync Group rather than to a Machine (§5.3). It never counts as a Machine.

## 5. Blobs

The server stores opaque blobs addressed by `(group-id, machine-id, name)`.

### 5.1 Envelope

```
byte 0        version (0x01)
bytes 1..12   nonce (12 random bytes)
bytes 13..    ChaCha20-Poly1305 ciphertext || 16-byte tag
```

- Associated data: UTF-8 `"codexbar-sync/v1|<group-id>|<machine-id>|<name>"`. This binds each blob to its address, so a server can't swap blobs between Machines, days, or groups without decryption failing.
- Plaintext: UTF-8 JSON, zero-padded to the next multiple of 1024 bytes before encryption to blur exact model and hour counts. Readers strip trailing `0x00` bytes before parsing.
- Maximum envelope size: 64 KiB.

### 5.2 Machine blobs

**`profile`**: one per Machine, rewritten on every push.

```json
{
  "v": 1,
  "displayName": "laptop",
  "platform": "linux",
  "clientVersion": "0.24.0",
  "coverageStart": "2026-06-25",
  "pushedAt": "2026-09-23T14:05:12Z"
}
```

- `displayName` defaults to the hostname and the user can edit it.
- `coverageStart` is the UTC date of the oldest day blob this Machine has uploaded. Readers show Coverage from `coverageStart` to Last Seen.

**`day-YYYY-MM-DD`** (UTC date): one per Machine per UTC day that has Spend.

```json
{
  "v": 1,
  "buckets": [
    {
      "hour": 14,
      "provider": "claude",
      "model": "claude-sonnet-5",
      "costUSD": 1.84,
      "inputTokens": 12040,
      "outputTokens": 3310,
      "cacheReadTokens": 402113,
      "cacheCreationTokens": 18220,
      "totalTokens": 435683,
      "requests": 41
    }
  ]
}
```

- A bucket is one Spend Bucket: one `(hour, provider, model)`. `hour` is 0–23 UTC.
- `provider` uses the CodexBar provider ID. Only providers whose cost comes from **local session logs** may appear (Codex, Claude, and Pi at the time of writing). Account Billing sources (Claude Admin API, OpenAI API usage, Bedrock, and similar) must never be written.
- Numeric fields are optional. Omit a field the log didn't report rather than writing `0`. `costUSD` is omitted when pricing for the model is unknown.
- The blob always holds the complete day for that Machine, and a newer write replaces the older one wholesale. Readers never merge two versions of the same blob.

### 5.3 Group blobs (`machine-id = group`)

**`retired`**: the set of Retired Machines.

```json
{ "v": 1, "machines": { "<machine-id>": { "retiredAt": "2026-09-01T10:00:00Z" } } }
```

- Retired Machines still count toward totals and stay out of the active list.
- Writers use read-modify-write with `If-Match` (§6.4) so two Machines retiring at once don't lose an update.
- If a retired Machine pushes again, readers show it as active again. Its local config holds the same ID, so re-pairing or unretiring restores it.

## 6. HTTP API

Base URL: from the Pairing Link, with `/v1` appended. Bodies are JSON unless stated otherwise. Timestamps are RFC 3339 UTC.

### 6.1 Authentication

- Every group-scoped request carries `Authorization: Bearer <base64url(auth-key)>`.
- The server compares `SHA-256(auth-key)` to the stored hash in constant time. On mismatch or an unknown group it returns `404 group_not_found`, so it never confirms whether a group exists.

### 6.2 `GET /v1/info`

Unauthenticated. Lets a client decide whether to ask the user for an Enrollment Token.

```json
{
  "protocols": [1],
  "enrollment": "required",
  "maxBlobBytes": 65536,
  "retentionDays": 400,
  "operator": "Example Sync"
}
```

`enrollment` is one of `none` (open server), `optional`, or `required`. `operator` is display text chosen by the server operator. Clients show it as-is and never interpret it.

### 6.3 `POST /v1/groups`

Creates a Sync Group. Headers: `Authorization: Enrollment <token>` when `enrollment` isn't `none`.

```json
{ "groupId": "<22 chars>", "authKeyHash": "<base64url SHA-256(auth-key)>" }
```

- `201` returns `{ "limits": Limits }`.
- `409 group_exists` if the group ID is already registered. Creating a group is idempotent for the same `authKeyHash`, which returns `200` with the limits.
- `402 enrollment_required`, `403 enrollment_invalid`, `403 enrollment_expired`.
- An Enrollment Token binds to exactly one group. Presenting it again for a different group returns `403 enrollment_used`.

`Limits`:

```json
{ "maxMachines": 10, "retentionDays": 400, "expiresAt": "2026-10-07T00:00:00Z" }
```

`expiresAt` is `null` when the group never expires (typical for self-hosting).

### 6.4 `PUT /v1/groups/{groupId}/machines/{machineId}/blobs/{name}`

Body: `application/octet-stream` envelope. Optional `If-Match: <etag>`.

- `200` returns `{ "etag": "...", "updatedAt": "..." }`. The server sets the Machine's Last Seen to its own receive time on every successful PUT from that Machine (not for `machine-id = group`).
- `412 precondition_failed` on an `If-Match` mismatch.
- `413 payload_too_large` above `maxBlobBytes`.
- `403 machine_limit` when the write would introduce a Machine beyond `maxMachines`. Retired Machines still count until they are deleted (§6.7).
- `403 enrollment_expired` once `expiresAt` has passed. After expiry, reads keep working for at least 30 days so users can export or move servers.
- `422 invalid_name`: names must match `^(profile|retired|day-\d{4}-\d{2}-\d{2})$`, and `retired` is allowed only under `machine-id = group`.

### 6.5 `GET /v1/groups/{groupId}/changes?since=<cursor>&limit=<n>`

Incremental read of everything that changed since `cursor`. Omitting `since` returns everything.

```json
{
  "limits": { "maxMachines": 10, "retentionDays": 400, "expiresAt": null },
  "machines": [
    { "machineId": "<id>", "lastSeen": "2026-09-23T14:05:12Z" }
  ],
  "blobs": [
    {
      "machineId": "<id>",
      "name": "day-2026-09-23",
      "etag": "...",
      "updatedAt": "2026-09-23T14:05:12Z",
      "body": "<base64 envelope>"
    }
  ],
  "cursor": "<opaque>",
  "hasMore": false
}
```

- `machines` always lists every Machine in the group, whatever the cursor.
- Clients keep the cursor and a decrypted local cache. A reader that fails to decrypt a blob skips it and reports a sync error. It never shows partial data from that blob.

### 6.6 `GET /v1/groups/{groupId}/machines/{machineId}/blobs/{name}`

Returns a single envelope with an `ETag` header. It's used for the `retired` read-modify-write cycle.

### 6.7 Deletion

- `DELETE /v1/groups/{groupId}/machines/{machineId}` removes a Machine and all its blobs ("forget this Machine"). This is separate from retiring, which keeps history.
- `DELETE /v1/groups/{groupId}` removes the group and everything in it. The Enrollment Token stays bound to the deleted group.

### 6.8 Errors and rate limits

Error body: `{ "error": { "code": "<snake_case>", "message": "<human text>" } }`. Codes used above plus `unauthorized`, `rate_limited` (`429` with `Retry-After`), and `unsupported_version` (`400`).

Clients display `message` only as a fallback. They map known codes to their own localized text.

## 7. Retention

- The server deletes `day-*` blobs whose date is older than `retentionDays` before the current UTC date. `profile` and `retired` are kept while the group exists.
- Clients never upload `day-*` blobs older than `retentionDays`.

## 8. Client behavior

### 8.1 Push (every ~150 s, ±20 s jitter)

1. Take the push lock (§4). Skip the cycle if it's held.
2. Scan local logs into Spend Buckets for the **current and previous UTC day**. Late log writes (long sessions, sleep) mean yesterday isn't final until today ends.
3. For each of those day blobs, and for `profile`, skip the PUT if the plaintext hash matches the last successful upload. Otherwise encrypt and PUT.
4. On `429` or a network error, back off exponentially (capped at 15 min). Resending is always safe, because each blob is complete and replaces the old copy.

The desktop app and GNOME extension call the same push routine on their refresh loop. Headless Machines run `codexbar sync push` from a timer (§9).

### 8.2 Backfill (once, on pairing)

Upload one `day-*` blob per UTC day that has Spend in the local scan window, oldest first, capped at `retentionDays`. Set `coverageStart` accordingly.

### 8.3 Read (desktop surfaces only)

1. Poll `changes` on the same cadence as push, but only while a Machines view is visible or its data is older than 5 minutes.
2. Group decrypted Spend Buckets into days using the user's **Reporting Day** (timezone and day boundary), not UTC.
3. A Machine is **active** while its Last Seen is under 5 minutes old (about two push intervals).
4. Show Coverage for each Machine. Never label a total "lifetime".

## 9. CLI surface

```
codexbar sync pair <pairing-link> [--name <display-name>]
codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>]
codexbar sync push
codexbar sync status [--json]
codexbar sync link              # print the Pairing Link (with a warning)
codexbar sync rename <display-name>
codexbar sync retire <machine-id-or-name>
codexbar sync forget <machine-id-or-name>
codexbar sync leave             # unpair this Machine; keeps its server data
codexbar sync install-timer     # systemd user timer (Linux) or launchd agent (macOS)
```

`create` generates the root key locally, derives the group ID and auth key, calls `POST /v1/groups`, backfills, and prints the Pairing Link.

## 10. What the Sync Server learns

A Sync Server, and anyone who compromises it, **can** see:

- group IDs, Machine IDs, and how many Machines a group has;
- blob names, which reveal **which UTC days** each Machine had Spend (required for retention);
- blob sizes (blurred by 1 KiB padding), write times, Last Seen, and client IP addresses;
- the Enrollment Token used to create each group, and so the link between a paying customer and a group ID.

It **cannot** see Spend amounts, tokens, providers, models, Machine names, or platforms.

Someone holding the Pairing Link can read and write all of the group's data. There is no per-Machine revocation in v1. If a link leaks, create a new group and re-pair each Machine.

## 11. Versioning

- The protocol version appears in the URL (`/v1`), the envelope version byte, and each plaintext `"v"` field.
- Readers ignore unknown JSON fields and skip blobs whose `"v"` they don't support.
- Breaking changes need a new URL version. Servers list supported versions in `GET /v1/info`.
