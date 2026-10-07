# Fork delta: where UsageBar changes go

UsageBar is a fork of [steipete/CodexBar](https://github.com/steipete/CodexBar). Every upstream release gets merged
in (see [RUNBOOK.md](RUNBOOK.md)), and every upstream file the fork edits is a file that can conflict in that merge.
The **fork delta report** keeps that set small and deliberate.

```sh
git remote add upstream https://github.com/steipete/CodexBar.git   # once
git fetch upstream main
linux/upstream/fork-delta.sh             # working tree vs its merge-base with upstream/main
linux/upstream/fork-delta.sh --verbose   # also list every fork-owned file
```

## The four groups

The report diffs the checkout against its merge-base with `upstream/main` (the upstream release last merged in) and
puts every changed path in one group:

| Group | What it is | Conflict risk |
| --- | --- | --- |
| `linux/` | The Linux port: GNOME extension, packaging, these scripts. | None: upstream has no `linux/`. |
| fork-owned | A file outside `linux/` that upstream doesn't have, such as `Sources/CodexBarCore/MachineSync/`, `CLISync*.swift`, the Linux test suites, `docs/adr/`, or `.github/workflows/usagebar-*.yml`. | None: upstream never touches it. |
| allowlisted hook | An upstream file the fork edits, listed in [`hook-allowlist.tsv`](hook-allowlist.tsv) with the fork feature it serves. | Yes. Each one is a known, named conflict point. |
| unlisted upstream edit | An upstream file the fork edits without an allowlist entry. | **The check fails.** |

It exits 1 on an unlisted upstream edit, and on a **stale** allowlist entry (one whose file the fork no longer edits),
so the allowlist shrinks as soon as an edit goes away. It exits 2 on a malformed allowlist or a missing `upstream`
ref.

## Where to put a change

1. **In `linux/`**, if it's Linux-only (extension, packaging, scripts).
2. **In a new file**, if it's Swift, docs or CI outside `linux/`. A new `Foo+UsageBar.swift`, a new test file or a new
   `usagebar-*.yml` workflow is fork-owned and never conflicts. Prefer extending an upstream type from a new file to
   editing the upstream file.
3. **As a hook**, only when upstream's code has to call into fork code: keep the edit in the upstream file to one
   line or one call, and put the logic in a fork-owned file.
4. **Upstream**, if the change is generic. Propose it to steipete/CodexBar (#62) and drop the fork copy once it lands.

## Adding a hook

Add one line to [`hook-allowlist.tsv`](hook-allowlist.tsv), in the PR that makes the edit:

```text
<upstream path><TAB><fork feature><TAB><note: what the edit is, which ticket can remove it>
```

- Columns are separated by a real tab. Lines starting with `#` are comments.
- The feature is one of the names already in the file (Machine Sync: sync command, Spend Buckets, OpenCode on Linux,
  Repo plumbing, ...) or a new one. The merge rehearsal shows it next to each conflicted file.
- Say in the PR description that it grows the fork delta, and why a fork-owned file wouldn't do.

When an isolation ticket (#53–#60) removes an edit, delete its line in the same PR; CI fails until you do.

## In CI

- [`usagebar-fork-delta.yml`](../../.github/workflows/usagebar-fork-delta.yml) runs on every PR and every push to
  `main`: ShellCheck on `linux/upstream/*.sh`, the self-tests (`test-fork-delta.sh`, `test-merge-rehearsal.sh`), then
  the report against `upstream/main`. It is fork-only: upstream has no copy of the workflow, so merging upstream
  never changes it.
- The [merge rehearsal](RUNBOOK.md#the-merge-rehearsal) runs the report after merging upstream with
  `--allow-stale`. Taking upstream's side of a conflict drops fork hooks, so stale entries are expected there; an
  unlisted edit still fails.
