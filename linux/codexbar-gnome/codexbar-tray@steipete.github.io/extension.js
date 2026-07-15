// CodexBar Tray — GNOME Shell extension.
//
// Panel chips (one per provider, worst-window percent) opening an anchored
// popover with a tab strip ("All" + one tab per provider, each with a mini
// usage bar) above the detail area: all cards stacked on the All tab, a
// single card per provider tab — rate-window progress bars, reset
// countdowns, pace, cost (Today / 30 days, top models) and links.
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
const BAR_WIDTH = 320;
const MINI_BAR_WIDTH = 26;

// TODO(upstream): expose these in `codexbar config providers --format json`
// (they exist per-provider in CodexBarCore's ProviderDescriptors).
const URLS = {
    codex: {
        dashboard: 'https://chatgpt.com/codex/settings/usage',
        status: 'https://status.openai.com/',
    },
    claude: {
        dashboard: 'https://claude.ai/settings/usage',
        status: 'https://status.claude.com/',
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
    return v === null || v === undefined ? null : `$${v.toFixed(2)}`;
}

function costLine(report) {
    if (!report)
        return null;
    const parts = [];
    const today = new Date().toLocaleDateString('en-CA'); // local YYYY-MM-DD
    const entry = (report.daily ?? []).find(d => d.date === today);
    if (entry) {
        // Dollar values arrive under the upstream key "totalCost".
        const bits = [fmtUSD(entry.totalCost), fmtTokens(entry.totalTokens)]
            .filter(Boolean);
        if (bits.length)
            parts.push(`Today ${bits.join(' · ')}`);
    }
    const totals = report.totals ?? {};
    const usd = report.last30DaysCostUSD ?? totals.totalCost;
    const toks = report.last30DaysTokens ?? totals.totalTokens;
    const bits30 = [fmtUSD(usd), fmtTokens(toks)].filter(Boolean);
    if (bits30.length)
        parts.push(`${report.historyDays ?? 30}d ${bits30.join(' · ')}`);
    return parts.length ? parts.join('   ·   ') : null;
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
class CodexBarIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.5, 'CodexBar', false);

        this._chipBox = new St.BoxLayout({style_class: 'codexbar-panel-box'});
        this.add_child(this._chipBox);
        this._setPanelText([]);

        this.menu.box.add_style_class_name('codexbar-menu');

        // Header: title left, "updated Xs ago" right.
        const header = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        header.add_child(new St.Label({
            text: 'CodexBar',
            style_class: 'codexbar-title',
            x_expand: true,
            y_align: Clutter.ActorAlign.CENTER,
        }));
        this._updatedLabel = new St.Label({
            text: '',
            style_class: 'codexbar-dim',
            y_align: Clutter.ActorAlign.CENTER,
        });
        header.add_child(this._updatedLabel);
        this.menu.addMenuItem(header);

        // Status banner (serve problems, fetch errors).
        this._statusItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._statusLabel = new St.Label({style_class: 'codexbar-banner', x_expand: true});
        this._statusLabel.clutter_text.line_wrap = true;
        this._statusItem.add_child(this._statusLabel);
        this._statusItem.visible = false;
        this.menu.addMenuItem(this._statusItem);

        // Tab strip (one tab per provider) above a single detail card;
        // both rebuilt on every render.
        this._tabsItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._tabsBox = new St.BoxLayout({style_class: 'codexbar-tabs', x_expand: true});
        this._tabsItem.add_child(this._tabsBox);
        this._tabsItem.visible = false;
        this.menu.addMenuItem(this._tabsItem);

        const detailItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._detailBox = new St.BoxLayout({vertical: true, x_expand: true});
        detailItem.add_child(this._detailBox);
        this.menu.addMenuItem(detailItem);

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
                text: 'CB',
                style_class: 'codexbar-chip-label',
                y_align: Clutter.ActorAlign.CENTER,
            }));
            return;
        }
        for (const chip of chips) {
            const box = new St.BoxLayout({style_class: 'codexbar-chip'});
            box.add_child(new St.Widget({
                style_class: `codexbar-dot codexbar-bg-${chip.sev}`,
                width: 8,
                height: 8,
                y_align: Clutter.ActorAlign.CENTER,
            }));
            box.add_child(new St.Label({
                text: chip.text,
                style_class: 'codexbar-chip-label',
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

export default class CodexBarExtension extends Extension {
    enable() {
        this._rows = [];
        this._names = {};
        this._selectedProvider = null;
        this._notified = new Map();
        this._costs = null;
        this._costFetchedAt = 0;
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
        this._settingsChangedId = this._settings.connect('changed', () => {
            applyThresholds();
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
                this._render();
            }
        });
        Main.panel.addToStatusArea(this.uuid, this._indicator);

        const binary = findBinary();
        if (!binary) {
            this._indicator.setStatus('codexbar CLI not found — install it ' +
                '(brew install steipete/tap/codexbar) or set $CODEXBAR_BIN');
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

    _get(path, cb) {
        const port = this._supervisor?.port;
        if (!port) {
            cb(null, new Error('serve not running'));
            return;
        }
        const msg = Soup.Message.new('GET', `http://127.0.0.1:${port}${path}`);
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
                style_class: 'codexbar-dim',
            }));
        } else if (selectedRow) {
            detail.add_child(this._buildCard(selectedRow));
        } else {
            // All view: compact cards, no cost lines — those live on the
            // per-provider tabs.
            for (const row of this._rows)
                detail.add_child(this._buildCard(row, {showCost: false}));
        }
    }

    _makeTab(label, worst, grey, active, onClick) {
        const content = new St.BoxLayout({vertical: true, style_class: 'codexbar-tab-content'});
        content.add_child(new St.Label({
            text: label,
            style_class: 'codexbar-tab-label',
            x_align: Clutter.ActorAlign.CENTER,
        }));
        const percent = Math.min(100, Math.max(0, worst ?? 0));
        const track = new St.Widget({
            style_class: 'codexbar-track',
            width: MINI_BAR_WIDTH,
            height: 3,
            x_align: Clutter.ActorAlign.CENTER,
        });
        const fill = new St.Widget({
            style_class: `codexbar-fill codexbar-bg-${severity(percent, grey)}`,
        });
        fill.set_size(Math.max(2, Math.round(MINI_BAR_WIDTH * percent / 100)), 3);
        track.add_child(fill);
        content.add_child(track);

        const btn = new St.Button({
            style_class: 'codexbar-tab',
            child: content,
            x_expand: true,
        });
        if (active)
            btn.add_style_pseudo_class('checked');
        btn.connect('clicked', onClick);
        return btn;
    }

    // One usage metric: label + "% · resets in …" row, severity bar, pace.
    // Handles windows with unknown percent (upstream shows "Unavailable").
    _addWindowRow(card, label, w, stale, paceSummary) {
        const known = w.usedPercent !== null && w.usedPercent !== undefined;
        const percent = known ? Math.min(100, Math.max(0, w.usedPercent)) : 0;
        const sev = severity(percent, stale || !known);

        const labels = new St.BoxLayout({x_expand: true, style_class: 'codexbar-window-row'});
        labels.add_child(new St.Label({
            text: label,
            style_class: 'codexbar-window-label',
        }));
        labels.add_child(new St.Widget({x_expand: true}));
        const reset = resetText(w);
        labels.add_child(new St.Label({
            text: known
                ? (reset ? `${Math.round(w.usedPercent)}% · ${reset}` : `${Math.round(w.usedPercent)}%`)
                : (reset ? `unavailable · ${reset}` : 'unavailable'),
            style_class: 'codexbar-dim',
        }));
        card.add_child(labels);

        const track = new St.Widget({
            style_class: 'codexbar-track',
            width: BAR_WIDTH,
            height: 6,
        });
        const fill = new St.Widget({style_class: `codexbar-fill codexbar-bg-${sev}`});
        fill.set_size(Math.max(3, Math.round(BAR_WIDTH * percent / 100)), 6);
        track.add_child(fill);
        card.add_child(track);

        if (paceSummary) {
            card.add_child(new St.Label({
                text: paceSummary.startsWith('Pace') ? paceSummary : `Pace: ${paceSummary}`,
                style_class: 'codexbar-dim codexbar-pace',
            }));
        }
    }

    _buildCard(row, {showCost = true} = {}) {
        const card = new St.BoxLayout({vertical: true, style_class: 'codexbar-card', x_expand: true});
        const worst = worstPercent(row);
        const grey = row.stale || (row.error && worst === null);

        // Head: name + badges left, worst% right.
        const head = new St.BoxLayout({x_expand: true});
        head.add_child(new St.Label({
            text: this._displayName(row.provider),
            style_class: 'codexbar-card-title',
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
                style_class: 'codexbar-badge',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        if (row.stale) {
            head.add_child(new St.Label({
                text: 'stale',
                style_class: 'codexbar-badge codexbar-badge-stale',
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        head.add_child(new St.Widget({x_expand: true}));
        if (worst !== null) {
            head.add_child(new St.Label({
                text: `${Math.round(worst)}%`,
                style_class: `codexbar-worst codexbar-fg-${severity(worst, grey)}`,
                y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        card.add_child(head);

        if (row.error) {
            const msg = row.error.message ?? 'provider fetch failed';
            const suffix = row.stale ? ' — showing last known data' : '';
            const banner = new St.Label({
                text: `⚠ ${msg}${suffix}`,
                style_class: 'codexbar-banner',
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
        const cost = costLine(report);
        if (cost) {
            card.add_child(new St.Label({
                text: cost,
                style_class: 'codexbar-dim codexbar-cost',
            }));
        }
        const models = topModelsLine(report);
        if (models) {
            card.add_child(new St.Label({
                text: models,
                style_class: 'codexbar-dim codexbar-models',
            }));
        }

        const urls = URLS[row.provider];
        if (urls) {
            const links = new St.BoxLayout({style_class: 'codexbar-links'});
            for (const [label, url] of [['Dashboard', urls.dashboard], ['Status', urls.status]]) {
                const btn = new St.Button({
                    label,
                    style_class: 'codexbar-link',
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
