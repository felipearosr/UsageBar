# Plan 005: Fix the provider-metadata generator, regenerate `providermeta.js`, and add a drift check

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat bcc721dfd..HEAD -- linux/usagebar-gnome/tools/gen-provider-meta.py linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js linux/usagebar-gnome/tests .github/workflows/gnome-extension.yml .github/workflows/usagebar-merge-rehearsal.yml linux/usagebar-gnome/README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Authorized revision, 2026-10-13

The original metadata-loss STOP was valid. The user has now explicitly approved
keeping legacy entries for Crof, CrossModel and Kimi K2 (unofficial), preserving
their committed names, dashboard URLs and colors for older CLIs. Store this
small curated input in `LEGACY_META` in the fork-owned generator. Never read the
generated table as input. Current Swift descriptors take precedence if an ID
returns; test collisions and deterministic, independent generation.

The current target is 91 descriptor providers plus three legacy entries: 94
entries, all with brand colors. Thirteen descriptors use shorthand
`color: .init(hex: ...)`, including Manus and Poe; they do supply literal
colors. Parse explicit and shorthand constructors for hex and RGB, including
red-capable fixtures, and never substitute `widgetColor` for brand color.

Kimi's existing dashboard is source-backed by
`KimiRegion.china.consoleURL.absoluteString`. Resolve only the known
`domain` -> `webBaseURL` -> `consoleURL` chain from `KimiRegion.swift`, reflecting
literal domain/path changes and rejecting unsupported expression changes.
Add fixtures and real-descriptor invariants. Do not implement a general Swift
interpreter or edit Swift inputs. `Providers/**` must trigger the GNOME check
so changes to this backing source cannot silently leave stale metadata.

This revision expands the original steps and tests accordingly. The already
merged 003/004/006 changes are expected drift: preserve their extracted modules,
README updates, restore-only rehearsal cache and isolated trusted report job.
The loss STOP still applies outside the approved compatibility/resolver policy.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / dx
- **Planned at**: commit `bcc721dfd`, 2026-10-12

## Why this matters

The extension's provider names, brand colors, dashboard/status links and
status-strip feeds come from a generated table, `providermeta.js`, produced
by `tools/gen-provider-meta.py` from the upstream Swift provider
descriptors. The generator only understands the older `ProviderMetadata(…)`
descriptor form and the `ProviderColor(red:green:blue:)` color form. Upstream
now writes 41 of its 91 descriptors as `PluginProviderSpec(…)` with
`ProviderColor(hex: 0x…)`. The committed table has 59 providers; 32
providers that the CLI reports (for example `notion`, `pi`, `replicate`,
`coderabbit`, `zoommate`) get no links, no brand color and no status strip in
the popover. Running the documented regenerate command today would make
things worse: it would drop the 19 providers whose descriptors were
migrated upstream. Nothing in CI notices any of this after an upstream merge.

After this plan the generator parses both descriptor forms and both color
forms, the table covers every descriptor, and a `--check` mode runs in the
extension CI and in the upstream merge rehearsal so the table cannot drift
silently again.

## Current state

- `linux/usagebar-gnome/tools/gen-provider-meta.py` (156 lines) — the
  generator. Key functions (line numbers from the file today):
  - `metadata_block(src)` (60–73): finds `ProviderMetadata(` and returns the
    balanced-paren argument text.
  - `str_field(block, field)` (76–78): regex `\b<field>:\s*"…"`.
  - `color_field(src)` (81–93): parses ONLY
    `ProviderColor(red: …, green: …, blue: …)` anywhere in the file.
  - `parse(path)` (96–123): `id` from `\bid:\s*\.(\w+)` inside the block,
    `STR_FIELDS` mapping (`displayName→name`, `dashboardURL→dashboard`,
    `subscriptionDashboardURL→subscriptionDashboard`, `statusPageURL→statusPage`,
    `statusLinkURL→statusLink`), `statusFeed` derived from `statusPage` with
    `STATUS_FEED_OVERRIDES`, `statusScopes` from `STATUS_SCOPES`.
  - `main()` (126–152): globs `Sources/CodexBarCore/Providers/*/*ProviderDescriptor.swift`,
    warns `no ProviderMetadata in <path>` for files it can't parse, writes
    `OUT` and prints `<N> providers -> <relpath>`.
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js` —
  generated ESM: `export const PROVIDER_META = { "abacus": {"name": …, "dashboard": …, "color": "#38bdf8"}, … }`
  (59 entries, header comment says "GENERATED … do not edit").
- Consumers: `extension.js` (`PROVIDER_META[p]?.name/color/statusFeed/statusScopes`
  and `providerLinks()` at line 88 reading `dashboard`, `subscriptionDashboard`,
  `statusPage`, `statusLink`), `prefs.js`, `statusscopes.js`,
  `tests/brandtext.test.mjs` (imports the table).
- Upstream descriptor forms (read-only inputs; never edit them):
  - Classic: `Sources/CodexBarCore/Providers/Alibaba/AlibabaCodingPlanProviderDescriptor.swift:51`
    `metadata: ProviderMetadata(id: .alibaba, displayName: "Alibaba", …)`.
  - Plugin spec: `Sources/CodexBarCore/Providers/Chutes/ChutesProviderDescriptor.swift:5`:

```swift
    public static let spec = PluginProviderSpec(
        id: .chutes,
        displayName: "Chutes",
        …
        dashboardURL: "https://chutes.ai",
        color: ProviderColor(hex: 0x3184FF),
        confetti: [0x121212, 0xFFFFFF, 0x63D297],
        widgetColor: ProviderColor(hex: 0x18A058),
```

  - `Sources/CodexBarCore/Plugins/PluginProviderSpec.swift:26-43` declares the
    same field names the generator already maps: `id`, `displayName`,
    `dashboardURL`, `subscriptionDashboardURL`, `statusPageURL`,
    `statusLinkURL`, `color`.
  - Counts today: 91 descriptor files; 50 contain `ProviderMetadata(`, 41
    contain `PluginProviderSpec(`; `ProviderColor(hex:` appears 208 times,
    `ProviderColor(red:` 33 times across descriptors.
- CI: `.github/workflows/gnome-extension.yml` runs unit tests, syntax
  checks, `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'`,
  the EGO zip build, and ESLint (warning-only). The merge rehearsal
  (`.github/workflows/usagebar-merge-rehearsal.yml`, step "Generated files
  are current", lines ~103–107) runs upstream's `--check` regenerators via
  `"$MR" check "$OUT" "<name>" -- <command>`.
- Python test pattern: `linux/usagebar-gnome/tests/test_ego_zip.py` loads the
  tool with `importlib.util.spec_from_file_location` and uses `unittest`
  with `tempfile.TemporaryDirectory()`.
- Conventions: Python 3 stdlib only (no pip packages), 4-space indent;
  commit messages short imperative.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate | `python3 linux/usagebar-gnome/tools/gen-provider-meta.py` | `94 providers -> linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js`, no `warning:` lines |
| Drift check | `python3 linux/usagebar-gnome/tools/gen-provider-meta.py --check` | exit 0, prints `providermeta.js is current` |
| Python tests | `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'` | `OK` |
| Node tests | `node --test linux/usagebar-gnome/tests/*.test.mjs` | `# fail 0` |
| Syntax | `node --input-type=module --check < linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js` | exit 0 |
| EGO zip | `python3 linux/usagebar-gnome/tools/ego-zip.py build --out "$(mktemp -d)"` | exit 0 |
| Descriptor count | `ls Sources/CodexBarCore/Providers/*/*ProviderDescriptor.swift \| wc -l` | `91` (today) |
| Dev kit | as in plan 003 Step 5 | no `JS ERROR` |
| Fork delta | `git fetch upstream main && linux/upstream/fork-delta.sh` | ends with `OK:` |

## Scope

**In scope**:
- `linux/usagebar-gnome/tools/gen-provider-meta.py` (including explicit legacy data and Kimi resolver)
- `linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js` (regenerated only; never hand-edited)
- `linux/usagebar-gnome/tests/test_gen_provider_meta.py` (create)
- `.github/workflows/gnome-extension.yml` (one step)
- `.github/workflows/usagebar-merge-rehearsal.yml` (one line in "Generated files are current")
- `linux/usagebar-gnome/README.md` (document `--check`)

**Out of scope** (do NOT touch):
- Anything under `Sources/` (upstream; the fork-delta check fails on edits).
- `brandtext.js`, `extension.js`, `prefs.js`, `statusscopes.js` — consumers
  are unchanged; if a regenerated field breaks one of them, STOP.
- `STATUS_SCOPES` / `STATUS_FEED_OVERRIDES` content — curated by hand; keep.
- Publishing metadata from the CLI (`config providers --format json`) — a
  separate upstream proposal; this plan is the bridge until then.

## Git workflow

- Branch: `felipearosr/gnome-provider-meta` from `main`.
- Two commits: generator + tests + CI first, then the regenerated table
  (`Regenerate providermeta.js from the 0.73.0 descriptors`), so the table
  diff reviews on its own.
- Do NOT push or open a PR unless the operator instructed it. `gh` calls
  always use `-R felipearosr/UsageBar`.

## Steps

### Step 1: Parse both descriptor forms, explicit/shorthand colors and approved inputs

In `gen-provider-meta.py`:

1. Rename `metadata_block` to `spec_block` and make it find the first of
   `ProviderMetadata(` or `PluginProviderSpec(` (whichever occurs first in
   the file), returning the balanced argument text as today. Keep the old
   name as an alias if `test_ego_zip.py` or anything imports it
   (`grep -rn metadata_block linux/` → only this file today).
2. Color: first look INSIDE the block for a `color:` argument:
   - `(?<![A-Za-z])color:\s*ProviderColor\(\s*hex:\s*0x([0-9A-Fa-f]{6})\s*\)` → `#rrggbb` lowercase;
   - `(?<![A-Za-z])color:\s*ProviderColor\(\s*red:` → reuse the existing
     red/green/blue parser on that match.
   The negative lookbehind keeps `widgetColor:` from matching. If the block
   has no `color:`, fall back to today's whole-file search (classic
   descriptors keep their color elsewhere in the file), and extend that
   fallback to accept the `hex:` form too.
3. Update the module docstring (lines 2–17) and the `warning:` text in
   `main()` to say "no ProviderMetadata/PluginProviderSpec".

**Verify**: `python3 linux/usagebar-gnome/tools/gen-provider-meta.py` →
`94 providers -> …` and zero `warning:` lines. Then
`grep -c '^    "[a-z0-9]*": {' linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js`
→ `94`, and `grep -c '"color"' …/providermeta.js` → `94` (every provider has
a color; if fewer, list the ones without and STOP if any descriptor really
has a `ProviderColor(` the parser missed).

### Step 2: Add `--check`

Add an argument parser (`argparse`, stdlib): no args → write the file as
today; `--check` → render the output to a string, compare with the file's
current content, print `providermeta.js is current` and exit 0 when equal,
otherwise print `providermeta.js is stale; run: python3 linux/usagebar-gnome/tools/gen-provider-meta.py`
plus the first 20 lines of a unified diff (`difflib.unified_diff`) to
stderr and exit 1. Refactor `main()` so rendering is a function
`render(meta) -> str` and writing is separate.

**Verify**: `python3 …/gen-provider-meta.py --check` → exit 0 after Step 1's
regeneration; then `printf '\n' >> …/providermeta.js && python3 …/gen-provider-meta.py --check; echo $?`
→ `1` with the stale message, and `git checkout -- linux/usagebar-gnome/usagebar@felipearosr.github.io/providermeta.js`
restores it.

### Step 3: Python tests

Create `linux/usagebar-gnome/tests/test_gen_provider_meta.py` (load the
tool like `test_ego_zip.py` does). Write small Swift-like fixture strings
to a `TemporaryDirectory` and point the tool's `DESCRIPTOR_GLOB`/`OUT` at
it (make those module attributes overridable, e.g. `parse(path)` stays
pure and `main(argv, descriptor_glob=…, out=…)` takes parameters). Cases:

1. Classic `ProviderMetadata(` with `ProviderColor(red: 56 / 255, green: 189 / 255, blue: 248 / 255)` elsewhere in the file → `color` `#38bdf8`.
2. `PluginProviderSpec(` with `color: ProviderColor(hex: 0x3184FF)` AND a
   later `widgetColor: ProviderColor(hex: 0x18A058)` → `#3184ff`, not the widget color.
3. `statusPageURL: "https://status.openai.com"` → `statusFeed` uses the
   incident.io override; a different status page → `{"kind": "statuspage", "base": …}`.
4. A file with neither call → `parse` returns `None`.
5. `--check` returns 0 when the output file matches and 1 when it differs.

**Verify**: `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'`
→ `OK` with the original cases plus legacy, shorthand, Kimi and real-descriptor tests
(22 existing + 12 generator tests).

### Step 4: Wire the check into CI

- `.github/workflows/gnome-extension.yml`: add a step after "Syntax check":
  `- name: Provider metadata is current` /
  `run: python3 linux/usagebar-gnome/tools/gen-provider-meta.py --check`.
  Also add `Sources/CodexBarCore/Providers/**` and
  `Sources/CodexBarCore/Plugins/PluginProviderSpec.swift` to BOTH `paths:`
  lists so an upstream merge that changes descriptors triggers this
  workflow.
- `.github/workflows/usagebar-merge-rehearsal.yml`, step "Generated files
  are current": add
  `"$MR" check "$OUT" "Generated: GNOME provider meta" -- python3 linux/usagebar-gnome/tools/gen-provider-meta.py --check`.

**Verify**: both files still parse as YAML. PyYAML is not installed on the
dev box, so use the js-yaml CLI from the npx cache:
`npx --yes js-yaml@4.1.0 .github/workflows/gnome-extension.yml > /dev/null && npx --yes js-yaml@4.1.0 .github/workflows/usagebar-merge-rehearsal.yml > /dev/null`
→ exit 0 for both (it prints the parsed document; a parse error is non-zero).

### Step 5: README

In `linux/usagebar-gnome/README.md`, under "Tests", add the `--check`
command and a sentence that CI and the merge rehearsal run it, and that
the table must be regenerated (never hand-edited) after an upstream merge.

**Verify**: `grep -c 'gen-provider-meta.py --check' linux/usagebar-gnome/README.md` → `1`.

### Step 6: Consumers, zip, dev kit, fork delta

**Verify**:
- `node --test linux/usagebar-gnome/tests/*.test.mjs` → `# fail 0`
  (`brandtext.test.mjs` imports the table).
- `node --input-type=module --check < …/providermeta.js` → exit 0.
- `python3 linux/usagebar-gnome/tools/ego-zip.py build --out "$(mktemp -d)"` → exit 0.
- Dev kit with the stub CLI (plan 003 Step 5 procedure): no `JS ERROR`; the
  two stub providers render with names and colors.
- `git fetch upstream main && linux/upstream/fork-delta.sh` → `OK:`.
- `git status --porcelain` → only in-scope files.

## Test plan

- `tests/test_gen_provider_meta.py`: the five cases in Step 3, modelled on
  `tests/test_ego_zip.py`.
- Existing Node and Python suites keep passing.
- Verification: the two test commands above.

## Done criteria

- [ ] `python3 …/gen-provider-meta.py` prints the descriptor count plus absent legacy IDs (94 today) and no `warning:`
- [ ] `python3 …/gen-provider-meta.py --check` exits 0 on the committed table
- [ ] `grep -c '"color"' …/providermeta.js` equals the provider count
- [ ] `python3 -m unittest discover -s linux/usagebar-gnome/tests -p 'test_*.py'` → `OK`, ≥ 34 tests
- [ ] `node --test …` → `# fail 0`
- [ ] Both edited workflow files parse (`npx --yes js-yaml@4.1.0 <file>` exits 0)
- [ ] `linux/upstream/fork-delta.sh` ends with `OK:`
- [ ] `git status --porcelain` lists only in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The descriptor count or the two call forms differ from the counts above
  in a way the plan does not cover (a third descriptor style).
- After regeneration, outside the approved legacy/Kimi policy, a provider in the old table loses its
  `dashboard`/`statusPage`/`color` (compare with
  `git diff --stat` and a quick `python3 - <<EOF` that loads both tables):
  report the list instead of hand-editing the generated file.
- A consumer test fails on the new table (`brandtext.test.mjs` or the
  dev kit) — that means a field shape changed; report it.
- `--check` cannot be made deterministic (for example key order differs
  between runs) — fix with `sort_keys`/sorted globbing, and if that is not
  enough, report.

## Maintenance notes

- After every upstream merge, CI now fails until
  `python3 linux/usagebar-gnome/tools/gen-provider-meta.py` is re-run;
  add that line to `linux/upstream/RUNBOOK.md`'s merge checklist in the
  merge PR that first hits it.
- Reviewer focus: the regenerated table diff. Expect complete descriptor coverage plus the three approved legacy entries.
  Any other lost dashboard, status or color field still needs investigation.
- Long term, the upstream CLI could publish these fields from
  `config providers --format json` (three TODOs in the tree ask for it:
  `extension.js:80-83`, this generator's docstring,
  `linux/codexbar-tray/dist/app.js:10`). That proposal belongs under
  issue #62; this generator stays as the fallback for older CLIs.
