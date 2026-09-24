# CodexBar / UsageBar

Shows AI provider limits and spend on the desktop. Machine Sync adds a view of spend across all of a user's machines.

## Language

### Usage

**Quota**:
How much of a rate window an account has used, as reported by the provider API. It belongs to the account, so every machine sees the same value.
_Avoid_: Usage (ambiguous), limit

**Spend**:
Estimated cost, tokens, and requests calculated from the agent session logs on one machine. Every unit of spend belongs to exactly one machine.
_Avoid_: Usage (ambiguous), bill, cost (when you mean the synced concept)

**Account Billing**:
Cost reported by a provider's billing API (for example the Claude Admin API, OpenAI API usage, or Bedrock). It covers the whole account, like Quota, is never Spend, and never syncs.
_Avoid_: Spend, API spend

### Machine Sync

**Machine**:
One OS user on one computer that reports its own Spend, identified by a random ID created when it first pairs and shown under an editable display name. The app and the CLI on the same computer are the same Machine.
_Avoid_: Device, PC, host (host is kept for Tailscale peers in Remote Sessions)

**Retired Machine**:
A Machine the user has marked as gone, for example after a reinstall. Its Spend history stays in totals, but it no longer appears as active.
_Avoid_: Deleted machine, removed device

**Machine Sync**:
Sharing each Machine's Spend so any Machine can show the Spend of all of them, updated live while they run.
_Avoid_: Cloud sync, backup

**Sync Group**:
The set of one person's Machines that share a sync key and can see each other's Spend. A Machine belongs to at most one Sync Group.
_Avoid_: Account, team, workspace

**Pairing Link**:
A single secret string holding the server address, the Sync Group, and its key. Whoever holds it can join the Sync Group, and it doubles as the recovery key.
_Avoid_: Invite, token, password

**Sync Server**:
Any server, self-hosted or hosted, that stores a Sync Group's encrypted Spend Buckets without being able to read them.
_Avoid_: Cloud, backend, relay

**Enrollment Token**:
A credential a Sync Server issues that allows exactly one Sync Group to exist on it, with a cap on Machines and an expiry. The hosted plan uses it to limit the server to paying subscribers and people on a trial.
_Avoid_: License key, API key, subscription code

**Spend Bucket**:
One Machine's Spend for one provider and model within one UTC hour. It is the unit Machine Sync exchanges, and a newer copy of a bucket replaces the older one.
_Avoid_: Record, event, entry

**Last Seen**:
The most recent time a Machine pushed its Spend Buckets. A Machine counts as active while its Last Seen is recent.
_Avoid_: Heartbeat, online

**Coverage**:
The period a Machine's synced Spend actually spans, from its oldest Spend Bucket to its Last Seen. It is always shown as a date range and never called lifetime.
_Avoid_: Lifetime, all time, history

**Reporting Day**:
The user-configured timezone and day boundary used to group Spend Buckets into days for display.
_Avoid_: Local day (that one belongs to a single Machine's log scan)
