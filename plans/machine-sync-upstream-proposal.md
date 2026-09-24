# Proposal: optional, end-to-end-encrypted Machine Sync

Draft issue for steipete/CodexBar. `VISION.md` lists new features and changes to data storage and privacy under "Needs Sign-Off", so this asks for sign-off before any client code is written.

---

**Title:** Proposal: opt-in Machine Sync — see local-log spend across all your machines (E2E encrypted, any server)

### Problem

CodexBar's cost dashboard only knows about the machine it runs on, because it reads that machine's Codex / Claude / Pi session logs. Many people run agents on several machines at once (laptop, desktop, a devbox or VPS over SSH), and there's no way to see total spend or which machine it's going to.

### Proposal

An **opt-in** Machine Sync that shares each machine's *local-log* spend through a server that can't read it.

- **What syncs:** hourly UTC buckets of cost, tokens, and requests for each machine, provider, and model, taken only from local session logs. It never includes quota, provider billing APIs (Admin API, OpenAI API usage, Bedrock…), account identity, project names or paths, or raw log content.
- **Privacy:** end-to-end encrypted with ChaCha20-Poly1305 and HKDF from the existing `swift-crypto` dependency. The server stores opaque blobs and can't see amounts, providers, models, or machine names. The spec lists exactly what the server *can* see (group and machine IDs, active UTC days, timing, IPs).
- **Pairing:** no accounts. One machine creates a group locally and shows a Pairing Link (`codexbar-sync://host#key`), and other machines paste it. The link doubles as the recovery key.
- **Server-neutral:** the app names and promotes no server. The user enters a server URL, plus an Enrollment Token if that server requires one. The server is a separate open-source project built against a protocol spec kept in this repo, so upstream never has to operate or ship server code.
- **Headless machines:** `codexbar sync pair|push|status` plus an optional timer helper, so SSH boxes count too.
- **UI:** a separate Machines view. Existing cost cards keep meaning "this machine", so nothing changes for anyone who doesn't pair.

### Footprint in this repo

- `docs/machine-sync-protocol.md` (wire spec), `CONTEXT.md` (glossary), and `docs/adr/0001`–`0003`.
- A self-contained client module in `CodexBarCore` (keys, envelope, HTTP client, push, and read cache), plus a small seam into the cost scanner to produce hourly UTC buckets.
- `codexbar sync …` CLI subcommands.
- A Machines view, Linux GNOME first and macOS afterwards.
- No new package dependencies.

### Explicitly out of scope

Teams and shared groups, key rotation, server-side dashboards and alerts, and syncing quota or billing-API cost.

### Questions for the maintainer

1. Is an opt-in, E2E-encrypted sync feature acceptable in principle?
2. Should the protocol spec and client live upstream, with the server as a separate project, or would you rather keep this fork-only?
3. Any objection to the `codexbar sync` CLI namespace and a new `CodexBarCore` submodule?

Full design: `docs/machine-sync-protocol.md`, `CONTEXT.md`, and `docs/adr/`.
