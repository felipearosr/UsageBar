# Plan 003: Make the `codexbar serve` supervisor restart, back off and shut down correctly

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
> mismatch, treat it as a STOP condition. Open PR #110 edits `extension.js`
> heavily; if it has merged, re-locate the excerpts by content, not line.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `bcc721dfd`, 2026-10-12

## Why this matters

The GNOME extension starts and supervises its own `codexbar serve` child.
Three bugs in that supervisor cause orphaned processes, restart storms and
unrecoverable states:

1. `restart()` (used when the user changes the refresh interval in Settings)
   kills the old child and starts a new one, but the old child's exit
   callback fires afterwards and clears the reference to the *new* child,
   reports "serve exited", and schedules yet another spawn on the same port.
   The second child is orphaned (never killed on disable) and the third one
   fails to bind and exits, which loops every 2 s.
2. The backoff is reset to 2 s inside `_spawn()`, so a child that dies at
   startup (bad CLI, port taken) restarts every 2 s forever instead of
   backing off to 30 s. The port is chosen once in `start()` and reused on
   every respawn, so if anything else takes it, serve never comes back.
3. `stop()` sends SIGKILL (`force_exit()`), which skips serve's own
   shutdown. Serve's provider CLI sessions (`codex app-server`, `claude`
   PTYs) run in their own process groups and get orphaned. GNOME disables
   the extension on every screen lock, so this happens several times a day.

After this plan the supervisor ignores stale exit callbacks, backs off
properly, picks a fresh port on each spawn, and terminates the child with
SIGTERM followed by a SIGKILL fallback. The supervisor logic moves to a
dependency-injected module so Node can test it.

## Current state

- `linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` —
  the whole extension (5567 lines). The supervisor is lines 1107–1203:

```js
function freePort() {
    const listener = Gio.SocketListener.new();
    const port = listener.add_any_inet_port(null);
    listener.close();
    return port;
}

class ServeSupervisor {
    constructor(binary, interval, onState) {
        this._binary = binary;
        this._interval = interval;
        this._onState = onState; // (portOrNull, statusMessage)
        this._enabled = false;
        this._proc = null;
        this._restartId = 0;
        this._backoff = 2;
        this.port = 0;
    }

    // Serve only reads --refresh-interval at startup — bounce the child to
    // apply a new one (the exit handler is inert while _enabled is false).
    restart(interval) {
        this._interval = interval;
        this.stop();
        this.start();
    }

    start() {
        this._enabled = true;
        try {
            this.port = freePort();
        } catch (e) {
            this._onState(null, `no free loopback port: ${e.message}`);
            return;
        }
        this._spawn();
    }

    _spawn() {
        try {
            this._proc = Gio.Subprocess.new(
                [
                    this._binary, 'serve',
                    '--port', String(this.port),
                    '--refresh-interval', String(this._interval),
                    '--request-timeout', String(REQUEST_TIMEOUT_SECS),
                ],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            this._proc = null;
            this._onState(null, `failed to start codexbar serve: ${e.message}`);
            this._scheduleRestart();
            return;
        }
        this._proc.wait_async(null, (proc, res) => {
            try {
                proc.wait_finish(res);
            } catch {
                // cancelled or reaped — nothing to do
            }
            this._proc = null;
            if (this._enabled) {
                this._onState(null, 'codexbar serve exited — restarting…');
                this._scheduleRestart();
            }
        });
        // Readiness is handled by the fetch retry loop, not a /health gate.
        this._backoff = 2;
        this._onState(this.port, '');
    }

    _scheduleRestart() {
        if (!this._enabled || this._restartId)
            return;
        this._restartId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._backoff, () => {
            this._restartId = 0;
            this._backoff = Math.min(this._backoff * 2, 30);
            if (this._enabled)
                this._spawn();
            return GLib.SOURCE_REMOVE;
        });
    }

    stop() {
        this._enabled = false;
        if (this._restartId) {
            GLib.source_remove(this._restartId);
            this._restartId = 0;
        }
        if (this._proc) {
            this._proc.force_exit();
            this._proc = null;
        }
    }
}
```

- The extension creates it in `_startCli` (`extension.js:2005-2015`):

```js
        this._supervisor = new ServeSupervisor(binary,
            this._settings.get_int('refresh-interval-secs'), (port, status) => {
                if (generation !== this._generation || !this._indicator)
                    return;
                if (status)
                    this._indicator.setStatus(status);
                if (port) {
                    // A restarted serve may be a different CLI: ask again.
                    this._resetSyncSupport();
                    this._scheduleFetch(2);
                }
            });
        this._supervisor.start();
```

- `restart()` is called from the settings handler (`extension.js:1842-1855`)
  after a 2 s debounce when `refresh-interval-secs` changes.
- `disable()` calls `this._supervisor?.stop(); this._supervisor = null;`
  (`extension.js:2062-2063`) and removes every other GLib source.
- `_get()` (`extension.js:2236-2243`) reads `this._supervisor?.port` for each
  request, so re-picking the port on respawn needs no other change.
- Precedent for dependency injection: `RenderScheduler` in `renderstate.js`
  receives the GLib scheduling functions from `enable()`
  (`extension.js:1774-1783`):

```js
        this._renderScheduler = new RenderScheduler(
            callback => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                callback();
                return GLib.SOURCE_REMOVE;
            }),
            sourceId => GLib.source_remove(sourceId),
            () => { … });
```

- `tests/renderstate.test.mjs` tests `RenderScheduler` with fake scheduling
  functions; use it as the structural pattern for the new tests. Tests use
  `node:test` + `node:assert/strict`, backticked or plain sentence names, no
  real timers.
- `tools/ego-zip.py` discovers statically imported local modules
  (`from './x.js'`) automatically, so a new module needs no allowlist edit.
  Its lint warns about discarded GLib source IDs; every `timeout_add` must
  be stored and removed.
- Serve handles SIGTERM/SIGINT with its own shutdown (upstream
  `Sources/CodexBarCLI/CLIServeCommand.swift`, `shutdownServeRuntime`); it
  exits with an error when the port bind fails (lines ~775–786 there).
- Offline stand-in CLI for runtime checks: `tests/stub-codexbar`
  (`CODEXBAR_BIN=linux/usagebar-gnome/tests/stub-codexbar`). It never touches
  real accounts.
- Style: GJS ES modules, 4-space indent, single quotes, semicolons,
  `_private` method names, explicit cleanup in `disable()`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Unit tests | `node --test linux/usagebar-gnome/tests/*.test.mjs` | `# fail 0` (97 today + the new ones) |
| Syntax | `for f in linux/usagebar-gnome/usagebar@felipearosr.github.io/*.js; do node --input-type=module --check < "$f" || echo FAIL $f; done` | no `FAIL` lines |
| EGO zip lint | `python3 linux/usagebar-gnome/tools/ego-zip.py build --out "$(mktemp -d)"` | exit 0; new module listed in the zip |
| EGO zip tests | `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'` | `OK` |
| ESLint (warning-only) | `npx --yes eslint@9 --config linux/usagebar-gnome/eslint.config.mjs linux/usagebar-gnome/usagebar@felipearosr.github.io` | no `no-undef` / `no-unused-vars` warnings (12 style warnings exist today) |
| Headless UI smoke | `CODEXBAR_BIN=linux/usagebar-gnome/tests/stub-codexbar make test-linux-ui` | `PASS`, no `JS ERROR` in the printed log path |
| Dev kit (required by AGENTS.md after any extension change) | see Step 5 | extension enabled, no JS errors in `/tmp/codexbar-devkit.log` |
| Fork delta | `git fetch upstream main && linux/upstream/fork-delta.sh` | ends with `OK:` |

## Scope

**In scope** (the only files you should modify):
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js`
  (only the supervisor region ~1107–1203 and the `_startCli` construction
  site; imports at the top)
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/servesupervisor.js` (create)
- `linux/usagebar-gnome/tests/servesupervisor.test.mjs` (create)
- `linux/usagebar-gnome/README.md` (one bullet in "Files")

**Out of scope** (do NOT touch):
- `_fetchUsage`, `_fetchJSON`, `_get`, the sync code, rendering — other plans.
- `linux/codexbar-tray/` (the Rust tray has the same SIGKILL problem; it is a
  separate change).
- `metadata.json` `session-modes` — keeping the extension alive on the lock
  screen is a product decision, not this plan.
- Any Swift file (`codexbar serve` itself).

## Git workflow

- Branch: `felipearosr/gnome-serve-supervisor` from `main`.
- Commit per step; style: short imperative, e.g.
  `Ignore stale exit callbacks in the serve supervisor`.
- Do NOT push or open a PR unless the operator instructed it. `gh` calls
  always use `-R felipearosr/UsageBar`.

## Steps

### Step 1: Move the supervisor to `servesupervisor.js` with injected dependencies

Create `linux/usagebar-gnome/usagebar@felipearosr.github.io/servesupervisor.js`
(gi-free: it must not import `gi://*`). Export `class ServeSupervisor` with
the constructor shape:

```js
export class ServeSupervisor {
    // deps: {
    //   pickPort: () => number,                       // may throw
    //   spawn: (argv) => proc,                        // may throw; proc has
    //                                                 //   wait(cb), terminate(), kill()
    //   addTimeout: (secs, cb) => id, removeTimeout: (id) => void,
    //   now: () => number (ms),
    // }
    constructor(binary, interval, onState, deps)
```

Behaviour (write the tests in Step 2 against this list):

- `start()`: set `_enabled`, call `_spawn()`.
- `_spawn()`: pick a NEW port via `deps.pickPort()` every time (report
  `onState(null, 'no free loopback port: …')` and schedule a restart on
  failure), spawn with the same argv as today, remember `spawnedAt = now()`,
  keep a local `const proc` and set `this._proc = proc`. In `proc.wait()`'s
  callback: `if (this._proc !== proc) return;` (stale callback), then clear
  `_proc`, remove a pending kill timer, and if `_enabled`, report
  `'codexbar serve exited — restarting…'` and `_scheduleRestart()`.
- Backoff: do NOT reset in `_spawn()`. In the exit callback, if the child
  lived at least `HEALTHY_SECS = 30` seconds, reset `_backoff = 2` before
  scheduling; otherwise leave it so `_scheduleRestart()` doubles it (cap 30).
- `_scheduleRestart()`: unchanged logic, but via `deps.addTimeout`.
- `stop()`: `_enabled = false`, remove the restart timer, then if a child
  exists: `proc.terminate()` (SIGTERM) and `this._killId = deps.addTimeout(KILL_GRACE_SECS = 3, () => { this._killId = 0; proc.kill(); })`.
  Keep `this._proc` pointing at the child until its exit callback runs
  (so the stale-callback guard still works after a `restart()`); the exit
  callback removes `_killId`. Document in a comment that this one timer may
  outlive `disable()` by up to 3 s on purpose, and is removed when the
  child exits.
- `restart(interval)`: unchanged (`stop()` then `start()`); it now works
  because the old child's callback sees `this._proc !== proc`.
- Expose `port` as today (the extension reads it).

In `extension.js`: delete the old `ServeSupervisor` class and `freePort`,
import the new one, and build the deps at the construction site:

```js
import {ServeSupervisor} from './servesupervisor.js';
…
        this._supervisor = new ServeSupervisor(binary,
            this._settings.get_int('refresh-interval-secs'), (port, status) => { …unchanged… }, {
                pickPort: () => {
                    const listener = Gio.SocketListener.new();
                    const port = listener.add_any_inet_port(null);
                    listener.close();
                    return port;
                },
                spawn: argv => {
                    const proc = Gio.Subprocess.new(argv,
                        Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
                    return {
                        wait: cb => proc.wait_async(null, (p, res) => {
                            try { p.wait_finish(res); } catch { /* reaped */ }
                            cb();
                        }),
                        terminate: () => proc.send_signal(15),
                        kill: () => proc.force_exit(),
                    };
                },
                addTimeout: (secs, cb) => GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, secs, () => {
                    cb();
                    return GLib.SOURCE_REMOVE;
                }),
                removeTimeout: id => GLib.source_remove(id),
                now: () => Date.now(),
            });
```

`REQUEST_TIMEOUT_SECS` is defined in `extension.js:62`; pass it in as part
of the argv builder or as a fifth constructor option — pick one and keep
the serve argv byte-identical to today (`serve --port N --refresh-interval N --request-timeout 120`).

**Verify**: syntax loop → no `FAIL`; `python3 …/ego-zip.py build --out "$(mktemp -d)"`
→ exit 0 and the output lists `servesupervisor.js`.

### Step 2: Write the Node tests

Create `linux/usagebar-gnome/tests/servesupervisor.test.mjs` with fake deps:
a `pickPort` that returns incrementing numbers, a `spawn` that records argv
and returns a controllable fake proc (`exit()` triggers the wait callback;
`terminated`/`killed` flags), fake timers that record `(secs, cb)` and let
the test fire them in order, and a controllable `now`.

Cases (one `test()` each):
1. `start` spawns once with the expected argv and reports the port.
2. `restart` after the old child exits late: start, restart (new port),
   then fire the OLD child's exit → no `onState` "exited" message, no extra
   spawn, `port` still the new one; fire the NEW child's exit → restart
   scheduled.
3. Crash loop backs off: child exits immediately three times → scheduled
   delays are 2, 4, 8 (cap at 30 after enough rounds).
4. Healthy child resets backoff: a child that exits after `now` advanced by
   31 s schedules the next restart at 2 s again.
5. Each spawn gets a fresh port (`pickPort` call count equals spawn count).
6. `stop` sends `terminate`, schedules a 3 s kill; firing the kill timer
   calls `kill`; the child exiting before the timer removes the timer
   (`removeTimeout` called with that id) and does not schedule a restart.
7. `pickPort` throwing reports `no free loopback port` and schedules a
   restart.

**Verify**: `node --test linux/usagebar-gnome/tests/*.test.mjs` → `# fail 0`,
`# pass` ≥ 104.

### Step 3: README bullet

Add to the "Files" list in `linux/usagebar-gnome/README.md`:
`servesupervisor.js — serve child supervisor (spawn, restart backoff, port
per spawn, SIGTERM then SIGKILL); pure, tested in tests/servesupervisor.test.mjs`.

**Verify**: `grep -c servesupervisor linux/usagebar-gnome/README.md` → 1 or more.

### Step 4: Headless smoke

**Verify**: `CODEXBAR_BIN=linux/usagebar-gnome/tests/stub-codexbar make test-linux-ui`
→ prints `PASS` and the result JSON has `"ok": true`; the printed GNOME log
contains no `JS ERROR`. (Needs this Linux host's GNOME Shell. Take the
shared lock first: `mkdir /tmp/usagebar-devkit.lock` — poll if it exists —
and `rmdir` it afterwards. The script repoints
`~/.local/share/gnome-shell/extensions/usagebar@felipearosr.github.io` at the
checkout; if you work in a worktree, point it back at the main checkout
when done.)

### Step 5: Dev kit check (AGENTS.md requirement)

Write a small script in your scratchpad that does, in order:
1. `OLD=$(pgrep -f '^gnome-shell --devkit')`; if set: `pkill -P $OLD; kill $OLD`.
2. `cd <repo>; CODEXBAR_BIN=$PWD/linux/usagebar-gnome/tests/stub-codexbar setsid nohup ./linux/run-dev.sh > /tmp/codexbar-devkit.log 2>&1 < /dev/null &`
3. Wait up to 40 s for `grep -q usagebar /tmp/codexbar-devkit.log`.
Run it with `bash <file>` in the background (an inline `pkill -f` pattern
matches its own shell and kills the job — see the memory note). Then:

**Verify**: `grep -E 'JS ERROR|TypeError' /tmp/codexbar-devkit.log` → no
output; `pgrep -fc 'stub-codexbar serve'` → `1` (exactly one serve child for
the dev kit; the user's real session may own another `codexbar serve`, so
count only the stub). Leave the dev kit running for the user. Never
`gnome-extensions enable/disable` against the real session, and kill only
serve processes you started.

Optional runtime check of the restart path: with the nested shell's bus
address from `/proc/<new shell PID>/environ`, run
`DCONF_PROFILE=/tmp/codexbar-dconf-profile DBUS_SESSION_BUS_ADDRESS=… gsettings set org.gnome.shell.extensions.usagebar refresh-interval-secs 120`,
wait 10 s, then `pgrep -fc 'stub-codexbar serve'` → still `1`.

### Step 6: Fork delta

**Verify**: `git fetch upstream main && linux/upstream/fork-delta.sh` → ends
with `OK:`; `git status --porcelain` lists only in-scope files.

## Test plan

- `tests/servesupervisor.test.mjs`: the 7 cases in Step 2 (pattern:
  `tests/renderstate.test.mjs`, which injects fake scheduling functions).
- Existing 97 tests keep passing.
- Runtime: headless smoke (Step 4) and dev kit (Step 5).

## Done criteria

- [ ] `node --test linux/usagebar-gnome/tests/*.test.mjs` → `# fail 0` with ≥ 7 new tests
- [ ] Syntax loop prints no `FAIL`
- [ ] `grep -c 'class ServeSupervisor' linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` → `0`
- [ ] `grep -c 'force_exit' linux/usagebar-gnome/usagebar@felipearosr.github.io/extension.js` → `2` (the `runAsync` cancel path at ~line 1218 and the new `kill` dep in `_startCli`; the supervisor's own call is gone)
- [ ] EGO zip builds and lists `servesupervisor.js`; `python3 -m unittest …` → `OK`
- [ ] Headless smoke `PASS`, no `JS ERROR`
- [ ] Dev kit log has no `JS ERROR`; one stub serve process
- [ ] `linux/upstream/fork-delta.sh` ends with `OK:`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The supervisor code no longer matches the excerpt (PR #110 may have moved
  it) and you cannot find an equivalent block by searching for
  `class ServeSupervisor`.
- Serve does not exit within 3 s of SIGTERM in the dev kit check (then the
  SIGKILL fallback fires; report it so the serve side can be looked at — do
  not lengthen the grace period beyond 5 s on your own).
- The headless smoke fails for reasons unrelated to the supervisor (for
  example missing `gnome-shell`); report which gates ran.
- Making the tests pass seems to require stubbing `gi://` modules under
  Node — that means the module isn't gi-free; fix the module, not the tests.

## Maintenance notes

- Any future call that spawns serve must go through the supervisor; the
  port is now per-spawn, so never cache `supervisor.port` across restarts.
- The kill timer is the only GLib source allowed to outlive `disable()`
  (≤ 3 s). Reviewers should check it is stored in `_killId` and removed in
  the exit callback.
- The Rust tray (`linux/codexbar-tray/src-tauri/src/serve.rs:52-57`) still
  uses SIGKILL; the same SIGTERM-then-SIGKILL change there is a follow-up.
- Deferred: a per-launch token between extension and serve so a foreign
  listener on the chosen port cannot spoof usage (needs a serve-side change
  in an upstream file).
