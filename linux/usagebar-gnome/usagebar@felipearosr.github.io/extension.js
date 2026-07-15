// UsageBar — GNOME Shell extension (Linux port of CodexBar).
//
// Panel chips (one per provider, worst-window percent) opening an anchored
// popover with a tab strip ("All" + one tab per provider, each with a mini
// usage bar) above the detail area: all cards stacked on the All tab, a
// single card per provider tab — rate-window progress bars, reset
// countdowns, pace, cost (Today / 30 days, top models), a statuspage-style
// incident-history strip and links.
//
// Self-contained backend: supervises `codexbar serve` on a free loopback
// port (like the Tauri tray in ../codexbar-tray) and polls GET /usage and
// GET /cost. Payload models mirror Sources/CodexBarCLI/CLIPayloads.swift and
// CLICostCommand.swift; see ../codexbar-tray/fixtures/ for captures.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Soup from 'gi://Soup';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const REFRESH_INTERVAL_SECS = 300; // serve's upstream cadence (Claude rate-limits pollers)
const REQUEST_TIMEOUT_SECS = 120;
const FETCH_OK_SECS = 55;          // cache hits between serve refreshes
const FETCH_RETRY_SECS = 10;       // serve starting up / transient failure
const TICK_SECS = 30;              // countdown re-render while the menu is open
const COST_TTL_SECS = 120;
const STATUS_TTL_SECS = 900;   // provider status pages refresh slowly
const STATUS_DAYS = 30;        // history strip length, like statuspage.io
const STATUS_BAR_HEIGHT = 14;
const BAR_WIDTH = 320;
const MINI_BAR_WIDTH = 26;
const KPI_COL_WIDTH = 180; // left column of the 2x2 cost grid
const CHART_HEIGHT = 44; // daily cost/token trend bars
const COST_HINTS = {
    codex: 'Estimated from local Codex logs for the selected account.',
    claude: 'Estimated from local logs · may differ from your bill',
};

// TODO(upstream): expose these in `codexbar config providers --format json`
// (they exist per-provider in CodexBarCore's ProviderDescriptors).
const URLS = {
    codex: {
        dashboard: 'https://chatgpt.com/codex/settings/usage',
        status: 'https://status.openai.com/',
        // status.openai.com aggregates ChatGPT/Sora/Ads incidents and its
        // statuspage-compat API strips component tags — to match the page's
        // per-component bars, pull the incident.io native feed and keep only
        // impact windows inside the scope chosen in Settings (a component
        // group name, default "Codex").
        statusFeed: {
            kind: 'incidentio',
            base: 'https://status.openai.com/proxy/status.openai.com',
        },
    },
    claude: {
        dashboard: 'https://claude.ai/settings/usage',
        status: 'https://status.claude.com/',
        // Scope here is a component name prefix, default "Claude Code".
        statusFeed: {kind: 'statuspage', base: 'https://status.claude.com'},
    },
};

// ---------- payload helpers (ported from codexbar-tray dist/app.js) ----------

function windowsOf(row) {
    const u = row.usage;
    if (!u)
        return [];
    return [u.primary, u.secondary, u.tertiary]
        .map((w, slot) => ({w, slot}))
        .filter(({w}) => w && !w.isSyntheticPlaceholder && w.usedPercent !== null &&
                w.usedPercent !== undefined);
}

// Named per-model/per-feature limits beyond the three standard slots
// (e.g. Claude's Fable weekly bar, "Daily Routines"). Only present from
// the oauth/web sources — the claude CLI source strips them, so the config
// must pin claude to source "oauth" on Linux.
function extraWindowsOf(row) {
    return (row.usage?.extraRateWindows ?? []).filter(x => x?.window);
}

function worstPercent(row) {
    const ps = windowsOf(row).map(({w}) => w.usedPercent);
    for (const x of extraWindowsOf(row)) {
        if (x.window.usedPercent !== null && x.window.usedPercent !== undefined)
            ps.push(x.window.usedPercent);
    }
    return ps.length ? Math.max(...ps) : null;
}

// Serve replaces a failing provider's row with a bare error row; carry the
// last good usage forward, marked stale (port of client.rs merge_stale).
function mergeStale(previous, fresh) {
    for (const row of fresh) {
        if (row.error && windowsOf(row).length === 0) {
            const prev = previous.find(p => p.provider === row.provider &&
                windowsOf(p).length > 0);
            if (prev) {
                row.usage = prev.usage;
                row.pace = prev.pace;
                row.stale = true;
            }
        }
    }
    return fresh;
}

// Mutable so enable() can overwrite from GSettings (prefs.js edits them).
const THRESHOLDS = {warn: 60, crit: 85};

function severity(percent, grey) {
    if (grey)
        return 'stale';
    if (percent > THRESHOLDS.crit)
        return 'crit';
    if (percent > THRESHOLDS.warn)
        return 'warn';
    return 'ok';
}

function windowLabel(minutes, slot) {
    if (minutes === null || minutes === undefined)
        return ['Session', 'Weekly', 'Monthly'][slot] ?? 'Window';
    if (minutes >= 40000)
        return 'Monthly';
    if (minutes >= 9000)
        return 'Weekly';
    if (minutes >= 1440)
        return `${Math.ceil(minutes / 1440)}-day`;
    if (slot === 0)
        return `Session (${Math.ceil(minutes / 60)}h)`;
    if (minutes >= 60)
        return `${Math.ceil(minutes / 60)}h`;
    return `${minutes}m`;
}

function humanizeSecs(secs) {
    const d = Math.floor(secs / 86400);
    const h = Math.floor((secs % 86400) / 3600);
    const m = Math.floor((secs % 3600) / 60);
    if (d > 0)
        return `${d}d ${h}h`;
    if (h > 0)
        return `${h}h ${m}m`;
    if (m > 0)
        return `${m}m`;
    return 'under 1m';
}

function agoText(secs) {
    if (secs < 10)
        return 'just now';
    if (secs < 90)
        return `${Math.floor(secs)}s ago`;
    if (secs < 3600)
        return `${Math.floor(secs / 60)}m ago`;
    return `${Math.floor(secs / 3600)}h ago`;
}

function resetText(w) {
    if (w.resetsAt) {
        const at = Date.parse(w.resetsAt);
        if (!Number.isNaN(at)) {
            const secs = (at - Date.now()) / 1000;
            return secs <= 0 ? 'resets now' : `resets in ${humanizeSecs(secs)}`;
        }
    }
    return w.resetDescription ? `resets ${w.resetDescription}` : '';
}

function fmtTokens(n) {
    if (n === null || n === undefined)
        return null;
    if (n >= 1e9)
        return `${(n / 1e9).toFixed(1)}B`;
    if (n >= 1e6)
        return `${(n / 1e6).toFixed(1)}M`;
    if (n >= 1e3)
        return `${(n / 1e3).toFixed(1)}K`;
    return String(n);
}

function fmtUSD(v) {
    return v === null || v === undefined
        ? null
        : `$${v.toLocaleString('en-US', {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
}

// Cost as a 2x2 label-over-value grid, like the macOS inline dashboard:
// Today | Last Nd Cost / Last Nd tokens | Latest tokens. Values the report
// doesn't carry render as "—", as on macOS (codex has no pricing, and a
// fresh install has no history yet).
function costKpis(report) {
    if (!report)
        return null;
    const today = new Date().toLocaleDateString('en-CA'); // local YYYY-MM-DD
    const daily = report.daily ?? [];
    // Dollar values arrive under the upstream key "totalCost".
    const entry = daily.find(d => d.date === today);
    const latest = daily.length ? daily[daily.length - 1] : null;
    const totals = report.totals ?? {};
    const days = report.historyDays ?? 30;
    const kpis = [
        {title: 'Today', value: fmtUSD(entry?.totalCost) ?? '—'},
        {title: `Last ${days} days Cost`, value: fmtUSD(report.last30DaysCostUSD ?? totals.totalCost) ?? '—'},
        {title: `Last ${days} days tokens`, value: fmtTokens(report.last30DaysTokens ?? totals.totalTokens) ?? '—'},
        {title: 'Latest tokens', value: fmtTokens(latest?.totalTokens) ?? '—'},
    ];
    return kpis;
}

// Daily trend values for the mini bar chart (port of the macOS inline
// dashboard): a continuous series of the last historyDays days ending
// today — days without usage are zero (1px stub) so the rightmost bar is
// always today. Dollars when the report is priced, tokens otherwise.
// Null when there is no history at all.
function chartPoints(report) {
    const daily = report?.daily ?? [];
    if (!daily.length)
        return null;
    const byDate = new Map(daily.map(d => [d.date, d]));
    const useCost = daily.some(d => typeof d.totalCost === 'number');
    const days = report.historyDays ?? 30;
    const now = new Date();
    const points = [];
    for (let i = days - 1; i >= 0; i--) {
        const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i)
            .toLocaleDateString('en-CA'); // local YYYY-MM-DD
        const entry = byDate.get(day);
        points.push({
            value: entry ? ((useCost ? entry.totalCost : entry.totalTokens) ?? 0) : 0,
            date: day,
            cost: entry?.totalCost ?? null,
            tokens: entry?.totalTokens ?? null,
        });
    }
    return points;
}

function chartTooltipText(point) {
    const day = new Date(`${point.date}T12:00:00`)
        .toLocaleDateString('en-US', {month: 'short', day: 'numeric'});
    const bits = [
        fmtUSD(point.cost),
        point.tokens !== null ? `${fmtTokens(point.tokens)} tokens` : null,
    ].filter(Boolean);
    return bits.length ? `${day} · ${bits.join(' · ')}` : `${day} · no usage`;
}

// ---------- provider status (public status-page incident feeds) ----------

// Both feeds normalize to impact intervals {rank, name, start, end,
// ongoing}: rank 1 → yellow, 2/3 → red (matching the usage-bar palette),
// plus `covered` — the feed is a bounded page, so when it looks truncated,
// days wholly before its oldest entry are unknown, not a clean green.
const IMPACT_SEV = ['ok', 'warn', 'crit', 'crit'];
const STATUSPAGE_IMPACT_RANK = {minor: 1, major: 2, critical: 3};
const INCIDENTIO_STATUS_RANK = {
    degraded_performance: 1,
    partial_outage: 2,
    full_outage: 3,
};

function feedCoverage(incidents, dateOf) {
    const starts = (incidents ?? []).map(dateOf).filter(t => !Number.isNaN(t));
    return (incidents ?? []).length >= 20 && starts.length
        ? Math.min(...starts) : 0;
}

// Classic Atlassian Statuspage /api/v2/incidents.json.
//
// 'Everything': one interval per incident, spanning its whole lifetime,
// ranked by page-level impact — the page's overall incident history.
//
// Component scope (name prefix, case-insensitive — 'Claude API' matches
// 'Claude API (api.anthropic.com)'): reconstruct that component's outage
// windows from the per-update status transitions, exactly what the page's
// per-component uptime bars show. Like those bars, degraded_performance
// does NOT color a day (an incident can sit at "degraded" for weeks —
// e.g. a model-access notice — while the page stays green); only
// partial_outage (yellow) and major_outage (red) count.
const STATUSPAGE_COMPONENT_RANK = {partial_outage: 2, major_outage: 3};

function statuspageIntervals(incidents, scope) {
    const now = Date.now();
    const covered = feedCoverage(incidents, inc => Date.parse(inc.created_at));
    if (!scope || scope === 'Everything') {
        return {
            covered,
            intervals: (incidents ?? [])
                .map(inc => ({
                    rank: STATUSPAGE_IMPACT_RANK[inc.impact] ?? 0,
                    name: inc.name ?? 'incident',
                    start: Date.parse(inc.started_at ?? inc.created_at),
                    end: inc.resolved_at ? Date.parse(inc.resolved_at) : now,
                    ongoing: !inc.resolved_at,
                }))
                .filter(inc => !Number.isNaN(inc.start) && inc.rank > 0),
        };
    }
    const lower = scope.toLowerCase();
    const intervals = [];
    for (const inc of incidents ?? []) {
        const updates = [...(inc.incident_updates ?? [])]
            .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
        let open = null; // {rank, start}
        for (const u of updates) {
            const ac = (u.affected_components ?? []).find(c =>
                (c.name ?? '').toLowerCase().startsWith(lower));
            if (!ac)
                continue;
            const t = Date.parse(u.created_at);
            if (Number.isNaN(t))
                continue;
            const rank = STATUSPAGE_COMPONENT_RANK[ac.new_status] ?? 0;
            if (open && rank !== open.rank) {
                intervals.push({...open, name: inc.name ?? 'incident',
                    end: t, ongoing: false});
                open = null;
            }
            if (rank && !open)
                open = {rank, start: t};
        }
        if (open) {
            // Never transitioned back in the feed: closed at resolution,
            // or genuinely still open.
            intervals.push({...open, name: inc.name ?? 'incident',
                end: inc.resolved_at ? Date.parse(inc.resolved_at) : now,
                ongoing: !inc.resolved_at});
        }
    }
    return {intervals, covered};
}

// Resolve an incident.io scope to component ids: the members of the
// structure group named like it, plus any component whose own name
// contains it (catches "Codex in ChatGPT Desktop" living in the ChatGPT
// group). 'Everything' — or a scope matching nothing — is all components.
function incidentIoScopeIds(summary, scope) {
    const all = (summary?.components ?? []).map(c => c.id);
    if (!scope || scope === 'Everything')
        return new Set(all);
    const lower = scope.toLowerCase();
    const ids = new Set();
    for (const item of summary?.structure?.items ?? []) {
        if ((item.group?.name ?? '').toLowerCase() === lower) {
            for (const c of item.group.components ?? [])
                ids.add(c.component_id);
        }
    }
    for (const c of summary?.components ?? []) {
        if ((c.name ?? '').toLowerCase().includes(lower))
            ids.add(c.id);
    }
    return ids.size ? ids : new Set(all);
}

// incident.io native feed (<base>/incidents): one interval per
// component_impact window on a matching component — the same data the
// page's per-component uptime bars are drawn from.
function incidentIoIntervals(incidents, componentIds) {
    const now = Date.now();
    const intervals = [];
    for (const inc of incidents ?? []) {
        for (const imp of inc.component_impacts ?? []) {
            if (!componentIds.has(imp.component_id))
                continue;
            const rank = INCIDENTIO_STATUS_RANK[imp.status] ?? 0;
            const start = Date.parse(imp.start_at);
            if (!rank || Number.isNaN(start))
                continue;
            intervals.push({
                rank,
                name: inc.name ?? 'incident',
                start,
                end: imp.end_at ? Date.parse(imp.end_at) : now,
                ongoing: !imp.end_at,
            });
        }
    }
    return {
        intervals,
        covered: feedCoverage(incidents, inc => Date.parse(inc.published_at)),
    };
}

// One entry per day, oldest first: worst impact overlapping that day.
// Days are UTC, not local: the status pages bucket their uptime bars by
// UTC day, and matching them bar-for-bar is the whole point (a 03:28 UTC
// outage must land on the same day here as there).
function statusDays(intervals, numDays, covered) {
    const now = new Date();
    const days = [];
    for (let i = numDays - 1; i >= 0; i--) {
        const dayStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(),
            now.getUTCDate() - i);
        const dayEnd = dayStart + 86400000;
        const hits = intervals.filter(iv => iv.start < dayEnd && iv.end >= dayStart);
        const worst = hits.reduce((m, iv) => Math.max(m, iv.rank), 0);
        days.push({
            date: new Date(dayStart).toLocaleDateString('en-US',
                {month: 'short', day: 'numeric', timeZone: 'UTC'}),
            sev: worst > 0 ? IMPACT_SEV[worst] : (dayEnd <= covered ? 'stale' : 'ok'),
            names: [...new Set(hits.filter(h => h.rank === worst).map(h => h.name))],
            count: new Set(hits.map(h => h.name)).size,
            ongoing: hits.some(h => h.ongoing),
        });
    }
    return days;
}

function statusTooltipText(day) {
    if (day.sev === 'stale')
        return `${day.date} · no incident data`;
    if (!day.count)
        return `${day.date} · operational`;
    let name = day.names[0] ?? 'incident';
    if (name.length > 48)
        name = `${name.slice(0, 47)}…`;
    const more = day.count > 1 ? ` (+${day.count - 1} more)` : '';
    return `${day.date} · ${name}${more}${day.ongoing ? ' · ongoing' : ''}`;
}

// Right-hand summary over the strip, from still-open impact intervals.
function currentStatus(intervals) {
    let worst = 0;
    for (const iv of intervals ?? []) {
        if (iv.ongoing)
            worst = Math.max(worst, iv.rank);
    }
    return [
        {text: 'Operational', sev: 'ok'},
        {text: 'Minor incident', sev: 'warn'},
        {text: 'Major incident', sev: 'crit'},
        {text: 'Critical incident', sev: 'crit'},
    ][worst];
}

// Codex limit-reset credits (usage.codexResetCredits, oauth source only):
// "N reset(s) available" + countdown to the nearest expiry. Null when the
// provider has none available.
function creditsInfo(row) {
    const rc = row.usage?.codexResetCredits;
    if (!rc)
        return null;
    const avail = (rc.credits ?? []).filter(c => c.status === 'available');
    const count = rc.availableCount ?? avail.length;
    if (!count)
        return null;
    const expiries = avail.map(c => Date.parse(c.expires_at)).filter(t => !Number.isNaN(t));
    let expiryLine = null;
    if (expiries.length) {
        const secs = (Math.min(...expiries) - Date.now()) / 1000;
        expiryLine = secs <= 0 ? 'Next expires now' : `Next expires in ${humanizeSecs(secs)}`;
    }
    return {
        text: count === 1 ? '1 reset available' : `${count} resets available`,
        expiryLine,
    };
}

// Top models by summed cost across the report's daily entries, e.g.
// "fable-5 $157.5 · opus-4-8 $77.6". Breakdown dollars arrive under the
// upstream key "cost" (unlike daily totals' "totalCost") and are absent for
// providers without pricing (codex) — return null and show nothing then.
function topModelsLine(report) {
    const byModel = new Map();
    for (const day of report?.daily ?? []) {
        for (const m of day.modelBreakdowns ?? []) {
            if (typeof m.cost !== 'number' || !m.modelName)
                continue;
            byModel.set(m.modelName, (byModel.get(m.modelName) ?? 0) + m.cost);
        }
    }
    const top = [...byModel.entries()].sort((a, b) => b[1] - a[1]).slice(0, 2);
    if (!top.length)
        return null;
    return top
        .map(([name, usd]) => `${name.replace(/^claude-/, '')} $${usd.toFixed(1)}`)
        .join(' · ');
}

// ---------- serve supervisor ----------

function findBinary() {
    const explicit = GLib.getenv('CODEXBAR_BIN');
    if (explicit && GLib.file_test(explicit, GLib.FileTest.IS_EXECUTABLE))
        return explicit;
    const inPath = GLib.find_program_in_path('codexbar');
    if (inPath)
        return inPath;
    for (const dir of [`${GLib.get_home_dir()}/.local/bin`,
        '/home/linuxbrew/.linuxbrew/bin', '/usr/local/bin']) {
        const p = `${dir}/codexbar`;
        if (GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE))
            return p;
    }
    return null;
}

function freePort() {
    const listener = Gio.SocketListener.new();
    const port = listener.add_any_inet_port(null);
    listener.close();
    return port;
}

class ServeSupervisor {
    constructor(binary, onState) {
        this._binary = binary;
        this._onState = onState; // (portOrNull, statusMessage)
        this._enabled = false;
        this._proc = null;
        this._restartId = 0;
        this._backoff = 2;
        this.port = 0;
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
                    '--refresh-interval', String(REFRESH_INTERVAL_SECS),
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

// ---------- indicator ----------

const Indicator = GObject.registerClass(
class UsageBarIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.5, 'UsageBar', false);

        this._chipBox = new St.BoxLayout({style_class: 'usagebar-panel-box'});
        this.add_child(this._chipBox);
        this._setPanelText([]);

        this.menu.box.add_style_class_name('usagebar-menu');

        // Header: title left, "updated Xs ago" right.
        const header = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        header.add_child(new St.Label({
            text: 'UsageBar',
            style_class: 'usagebar-title',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._updatedLabel = new St.Label({
            text: '',
            style_class: 'usagebar-dim',
            y_align: Clutter.ActorAlign.CENTER,
        });
        header.add_child(this._updatedLabel);
        this.menu.addMenuItem(header);

        // Status banner (serve problems, fetch errors).
        this._statusItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._statusLabel = new St.Label({style_class: 'usagebar-banner', x_expand: true});
        this._statusLabel.clutter_text.line_wrap = true;
        this._statusItem.add_child(this._statusLabel);
        this._statusItem.visible = false;
        this.menu.addMenuItem(this._statusItem);

        // Tab strip (one tab per provider) above a single detail card;
        // both rebuilt on every render.
        this._tabsItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._tabsBox = new St.BoxLayout({style_class: 'usagebar-tabs', x_expand: true});
        this._tabsItem.add_child(this._tabsBox);
        this._tabsItem.visible = false;
        this.menu.addMenuItem(this._tabsItem);

        const detailItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._detailBox = new St.BoxLayout({vertical: true, x_expand: true});
        detailItem.add_child(this._detailBox);
        this.menu.addMenuItem(detailItem);

        // Floating tooltip for chart-bar hover. Lives in the shell's UI
        // group so it can escape the menu; hidden with the menu and
        // destroyed with the indicator.
        this._tooltip = new St.Label({style_class: 'usagebar-tooltip', visible: false});
        Main.uiGroup.add_child(this._tooltip);
        this.menu.connect('open-state-changed', (_menu, open) => {
            if (!open)
                this._tooltip?.hide();
        });
        this.connect('destroy', () => {
            this._tooltip?.destroy();
            this._tooltip = null;
        });

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._settingsItem = new PopupMenu.PopupMenuItem('Settings');
        this.menu.addMenuItem(this._settingsItem);
        this._refreshItem = new PopupMenu.PopupMenuItem('Refresh now');
        this.menu.addMenuItem(this._refreshItem);
    }

    _setPanelText(chips) {
        this._chipBox.destroy_all_children();
        if (!chips.length) {
            this._chipBox.add_child(new St.Label({
                text: 'UB',
                style_class: 'usagebar-chip-label',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            return;
        }
        for (const chip of chips) {
            const box = new St.BoxLayout({style_class: 'usagebar-chip'});
            box.add_child(new St.Widget({
                style_class: `usagebar-dot usagebar-bg-${chip.sev}`,
                width: 8,
                height: 8,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            box.add_child(new St.Label({
                text: chip.text,
                style_class: 'usagebar-chip-label',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            this._chipBox.add_child(box);
        }
    }

    setStatus(message) {
        this._statusItem.visible = !!message;
        this._statusLabel.text = message ? `⚠ ${message}` : '';
    }

    setUpdated(text) {
        this._updatedLabel.text = text;
    }
});

// ---------- extension ----------

export default class UsageBarExtension extends Extension {
    enable() {
        this._rows = [];
        this._names = {};
        this._selectedProvider = null;
        this._notified = new Map();
        this._costs = null;
        this._costFetchedAt = 0;
        this._status = {};
        this._lastFetchAt = 0;
        this._fetchId = 0;
        this._tickId = 0;
        this._session = new Soup.Session({timeout: REQUEST_TIMEOUT_SECS + 10});
        this._cancellable = new Gio.Cancellable();

        this._settings = this.getSettings();
        const applyThresholds = () => {
            THRESHOLDS.warn = this._settings.get_int('warn-threshold');
            THRESHOLDS.crit = this._settings.get_int('crit-threshold');
        };
        applyThresholds();
        this._settingsChangedId = this._settings.connect('changed', (_s, key) => {
            applyThresholds();
            if (key.endsWith('-status-scope') && this._status) {
                this._status = {}; // drop the cache so the new scope refetches
                this._fetchStatus();
            }
            this._render();
        });

        this._indicator = new Indicator();
        this._indicator._settingsItem.connect('activate', () => this.openPreferences());
        this._indicator._refreshItem.connect('activate', () => this._fetchUsage());
        this._indicator.menu.connect('open-state-changed', (_menu, open) => {
            if (open) {
                this._selectedProvider = null; // default to the All tab each open
                this._fetchUsage();
                this._fetchCost();
                this._fetchStatus();
                this._render();
            }
        });
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        const binary = findBinary();
        if (!binary) {
            this._indicator.setStatus('codexbar CLI not found — install it from ' +
                'github.com/steipete/CodexBar releases or set $CODEXBAR_BIN');
            this._render();
            return;
        }
        this._loadDisplayNames(binary);

        this._supervisor = new ServeSupervisor(binary, (port, status) => {
            if (status)
                this._indicator.setStatus(status);
            if (port)
                this._scheduleFetch(2);
        });
        this._supervisor.start();

        // Countdown/"updated ago" ticker while the menu is open.
        this._tickId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TICK_SECS, () => {
            if (this._indicator?.menu.isOpen)
                this._render();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        if (this._settingsChangedId) {
            this._settings.disconnect(this._settingsChangedId);
            this._settingsChangedId = 0;
        }
        this._settings = null;
        if (this._fetchId) {
            GLib.source_remove(this._fetchId);
            this._fetchId = 0;
        }
        if (this._tickId) {
            GLib.source_remove(this._tickId);
            this._tickId = 0;
        }
        this._cancellable?.cancel();
        this._cancellable = null;
        this._session?.abort();
        this._session = null;
        this._supervisor?.stop();
        this._supervisor = null;
        this._indicator?.destroy();
        this._indicator = null;
        this._rows = [];
        this._notified = null;
        this._costs = null;
        this._status = null;
    }

    // ----- data -----

    _loadDisplayNames(binary) {
        try {
            const proc = Gio.Subprocess.new(
                [binary, 'config', 'providers', '--format', 'json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
                try {
                    const [, out] = p.communicate_utf8_finish(res);
                    for (const entry of JSON.parse(out))
                        this._names[entry.provider] = entry.displayName;
                    this._render();
                } catch {
                    // cosmetic only — fall back to capitalized ids
                }
            });
        } catch {
            // ignore
        }
    }

    _fetchJSON(url, cb) {
        const msg = Soup.Message.new('GET', url);
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, this._cancellable,
            (session, res) => {
                try {
                    const bytes = session.send_and_read_finish(res);
                    if (msg.get_status() !== Soup.Status.OK)
                        throw new Error(`HTTP ${msg.get_status()}`);
                    cb(JSON.parse(new TextDecoder().decode(bytes.get_data())), null);
                } catch (e) {
                    cb(null, e);
                }
            });
    }

    _get(path, cb) {
        const port = this._supervisor?.port;
        if (!port) {
            cb(null, new Error('serve not running'));
            return;
        }
        this._fetchJSON(`http://127.0.0.1:${port}${path}`, cb);
    }

    _scheduleFetch(secs) {
        if (this._fetchId)
            GLib.source_remove(this._fetchId);
        this._fetchId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, secs, () => {
            this._fetchId = 0;
            this._fetchUsage();
            return GLib.SOURCE_REMOVE;
        });
    }

    _fetchUsage() {
        if (this._fetchInFlight)
            return;
        this._fetchInFlight = true;
        this._get('/usage', (rows, error) => {
            this._fetchInFlight = false;
            if (!this._indicator)
                return; // disabled while in flight
            if (error) {
                this._indicator.setStatus(`usage fetch failed: ${error.message}`);
                this._scheduleFetch(FETCH_RETRY_SECS);
            } else {
                this._rows = mergeStale(this._rows, rows);
                this._lastFetchAt = Date.now();
                this._indicator.setStatus('');
                this._scheduleFetch(FETCH_OK_SECS);
                this._maybeNotify();
            }
            this._render();
        });
    }

    // Quota warnings: one notification per window per reset cycle when it
    // crosses notify-warn-percent, plus one escalation past
    // notify-crit-percent. Cycle identity is provider+window+resetsAt, so a
    // reset (new resetsAt) re-arms; keys absent from the payload are pruned.
    _maybeNotify() {
        if (!this._settings.get_boolean('notify-enabled'))
            return;
        const warnAt = this._settings.get_int('notify-warn-percent');
        const critAt = this._settings.get_int('notify-crit-percent');
        const seen = new Map();
        for (const row of this._rows) {
            if (row.stale)
                continue;
            const name = this._displayName(row.provider);
            const wins = [
                ...windowsOf(row).map(({w, slot}) =>
                    ({w, label: windowLabel(w.windowMinutes, slot)})),
                ...extraWindowsOf(row)
                    .filter(x => x.window.usedPercent !== null &&
                        x.window.usedPercent !== undefined)
                    .map(x => ({w: x.window, label: x.title ?? x.id})),
            ];
            for (const {w, label} of wins) {
                const key = `${row.provider}:${label}:${w.resetsAt ?? ''}`;
                const prev = this._notified.get(key);
                seen.set(key, prev);
                const level = w.usedPercent >= critAt ? 'crit'
                    : w.usedPercent >= warnAt ? 'warn' : null;
                if (!level || prev === 'crit' || prev === level)
                    continue;
                Main.notify(`${name} ${label} at ${Math.round(w.usedPercent)}%`,
                    resetText(w) || 'usage limit approaching');
                seen.set(key, level);
            }
        }
        this._notified = seen;
    }

    _fetchCost() {
        if (this._costs && (Date.now() - this._costFetchedAt) / 1000 < COST_TTL_SECS)
            return;
        this._get('/cost', (reports, error) => {
            if (!this._indicator || error)
                return; // cost is best-effort
            this._costs = reports;
            this._costFetchedAt = Date.now();
            this._render();
        });
    }

    // Which slice of the provider's status page the strip tracks (set in
    // prefs; 'Everything' = whole page). Guarded: not every provider id in
    // the feed has a matching settings key.
    _statusScope(provider) {
        const key = `${provider}-status-scope`;
        return this._settings?.settings_schema.has_key(key)
            ? this._settings.get_string(key)
            : 'Everything';
    }

    // Incident history for the status strips, straight from each provider's
    // public status page (the serve API doesn't carry status — see the
    // TODO(upstream) above URLS). Everything here is best-effort.
    _fetchStatus() {
        for (const [provider, urls] of Object.entries(URLS)) {
            const feed = urls.statusFeed;
            if (!feed)
                continue;
            const cached = this._status[provider];
            if (cached && (Date.now() - cached.fetchedAt) / 1000 < STATUS_TTL_SECS)
                continue;
            const scope = this._statusScope(provider);
            const done = result => {
                if (!this._indicator || !this._status || !result)
                    return;
                this._status[provider] = {...result, scope, fetchedAt: Date.now()};
                this._render();
            };
            if (feed.kind === 'statuspage') {
                this._fetchJSON(`${feed.base}/api/v2/incidents.json`, (data, error) =>
                    done(error ? null : statuspageIntervals(data.incidents, scope)));
            } else {
                // incident.io: the component/group structure lives in the
                // summary document, the impact windows in /incidents.
                this._fetchJSON(feed.base, (summary, error) => {
                    if (error || !this._indicator)
                        return;
                    const ids = incidentIoScopeIds(summary.summary, scope);
                    this._fetchJSON(`${feed.base}/incidents`, (data, err2) =>
                        done(err2 ? null : incidentIoIntervals(data.incidents, ids)));
                });
            }
        }
    }

    // ----- rendering -----

    _displayName(provider) {
        return this._names[provider] ??
            provider.charAt(0).toUpperCase() + provider.slice(1);
    }

    _render() {
        if (!this._indicator)
            return;

        // Panel chips (minus providers hidden in prefs).
        const hiddenChips = new Set(this._settings?.get_strv('hidden-chips') ?? []);
        this._indicator._setPanelText(this._rows
            .filter(row => !hiddenChips.has(row.provider))
            .map(row => {
                const worst = worstPercent(row);
                const grey = row.stale || (row.error && worst === null);
                return {
                    text: worst === null ? '—' : `${Math.round(worst)}%`,
                    sev: severity(worst ?? 0, grey),
                };
            }));

        this._indicator.setUpdated(this._lastFetchAt
            ? `updated ${agoText((Date.now() - this._lastFetchAt) / 1000)}`
            : 'fetching…');

        // Tabs + detail. No selection (null) means the All tab: every card
        // stacked, as before tabs existed. A selected provider that drops
        // out of the feed falls back to All.
        const selectedRow = this._rows.find(r => r.provider === this._selectedProvider) ?? null;

        const tabs = this._indicator._tabsBox;
        tabs.destroy_all_children();
        this._indicator._tabsItem.visible = this._rows.length > 1;
        if (this._rows.length > 1) {
            const worsts = this._rows.map(worstPercent).filter(p => p !== null);
            const allGrey = this._rows.every(r =>
                r.stale || r.error || worstPercent(r) === null);
            tabs.add_child(this._makeTab('All',
                worsts.length ? Math.max(...worsts) : null, allGrey,
                selectedRow === null, () => {
                    this._selectedProvider = null;
                    this._render();
                }));
            for (const row of this._rows) {
                const worst = worstPercent(row);
                tabs.add_child(this._makeTab(this._displayName(row.provider),
                    worst, row.stale || row.error || worst === null,
                    row === selectedRow, () => {
                        this._selectedProvider = row.provider;
                        this._render();
                    }));
            }
        }

        const detail = this._indicator._detailBox;
        detail.destroy_all_children();
        if (!this._rows.length) {
            detail.add_child(new St.Label({
                text: 'No usage data yet.',
                style_class: 'usagebar-dim',
            }));
        } else if (selectedRow) {
            detail.add_child(this._buildCard(selectedRow, {flat: true}));
        } else {
            // All view: compact cards, no cost lines — those live on the
            // per-provider tabs.
            for (const row of this._rows)
                detail.add_child(this._buildCard(row, {showCost: false}));
        }
    }

    _makeTab(label, worst, grey, active, onClick) {
        const content = new St.BoxLayout({vertical: true, style_class: 'usagebar-tab-content'});
        content.add_child(new St.Label({
            text: label,
            style_class: 'usagebar-tab-label',
            x_align: Clutter.ActorAlign.CENTER,
        }));
        const percent = Math.min(100, Math.max(0, worst ?? 0));
        const track = new St.Widget({
            style_class: 'usagebar-track',
            width: MINI_BAR_WIDTH,
            height: 4,
            x_expand: true,
        });
        const fill = new St.Widget({
            style_class: `usagebar-fill usagebar-bg-${severity(percent, grey)}`,
        });
        fill.set_size(Math.max(2, Math.round(MINI_BAR_WIDTH * percent / 100)), 4);
        track.add_child(fill);
        // Same allocation-follow as the card bars: the tab stretches the
        // track, so a fixed-basis fill would read short.
        track.connect('notify::allocation', () => {
            const w = track.allocation.get_width();
            if (w > 0)
                fill.set_size(Math.max(2, Math.round(w * percent / 100)), 4);
        });
        content.add_child(track);

        const btn = new St.Button({
            style_class: 'usagebar-tab',
            child: content,
            x_expand: true,
        });
        if (active)
            btn.add_style_pseudo_class('checked');
        btn.connect('clicked', onClick);
        return btn;
    }

    // Mini daily-trend bar chart (port of the macOS MiniUsageBars): equal
    // bars bottom-aligned over a 1px baseline, height and opacity scaled
    // linearly to the max value.
    _buildTrendChart(points, provider) {
        const wrap = new St.BoxLayout({vertical: true, x_expand: true, style_class: 'usagebar-chart-wrap'});
        const chart = new St.BoxLayout({x_expand: true, height: CHART_HEIGHT, style_class: 'usagebar-chart'});
        const max = Math.max(...points.map(p => p.value), 0);
        // Each day is a full-height reactive slot (so short bars are easy
        // to hover) holding the bottom-aligned bar.
        const slots = points.map(point => {
            const ratio = max > 0 && point.value > 0 ? Math.min(point.value / max, 1) : 0;
            const bar = new St.Widget({
                style_class: `usagebar-chart-bar usagebar-chart-bar-${provider}`,
            });
            bar.set_opacity(Math.round(255 * (0.42 + 0.58 * Math.max(0.18, ratio))));
            bar.set_size(4, ratio > 0 ? Math.max(3, Math.round(ratio * CHART_HEIGHT)) : 1);
            // Vertical box with an expanding spacer: keeps the bar pinned
            // to the baseline (St.Bin centers its child).
            const slot = new St.BoxLayout({vertical: true, reactive: true, track_hover: true});
            slot.add_child(new St.Widget({y_expand: true}));
            slot.add_child(bar);
            slot._ratio = ratio;
            slot._bar = bar;
            slot.connect('notify::hover', () => {
                if (slot.hover)
                    this._showTooltip(slot, chartTooltipText(point));
                else
                    this._indicator?._tooltip?.hide();
            });
            chart.add_child(slot);
            return slot;
        });
        chart.connect('notify::allocation', () => {
            const w = chart.allocation.get_width();
            if (w <= 0)
                return;
            const n = slots.length;
            const bw = Math.min(12, Math.max(2, Math.floor((w - 2 * (n - 1)) / n)));
            for (const slot of slots) {
                slot.set_width(bw);
                const h = slot._ratio > 0 ? Math.max(3, Math.round(slot._ratio * CHART_HEIGHT)) : 1;
                slot._bar.set_size(bw, h);
            }
        });
        wrap.add_child(chart);
        wrap.add_child(new St.Widget({style_class: 'usagebar-chart-baseline', height: 1, x_expand: true}));
        return wrap;
    }

    _showTooltip(anchor, text) {
        const tip = this._indicator?._tooltip;
        if (!tip)
            return;
        tip.text = text;
        // The open menu is a later addition to uiGroup — restack or the
        // tooltip renders behind it.
        Main.uiGroup.set_child_above_sibling(tip, null);
        tip.show();
        const [ax, ay] = anchor.get_transformed_position();
        const [tw, th] = tip.get_size();
        const monitor = Main.layoutManager.currentMonitor;
        let x = Math.round(ax + anchor.get_width() / 2 - tw / 2);
        x = Math.max(monitor.x + 4, Math.min(x, monitor.x + monitor.width - tw - 4));
        tip.set_position(x, Math.round(ay - th - 6));
    }

    // Statuspage-style history strip: one same-height bar per day, colored
    // by that day's worst incident impact (green clean, yellow minor, red
    // major/critical, grey before the feed's coverage), hover tooltip with
    // the incident name. Null until the feed has been fetched.
    _buildStatusStrip(provider) {
        const cached = this._status?.[provider];
        if (!cached)
            return null;
        const wrap = new St.BoxLayout({
            vertical: true,
            x_expand: true,
            style_class: 'usagebar-status-wrap',
        });
        const head = new St.BoxLayout({x_expand: true});
        const scoped = cached.scope && cached.scope !== 'Everything';
        head.add_child(new St.Label({
            text: `${scoped ? `${cached.scope} status` : 'Status'} — last ${STATUS_DAYS} days`,
            style_class: 'usagebar-window-label',
        }));
        head.add_child(new St.Widget({x_expand: true}));
        const now = currentStatus(cached.intervals);
        head.add_child(new St.Label({
            text: now.text,
            style_class: `usagebar-status-now usagebar-fg-${now.sev}`,
        }));
        wrap.add_child(head);

        const strip = new St.BoxLayout({x_expand: true, style_class: 'usagebar-status-strip'});
        const bars = statusDays(cached.intervals, STATUS_DAYS, cached.covered).map(day => {
            const bar = new St.Widget({
                style_class: `usagebar-status-day usagebar-bg-${day.sev}`,
                width: 6,
                height: STATUS_BAR_HEIGHT,
                reactive: true,
                track_hover: true,
            });
            bar.connect('notify::hover', () => {
                if (bar.hover)
                    this._showTooltip(bar, statusTooltipText(day));
                else
                    this._indicator?._tooltip?.hide();
            });
            strip.add_child(bar);
            return bar;
        });
        // Fill the card width: same allocation-follow as the trend chart
        // (the 2px gaps come from the strip's CSS spacing).
        strip.connect('notify::allocation', () => {
            const w = strip.allocation.get_width();
            if (w <= 0)
                return;
            const bw = Math.max(2, Math.floor((w - 2 * (bars.length - 1)) / bars.length));
            for (const bar of bars)
                bar.set_width(bw);
        });
        wrap.add_child(strip);
        return wrap;
    }

    // One usage metric: label + "% · resets in …" row, severity bar, pace.
    // Handles windows with unknown percent (upstream shows "Unavailable").
    _addWindowRow(card, label, w, stale, paceSummary) {
        const known = w.usedPercent !== null && w.usedPercent !== undefined;
        const percent = known ? Math.min(100, Math.max(0, w.usedPercent)) : 0;
        const sev = severity(percent, stale || !known);

        const labels = new St.BoxLayout({x_expand: true, style_class: 'usagebar-window-row'});
        labels.add_child(new St.Label({
            text: label,
            style_class: 'usagebar-window-label',
        }));
        labels.add_child(new St.Widget({x_expand: true}));
        const reset = resetText(w);
        labels.add_child(new St.Label({
            text: known
                ? (reset ? `${Math.round(w.usedPercent)}% · ${reset}` : `${Math.round(w.usedPercent)}%`)
                : (reset ? `unavailable · ${reset}` : 'unavailable'),
            style_class: 'usagebar-dim',
        }));
        card.add_child(labels);

        const track = new St.Widget({
            style_class: 'usagebar-track',
            width: BAR_WIDTH,
            height: 6,
        });
        const fill = new St.Widget({style_class: `usagebar-fill usagebar-bg-${sev}`});
        fill.set_size(Math.max(3, Math.round(BAR_WIDTH * percent / 100)), 6);
        track.add_child(fill);
        // The box layout stretches the track past BAR_WIDTH; size the fill
        // against the real allocation or the percentage reads short.
        track.connect('notify::allocation', () => {
            const w = track.allocation.get_width();
            if (w > 0)
                fill.set_size(Math.max(3, Math.round(w * percent / 100)), 6);
        });
        card.add_child(track);

        if (paceSummary) {
            const pace = new St.Label({
                text: paceSummary.startsWith('Pace') ? paceSummary : `Pace: ${paceSummary}`,
                style_class: 'usagebar-dim usagebar-pace',
            });
            pace.clutter_text.line_wrap = true;
            card.add_child(pace);
        }
    }

    // flat: no card background; thin separator lines between sections
    // (usage | credits/cost | links) — used on the per-provider tabs.
    _buildCard(row, {showCost = true, flat = false} = {}) {
        const card = new St.BoxLayout({
            vertical: true,
            style_class: flat ? 'usagebar-card-flat' : 'usagebar-card',
            x_expand: true,
        });
        const addSeparator = () => card.add_child(new St.Widget({
            style_class: 'usagebar-separator',
            height: 1,
            x_expand: true,
        }));
        const worst = worstPercent(row);
        const grey = row.stale || (row.error && worst === null);

        // Head: name + badges left, worst% right.
        const head = new St.BoxLayout({x_expand: true});
        head.add_child(new St.Label({
            text: this._displayName(row.provider),
            style_class: 'usagebar-card-title',
            y_align: Clutter.ActorAlign.CENTER,
        }));
        let plan = row.usage?.loginMethod ?? row.usage?.identity?.loginMethod;
        if (plan) {
            plan = plan.charAt(0).toUpperCase() + plan.slice(1);
            // Drop a leading provider name ("Claude Max" → "Max"): the card
            // title already says it.
            const name = this._displayName(row.provider);
            if (plan.toLowerCase().startsWith(`${name.toLowerCase()} `))
                plan = plan.slice(name.length + 1);
            head.add_child(new St.Label({
                text: plan,
                style_class: 'usagebar-badge',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        if (row.stale) {
            head.add_child(new St.Label({
                text: 'stale',
                style_class: 'usagebar-badge usagebar-badge-stale',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        head.add_child(new St.Widget({x_expand: true}));
        if (worst !== null) {
            head.add_child(new St.Label({
                text: `${Math.round(worst)}%`,
                style_class: `usagebar-worst usagebar-fg-${severity(worst, grey)}`,
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        card.add_child(head);

        if (row.error) {
            const msg = row.error.message ?? 'provider fetch failed';
            const suffix = row.stale ? ' — showing last known data' : '';
            const banner = new St.Label({
                text: `⚠ ${msg}${suffix}`,
                style_class: 'usagebar-banner',
                x_expand: true,
            });
            banner.clutter_text.line_wrap = true;
            card.add_child(banner);
        }

        for (const {w, slot} of windowsOf(row)) {
            const pace = row.pace ? [row.pace.primary, row.pace.secondary][slot] : null;
            this._addWindowRow(card, windowLabel(w.windowMinutes, slot), w,
                row.stale, pace?.summary);
        }

        // Extra named limits (per-model bars like Fable, Daily Routines) —
        // rendered like the standard windows, as in the macOS card.
        for (const x of extraWindowsOf(row))
            this._addWindowRow(card, x.title ?? x.id, x.window, row.stale, null);

        const report = showCost
            ? (this._costs ?? []).find(c => c.provider === row.provider)
            : null;

        // Limit Reset Credits header (codex): count right-aligned, nearest
        // expiry below — matches the macOS card. Full card only, like cost.
        const credits = showCost ? creditsInfo(row) : null;
        const kpis = costKpis(report);
        const models = topModelsLine(report);
        if (flat && (credits || kpis || models))
            addSeparator();
        if (credits) {
            const head = new St.BoxLayout({x_expand: true, style_class: 'usagebar-credits'});
            head.add_child(new St.Label({text: 'Limit Reset Credits', style_class: 'usagebar-window-label'}));
            head.add_child(new St.Widget({x_expand: true}));
            head.add_child(new St.Label({text: credits.text, style_class: 'usagebar-credits-count'}));
            card.add_child(head);
            if (credits.expiryLine)
                card.add_child(new St.Label({text: credits.expiryLine, style_class: 'usagebar-dim'}));
        }

        if (kpis) {
            for (let i = 0; i < kpis.length; i += 2) {
                const kpiRow = new St.BoxLayout({x_expand: true, style_class: 'usagebar-kpi-row'});
                kpis.slice(i, i + 2).forEach((kpi, col) => {
                    // Fixed-width left column so the right column lines up
                    // across rows (natural widths differ per label).
                    const cell = new St.BoxLayout({
                        vertical: true,
                        ...(col === 0 ? {width: KPI_COL_WIDTH} : {x_expand: true}),
                    });
                    cell.add_child(new St.Label({text: kpi.title, style_class: 'usagebar-dim'}));
                    cell.add_child(new St.Label({text: kpi.value, style_class: 'usagebar-kpi-value'}));
                    kpiRow.add_child(cell);
                });
                card.add_child(kpiRow);
            }
        }
        const trend = chartPoints(report);
        if (trend)
            card.add_child(this._buildTrendChart(trend, row.provider));

        if (models) {
            card.add_child(new St.Label({
                text: models,
                style_class: 'usagebar-dim usagebar-models',
            }));
        }
        if (report && COST_HINTS[row.provider]) {
            const hintLabel = new St.Label({
                text: COST_HINTS[row.provider],
                style_class: 'usagebar-dim usagebar-hint',
            });
            hintLabel.clutter_text.line_wrap = true;
            card.add_child(hintLabel);
        }

        const urls = URLS[row.provider];
        // Status strip only on the detail tabs, like cost — All stays compact.
        const statusStrip = showCost ? this._buildStatusStrip(row.provider) : null;
        if (flat && (urls || statusStrip))
            addSeparator();
        if (statusStrip)
            card.add_child(statusStrip);
        if (urls) {
            const links = new St.BoxLayout({style_class: 'usagebar-links'});
            for (const [label, url] of [['Dashboard', urls.dashboard], ['Status', urls.status]]) {
                const btn = new St.Button({
                    label,
                    style_class: 'usagebar-link',
                    y_align: Clutter.ActorAlign.CENTER,
                });
                btn.connect('clicked', () => {
                    Gio.AppInfo.launch_default_for_uri(url, null);
                    this._indicator.menu.close();
                });
                links.add_child(btn);
            }
            card.add_child(links);
        }

        return card;
    }
}
