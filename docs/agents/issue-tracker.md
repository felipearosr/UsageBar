# Issue tracker

Issues live on GitHub at **felipearosr/UsageBar**. Always pass `-R felipearosr/UsageBar` to `gh`: this checkout's `upstream` remote is steipete/CodexBar, and a bare `gh issue`/`gh pr` can resolve there.

## Labels

- `spec`: a container spec (PRD). It is broken into tickets and never worked directly. Never also `ready-for-agent`.
- `ready-for-agent`: a ticket an AFK agent may claim.
- `ready-for-human` / `needs-human`: needs a person (accounts, payments, hosting).
- Area: `machine-sync`, `linux`, `server`, `payments`.

## Native relationships

GitHub has both relationships natively. Publish them in addition to the prose `## Parent` / `## Blocked by` sections, once every issue in the set exists.

- **Parent (sub-issues):** `gh api -X POST repos/felipearosr/UsageBar/issues/<parent>/sub_issues -F sub_issue_id=<child id>`.
- **Blocked by (issue dependencies):** `gh api -X POST repos/felipearosr/UsageBar/issues/<blocked>/dependencies/blocked_by -F issue_id=<blocker id>`.
- Both take the issue's REST **id** (`gh api repos/felipearosr/UsageBar/issues/<number> --jq .id`), not its number. Passing a number wires the wrong issue or fails.
- **Idempotent re-runs:** read first and skip existing links. `GET …/issues/<parent>/sub_issues` and `GET …/issues/<n>/dependencies/blocked_by` list the current numbers.
- **Removing a dropped edge:** `DELETE …/issues/<parent>/sub_issue -F sub_issue_id=<id>`, and `DELETE …/issues/<n>/dependencies/blocked_by/<blocker id>`.
- **Pull requests can't be blockers** (HTTP 422, "Target issue may only be an issue"). An edge on a PR stays prose-only in `## Blocked by`.
- **Verify** by re-reading: `GET …/issues/<n>/parent` and `…/dependencies/blocked_by` for every ticket.
