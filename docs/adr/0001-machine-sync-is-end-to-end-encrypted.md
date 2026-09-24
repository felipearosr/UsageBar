# Machine Sync is end-to-end encrypted; the server never reads Spend

Machine Sync runs on a self-hosted server or on a paid hosted plan. Machines encrypt their Spend Buckets with a key the server never sees. The server only stores opaque blobs for each Machine, and every client downloads them and aggregates Spend locally. Spend by provider and model reveals how someone works, and the app's trust story rests on privacy-first local data. The hosted operator should be unable to read subscribers' data, not merely promise not to.

## Considered Options

- **Plaintext server with server-side aggregation.** This would allow web dashboards, alerts, and team views, but the hosted operator and any breach would expose every user's Spend.
- **E2E by default with an opt-in plaintext mode.** Rejected because it means two code paths and two trust models to maintain.

## Consequences

- Losing the sync key means losing synced history. Each Machine's local logs remain the source of truth, so a new key can be rebuilt from them.
- The server can't compute totals, send spend alerts, or render a dashboard. A future web view has to decrypt in the browser.
- Self-hosting reduces to running an authenticated blob store, which keeps the self-hosted and hosted servers identical.
