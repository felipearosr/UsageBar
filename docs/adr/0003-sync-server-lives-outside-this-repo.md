# The Sync Server lives in its own repo; this repo owns the protocol

This repo contains only the Machine Sync client and the wire protocol spec (`docs/machine-sync-protocol.md`). The Sync Server is a separate open-source project. Upstream then reviews a client and a spec rather than taking on server code it would have to operate. The hosted plan can run on cheap serverless infrastructure, and anyone can build a compatible server from the spec.

## Considered Options

- **A `codexbar sync-server` subcommand in this repo** reusing the in-house HTTP server and SQLite. It needs no new dependencies, but it puts server maintenance on a menu bar app's upstream.
