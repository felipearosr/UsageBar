# Plan 004: Stop repeated quota notifications and put the decision logic under test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat bcc721dfd..HEAD -- linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js linux/usagebar-gnome/tests linux/usagebar-gnome/README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Open PR #110 edits `extension.js`;
> if it has merged, re-locate the excerpts by content.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none (independent of plan 003; both touch `extension.js`
  in different regions — rebase carefully if run in parallel)
- **Category**: bug / tests
- **Planned at**: commit `bcc721dfd`, 2026-10-12

## Why this matters

Quota notifications ("Claude Weekly at 87%") are the extension's main alert.
They repeat in two situations:

1. After every screen lock/unlock. GNOME disables and re-enables the
   extension on lock (metadata.json has no `session-modes`), and `enable()`
   creates a fresh `_notified` memo, so the first poll after unlock
   re-announces every threshold already crossed in the current window.
2. After any transient provider error. `mergeStale` marks the row stale,
   `_maybeNotify` skips stale rows and then replaces the memo with only the
   rows it visited, so the stale row's cycle keys are dropped. When the
   provider recovers, the same threshold fires again.

Nothing tests this logic: it lives inside the `UsageBarExtension` class in
`extension.js`, which imports `gi://*` at module top and therefore cannot be
loaded by Node. After this plan the decision logic lives in a gi-free
`notify.js` with tests, the memo survives disable/enable and provider
outages, and the small pure window helpers it needs live in a gi-free
`payload.js` (also fixing a bug where tertiary windows never get a pace
line because `paceOf` only indexes two slots).

## Current state

Files:

- `linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` — the
  extension. Relevant pieces:
  - `_maybeNotify` (lines 2475–2521) and `_notify` (2456–2462).
  - It is called from the `/usage` success path in `_fetchUsage`
    (line ~2444: `this._maybeNotify();`).
  - `enable()` line 1733: `this._notified = new Map();`
  - `disable()` line ~2066: `this._notified = null;`
  - Pure helpers used by `_maybeNotify`: `paceOf` (106–108), `resetSecs`
    (111–116), `windowsOf` (118–125), `extraWindowsOf` (132–134),
    `isLongWindow` (396–400), `windowLabel` (402–416). `resetText` (503–518)
    is NOT pure (uses the `T` string table and `DISPLAY`) and stays where it is.
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/machinesync.js` and
  `renderstate.js` — existing gi-free modules; `tests/machinesync.test.mjs`
  is the structural pattern for new tests (`node:test`,
  `node:assert/strict`, a fixed `NOW`, small payload builders).
- `schemas/org.gnome.shell.extensions.usagebar.gschema.xml` — the notify
  keys: `notify-enabled` (b, true), `notify-session-thresholds` (ai, [80, 95]),
  `notify-weekly-thresholds` (ai, [80, 95]), `notify-pace-enabled` (b, false),
  `notify-sound` (b), `notify-muted-providers` (as, []). Do not add keys.

`_maybeNotify` as it exists today (`extension.js:2475-2521`):

```js
    _maybeNotify() {
        if (!this._settings.get_boolean('notify-enabled'))
            return;
        const muted = new Set(this._settings.get_strv('notify-muted-providers'));
        const sessionAt = this._settings.get_value('notify-session-thresholds').deepUnpack();
        const weeklyAt = this._settings.get_value('notify-weekly-thresholds').deepUnpack();
        const paceEnabled = this._settings.get_boolean('notify-pace-enabled');
        const seen = new Map();
        for (const row of this._rows) {
            if (row.stale || muted.has(row.provider))
                continue;
            const name = this._displayName(row.provider);
            const wins = [
                ...windowsOf(row).map(({w, slot}) =>
                    ({w, label: windowLabel(w.windowMinutes, slot),
                        pace: paceOf(row, slot)})),
                ...extraWindowsOf(row)
                    .filter(x => x.window.usedPercent !== null &&
                        x.window.usedPercent !== undefined)
                    .map(x => ({w: x.window, label: x.title ?? x.id, pace: null})),
            ];
            for (const {w, label, pace} of wins) {
                const cycle = `${row.provider}:${label}:${w.resetsAt ?? ''}`;
                const crossed = (isLongWindow(w) ? weeklyAt : sessionAt)
                    .filter(t => w.usedPercent >= t);
                const prev = this._notified.get(cycle);
                seen.set(cycle, prev);
                if (crossed.length) {
                    const highest = Math.max(...crossed);
                    if (prev === undefined || highest > prev) {
                        this._notify(`${name} ${label} at ${Math.round(w.usedPercent)}%`,
                            resetText(w) || 'usage limit approaching');
                        seen.set(cycle, highest);
                    }
                }
                const paceKey = `${cycle}:pace`;
                const pacePrev = this._notified.get(paceKey);
                seen.set(paceKey, pacePrev);
                if (paceEnabled && pace?.willLastToReset === false && !pacePrev) {
                    this._notify(`${name} ${label} won't last to reset`,
                        pace.summary ?? 'current pace exceeds the window');
                    seen.set(paceKey, true);
                }
            }
        }
        this._notified = seen;
    }
```

The pure helpers (`extension.js:106-134`, `396-416`):

```js
function paceOf(row, slot) {
    return row.pace ? [row.pace.primary, row.pace.secondary][slot] : null;
}

function resetSecs(w) {
    if (!w?.resetsAt)
        return null;
    const at = Date.parse(w.resetsAt);
    return Number.isNaN(at) ? null : (at - Date.now()) / 1000;
}

function windowsOf(row) {
    const u = row.usage;
    if (!u)
        return [];
    return [u.primary, u.secondary, u.tertiary]
        .map((w, slot) => ({w, slot}))
        .filter(({w}) => w && !w.isSyntheticPlaceholder && w.usedPercent !== null &&
                w.usedPercent !== undefined);
}

function extraWindowsOf(row) {
    return (row.usage?.extraRateWindows ?? []).filter(x => x?.window);
}

function isLongWindow(w) {
    if (w.windowMinutes !== null && w.windowMinutes !== undefined)
        return w.windowMinutes >= 1440;
    return (resetSecs(w) ?? 0) > 86400;
}

function windowLabel(minutes, slot) { … pure ladder, see file … }
```

The CLI's pace payload has three slots (`Sources/CodexBarCLI/CLIPayloads.swift:136`
declares `tertiary: PacePayload?`), so `paceOf`'s two-element array is a bug.

Conventions: GJS ES modules, 4-space indent, single quotes, semicolons,
`_private` names. New pure modules import nothing from `gi://`. The EGO zip
tool (`tools/ego-zip.py`) auto-discovers `from './x.js'` imports.
Vocabulary from `CONTEXT.md`: these alerts are about **Quota** (rate windows
reported by the provider), not Spend; keep that word in comments.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Unit tests | `node --test linux/usagebar-gnome/tests/*.test.mjs` | `# fail 0` |
| Syntax | `for f in linux/usagebar-gnome/usagebar@felipearosr.github.io/*.js; do node --input-type=module --check < "$f" \|\| echo FAIL $f; done` | no `FAIL` |
| EGO zip | `python3 linux/usagebar-gnome/tools/ego-zip.py build --out "$(mktemp -d)"` | exit 0; lists `notify.js` and `payload.js` |
| EGO tests | `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'` | `OK` |
| ESLint | `npx --yes eslint@9 --config linux/usagebar-gnome/eslint.config.mjs linux/usagebar-gnome/usagebar@felipearosr.github.io` | no `no-undef` / `no-unused-vars` warnings |
| Headless smoke | `CODEXBAR_BIN=linux/usagebar-gnome/tests/stub-codexbar make test-linux-ui` | `PASS`, no `JS ERROR` |
| Dev kit | as in plan 003 Step 5 | no `JS ERROR` in `/tmp/codexbar-devkit.log` |
| Fork delta | `git fetch upstream main && linux/upstream/fork-delta.sh` | ends with `OK:` |

## Scope

**In scope**:
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js`
  (remove the moved helpers, import them, replace `_maybeNotify`'s body,
  change the memo lifecycle in `enable()`/`disable()`)
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/payload.js` (create)
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/notify.js` (create)
- `linux/usagebar-gnome/tests/payload.test.mjs` (create)
- `linux/usagebar-gnome/tests/notify.test.mjs` (create)
- `linux/usagebar-gnome/README.md` (two "Files" bullets)

**Out of scope** (do NOT touch):
- `resetText`, `humanizeSecs`, the `STRINGS`/`T` table, `DISPLAY`,
  `THRESHOLDS`, `severity` — they depend on module-level state; moving them
  is a separate refactor.
- `mergeStale`, `enrichAntigravityModels`, `_fetchUsage`'s control flow.
- The GSettings schema (no new keys).
- `prefs.js` (the notification settings UI is unchanged).

## Git workflow

- Branch: `felipearosr/gnome-notify-module` from `main`.
- Commit per step; style: short imperative, e.g.
  `Keep quota notification memory across stale rows and re-enable`.
- Do NOT push or open a PR unless the operator instructed it. `gh` calls
  always use `-R felipearosr/UsageBar`.

## Steps

### Step 1: Create `payload.js` with the pure window helpers

Move `paceOf`, `resetSecs`, `windowsOf`, `extraWindowsOf`, `isLongWindow`,
`windowLabel` from `extension.js` into
`usagebar@felipearosr.github.io/payload.js` as named exports, with these
changes only:

- `resetSecs(w, now = Date.now())` and `isLongWindow(w, now = Date.now())`
  take `now` (ms) so tests are deterministic.
- `paceOf(row, slot)` returns
  `row.pace ? [row.pace.primary, row.pace.secondary, row.pace.tertiary][slot] ?? null : null`.

In `extension.js` delete the moved functions and add
`import {extraWindowsOf, isLongWindow, paceOf, resetSecs, windowLabel, windowsOf} from './payload.js';`
Every existing call site keeps working (the `now` parameters default).

**Verify**: syntax loop → no `FAIL`;
`grep -c '^function \(paceOf\|resetSecs\|windowsOf\|extraWindowsOf\|isLongWindow\|windowLabel\)(' linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` → `0`.

### Step 2: Create `notify.js` with the decision logic

Export:

```js
// Quota notification planner (pure). Cycle identity is
// provider:label:resetsAt; a new resetsAt re-arms. memo: Map<cycleKey, number|true>.
export function planNotifications({rows, memo, sessionThresholds, weeklyThresholds,
    paceEnabled, muted, now, displayName})
    // → {notifications: [{kind: 'threshold'|'pace', provider, name, label, w, percent, pace}],
    //    memo: Map}
```

Rules (each is a test case in Step 3):
1. Rows that are `stale` or whose provider is in `muted` are not announced,
   but every memo entry whose key starts with `${row.provider}:` is COPIED
   into the new memo unchanged (this is the fix for repeats after outages).
2. For visited rows, behave exactly like today's loop: threshold entries
   store the highest crossed threshold, pace entries store `true`, a higher
   crossing announces again, a new `resetsAt` (new key) starts over.
3. Expired cycles are pruned: drop any carried-over key whose embedded
   `resetsAt` parses to a time more than 1 hour before `now` (keys with an
   empty `resetsAt` are kept only while their row is present, as today).
4. `displayName(provider)` is injected; `notifications[].name` is its result.
5. The function never calls `Main.notify`; the extension formats bodies.

In `extension.js`, `_maybeNotify` becomes: read the six settings as today,
call `planNotifications({rows: this._rows, memo: this._notified, …, now: Date.now(), displayName: p => this._displayName(p)})`,
then for each notification call `this._notify(...)` with the same titles
and bodies as today (`resetText(w) || 'usage limit approaching'` and
`pace.summary ?? 'current pace exceeds the window'`), and assign
`this._notified = result.memo`.

Memo lifecycle (fix for lock/unlock repeats):
- `enable()` line 1733: `this._notified ??= new Map();` (keep the memo if
  this extension object was enabled before in the same Shell session).
- `disable()`: remove the `this._notified = null;` line. Add a comment
  that the memo is a plain Map of strings and numbers (no actors, no
  signals, no sources), kept on purpose so re-enabling after a screen lock
  does not re-announce the current cycle; it is pruned by `planNotifications`.

**Verify**: syntax loop → no `FAIL`; `grep -n '_notified' …/extension.js`
shows the `??=` in `enable()` and no assignment in `disable()`.

### Step 3: Tests

`tests/payload.test.mjs` (pattern: `tests/machinesync.test.mjs`):
- `windowsOf` filters placeholders and null percents and keeps slot indexes.
- `extraWindowsOf` drops entries without `window`.
- `paceOf` returns the tertiary pace for slot 2 and `null` for a missing slot.
- `isLongWindow` uses `windowMinutes` when present, else the reset horizon
  against the injected `now`.
- `windowLabel` ladder: minutes null → Session/Weekly/Monthly by slot;
  40000 → Monthly; 9000 → Weekly; 2880 → `2-day`; slot 0 + 300 → `Session (5h)`;
  90 → `2h`; 30 → `30m`.

`tests/notify.test.mjs`:
- Crossing 80 announces once; the same payload again announces nothing.
- Rising to 95 announces again; memo stores 95.
- A new `resetsAt` re-arms (announces 80 again under the new key).
- Stale carry-through: fresh (announced) → stale → fresh with the same
  `resetsAt` and percent → no second notification.
- Muted provider: no notification, memo carried.
- Pace: with `paceEnabled`, `willLastToReset === false` announces once per
  cycle; disabled → never.
- Weekly vs session thresholds chosen by `isLongWindow`.
- Pruning: a memo key with a `resetsAt` 2 h before `now` and no matching
  row is dropped; one 10 min before `now` is kept.
- Re-enable simulation: calling the planner twice with the returned memo
  (as `enable()` would reuse it) announces nothing the second time.

**Verify**: `node --test linux/usagebar-gnome/tests/*.test.mjs` → `# fail 0`,
at least 16 new passing tests.

### Step 4: README, zip, smoke, dev kit

Add two bullets to the "Files" list in `linux/usagebar-gnome/README.md`
(`payload.js`: pure `/usage` row and window helpers; `notify.js`: quota
notification planner, memo survives disable/enable and stale rows; both
tested under `tests/`).

**Verify**: EGO zip build lists `notify.js` and `payload.js`; Python tests
`OK`; headless smoke `PASS` with the stub CLI; dev kit log (plan 003 Step 5
procedure, with the shared lock and the stub CLI) has no `JS ERROR`. The
stub's fixture rows are above 80 %, so the dev kit should show one
notification per window on first load and none on later polls.

### Step 5: Fork delta

**Verify**: `git fetch upstream main && linux/upstream/fork-delta.sh` → `OK:`;
`git status --porcelain` lists only in-scope files.

## Test plan

See Step 3. Pattern file: `linux/usagebar-gnome/tests/machinesync.test.mjs`.
Verification: `node --test linux/usagebar-gnome/tests/*.test.mjs` → `# fail 0`.

## Done criteria

- [ ] `node --test …` → `# fail 0`, `# pass` ≥ 113 (97 + ≥ 16)
- [ ] Syntax loop prints no `FAIL`; ESLint shows no `no-undef`/`no-unused-vars`
- [ ] `grep -c 'planNotifications' …/extension.js` → `2` (import + call)
- [ ] `grep -n '_notified = null' …/extension.js` → no match
- [ ] `grep -n '_notified ??= new Map' …/extension.js` → one match
- [ ] EGO zip lists `notify.js` and `payload.js`; `python3 -m unittest …` → `OK`
- [ ] Headless smoke `PASS`; dev kit log has no `JS ERROR`
- [ ] `linux/upstream/fork-delta.sh` ends with `OK:`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `_maybeNotify` or the helpers no longer match the excerpts and you cannot
  find them by name.
- A test needs `gi://` stubs — the module is not pure; fix the module.
- The `ego-zip.py` lint flags `notify.js`/`payload.js` for anything other
  than being new files (for example import-time work).
- Keeping the memo across `disable()` is challenged by a reviewer as an
  EGO rule violation: report the objection with the EGO guideline text
  rather than switching to GSettings persistence on your own.

## Maintenance notes

- Future notification kinds (for example a Spend budget, see
  `plans/README.md` direction notes) should add a memo key suffix like
  `:pace` and a test, not a second memo.
- Reviewer focus: the carried-over memo entries for stale/muted rows must
  be copied by key prefix `${provider}:` and pruned by `resetsAt`, or the
  Map grows forever on a long-running session.
- Known, not fixed here: some providers derive `resetsAt` from relative
  text, so the timestamp can jitter by seconds between polls and create a
  new cycle key. If repeats are still seen for one provider, round
  `resetsAt` to the minute inside the key (in `notify.js` only).
- The remaining pure logic in `extension.js` (`compactWindowLabel`,
  `mergeStale`, status-feed parsing, `costOverview`) is still untestable;
  move it into `payload.js` / new modules following this plan's pattern.
