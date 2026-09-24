# The Sync Server lives in its own repo; this repo owns the protocol

This repo contains only the Machine Sync client and the wire protocol spec (`docs/machine-sync-protocol.md`). The Sync Server is a separate open-source project. The app and the server then ship on their own schedules, the hosted plan can run on cheap serverless infrastructure, and anyone can build a compatible server from the spec.

## Considered Options

- **A `codexbar sync-server` subcommand in this repo** reusing the in-house HTTP server and SQLite. It needs no new dependencies, but it ties server releases to app releases and cannot run on serverless infrastructure.
