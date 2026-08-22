// UsageBar — extension preferences (opened from the popover's
// Settings item or `gnome-extensions prefs`). Mirrors the macOS app's
// Preferences shape: General / Notifications / Providers.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {PROVIDER_META} from './providermeta.js';
import {scopeOf, setScope} from './statusscopes.js';

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

// Every provider the CLI knows, enabled state included. Falls back to the
// two bootstrap providers when the CLI is missing (the Providers page is
// then read-only anyway).
function allProviders() {
    const fallback = [
        {id: 'codex', name: 'Codex', enabled: true},
        {id: 'claude', name: 'Claude', enabled: true},
    ];
    const binary = findBinary();
    if (!binary)
        return {binary, providers: fallback};
    try {
        const proc = Gio.Subprocess.new(
            [binary, 'config', 'providers', '--format', 'json'],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        const [, out] = proc.communicate_utf8(null, null);
        const list = JSON.parse(out).map(p => ({
            id: p.provider,
            name: p.displayName ?? PROVIDER_META[p.provider]?.name ?? p.provider,
            enabled: !!p.enabled,
        }));
        return {binary, providers: list.length ? list : fallback};
    } catch {
        return {binary, providers: fallback};
    }
}

// Which slice of the public status page the popover's incident-history
// strip tracks. The curated scope lists live in providermeta.js (generated);
// providers without one (or without a feed at all) track 'Everything'.
function statusScopeRow(settings, provider) {
    const meta = PROVIDER_META[provider];
    const scopes = meta?.statusScopes;
    if (!scopes || !meta?.statusFeed)
        return null;
    const row = new Adw.ComboRow({
        title: 'Status strip tracks',
        subtitle: 'Which part of the status page colors the history bars',
        model: Gtk.StringList.new(scopes),
    });
    row.selected = Math.max(0, scopes.indexOf(scopeOf(settings, provider)));
    row.connect('notify::selected', () => {
        setScope(settings, provider, scopes[row.selected]);
    });
    return row;
}

// Membership switch against a strv set key (hidden-chips, hidden-windows,
// notify-muted-providers): being in the list means hidden/muted, so the
// switch shows ON when the member is absent.
function strvMemberRow(settings, key, member, {title, subtitle = ''}) {
    const row = new Adw.SwitchRow({
        title,
        subtitle,
        active: !new Set(settings.get_strv(key)).has(member),
    });
    row.connect('notify::active', () => {
        const set = new Set(settings.get_strv(key));
        if (row.active)
            set.delete(member);
        else
            set.add(member);
        settings.set_strv(key, [...set].sort());
    });
    return row;
}

// One switch per usage bar the extension has seen for this provider, from the
// `known-windows` catalog it publishes on render. Toggling off adds the bar's
// "provider:key" to `hidden-windows`, which removes it from the popover card.
// Empty until the popover has rendered at least once — then a hint row shows.
function windowToggleRows(settings, provider) {
    const known = settings.get_strv('known-windows')
        .map(s => {
            try {
                return JSON.parse(s);
            } catch {
                return null;
            }
        })
        .filter(e => e && e.p === provider);
    if (!known.length) {
        const hint = new Adw.ActionRow({
            title: 'Usage bars',
            subtitle: 'Open the popover once to list this provider’s bars here',
        });
        return [hint];
    }
    return known.map(e => strvMemberRow(settings, 'hidden-windows', `${e.p}:${e.k}`,
        {title: `Show ${e.l} bar`}));
}

function spinRow(settings, key, title, subtitle, {lower = 1, upper = 100, step = 1} = {}) {
    const row = new Adw.SpinRow({
        title,
        subtitle,
        adjustment: new Gtk.Adjustment({
            lower,
            upper,
            step_increment: step,
            page_increment: step * 10,
        }),
    });
    settings.bind(key, row, 'value', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

function switchRow(settings, key, title, subtitle = '') {
    const row = new Adw.SwitchRow({title, subtitle});
    settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

// Comma-separated percent list bound to an 'ai' key (e.g. "80, 95").
// Applied on the row's apply button / Enter; invalid input flags the row
// and writes nothing.
function thresholdListRow(settings, key, title) {
    const row = new Adw.EntryRow({title, show_apply_button: true});
    row.text = settings.get_value(key).deepUnpack().join(', ');
    row.connect('apply', () => {
        const parts = row.text.split(',').map(s => s.trim()).filter(Boolean);
        const nums = [...new Set(parts.map(Number))];
        const values = nums
            .filter(n => Number.isInteger(n) && n >= 1 && n <= 100)
            .sort((a, b) => a - b);
        // Empty, or the range filter dropped something: flag, write nothing.
        if (!values.length || values.length !== nums.length) {
            row.add_css_class('error');
            return;
        }
        row.remove_css_class('error');
        settings.set_value(key, new GLib.Variant('ai', values));
        row.text = values.join(', ');
    });
    return row;
}

export default class UsageBarPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        // --- General ---
        const general = new Adw.PreferencesPage({
            title: 'General',
            icon_name: 'preferences-system-symbolic',
        });

        const panel = new Adw.PreferencesGroup({
            title: 'Panel',
            description: 'How usage chips appear in the top bar.',
        });
        const modeRow = new Adw.ComboRow({
            title: 'Chip shows',
            model: Gtk.StringList.new([
                'Icon and progress ring',
                'Icon, ring, and percent',
                'Icon and percent',
                'Name, ring, and percent',
                'Severity dot only',
            ]),
        });
        const MODES = ['ring', 'ring-percent', 'percent', 'name-percent', 'dot'];
        modeRow.selected = Math.max(0, MODES.indexOf(settings.get_string('chip-display-mode')));
        modeRow.connect('notify::selected', () => {
            settings.set_string('chip-display-mode', MODES[modeRow.selected]);
        });
        panel.add(modeRow);
        panel.add(switchRow(settings, 'merge-chips', 'Single merged chip',
            'One chip for the provider closest to its limit'));
        panel.add(switchRow(settings, 'show-reset-when-exhausted',
            'Show reset time when exhausted',
            'An exhausted chip counts down to the reset instead of showing 100%'));
        general.add(panel);

        const popover = new Adw.PreferencesGroup({
            title: 'Popover',
            description: 'How usage is written on the cards.',
        });
        popover.add(switchRow(settings, 'bars-show-used', 'Bars show percent used',
            'Off shows percent remaining'));
        popover.add(switchRow(settings, 'absolute-reset-times', 'Absolute reset times',
            '"Resets 18:30" instead of "Resets in 3h"'));
        popover.add(switchRow(settings, 'show-credits-extras', 'Credits and extra limits',
            'Limit-reset credits and per-model or feature bars'));
        general.add(popover);

        const thresholds = new Adw.PreferencesGroup({
            title: 'Severity thresholds',
            description: 'Usage percent at which bars and panel chips change color.',
        });
        thresholds.add(spinRow(settings, 'warn-threshold',
            'Warn above', 'Yellow from this percent up', {upper: 99}));
        thresholds.add(spinRow(settings, 'crit-threshold',
            'Critical above', 'Red from this percent up', {upper: 99}));
        general.add(thresholds);

        const behavior = new Adw.PreferencesGroup({title: 'Behavior'});
        behavior.add(spinRow(settings, 'refresh-interval-secs', 'Refresh interval',
            'Seconds between backend fetches; applying restarts the backend',
            {lower: 60, upper: 3600, step: 30}));
        behavior.add(switchRow(settings, 'refresh-on-open', 'Refresh when opened',
            'Fetch fresh usage every time the popover opens'));
        behavior.add(switchRow(settings, 'status-checks-enabled', 'Provider status strips',
            'Poll public status pages for the incident history strips'));
        behavior.add(switchRow(settings, 'sort-alphabetical', 'Sort providers alphabetically',
            'Off keeps the codexbar config order'));
        general.add(behavior);
        window.add(general);

        // --- Notifications ---
        const notifications = new Adw.PreferencesPage({
            title: 'Notifications',
            icon_name: 'preferences-system-notifications-symbolic',
        });
        const quota = new Adw.PreferencesGroup({
            title: 'Quota warnings',
            description: 'Notify when a rate window crosses a threshold, ' +
                'once per threshold per reset cycle.',
        });
        const enabledRow = new Adw.SwitchRow({title: 'Notify on high usage'});
        settings.bind('notify-enabled', enabledRow, 'active', Gio.SettingsBindFlags.DEFAULT);
        quota.add(enabledRow);
        for (const row of [
            thresholdListRow(settings, 'notify-session-thresholds',
                'Session window thresholds (%)'),
            thresholdListRow(settings, 'notify-weekly-thresholds',
                'Weekly window thresholds (%)'),
            switchRow(settings, 'notify-pace-enabled', 'Pace warnings',
                'Warn when the projection says a window runs out before reset'),
            switchRow(settings, 'notify-sound', 'Play sound'),
        ]) {
            settings.bind('notify-enabled', row, 'sensitive', Gio.SettingsBindFlags.GET);
            quota.add(row);
        }
        notifications.add(quota);
        window.add(notifications);

        // --- Providers ---
        const {binary, providers} = allProviders();
        const page = new Adw.PreferencesPage({
            title: 'Providers',
            icon_name: 'network-server-symbolic',
        });

        const catalog = new Adw.PreferencesGroup({
            title: 'Providers',
            description: binary
                ? 'Enabling fetches through the codexbar CLI. Reopen ' +
                  'Settings to configure a newly enabled provider.'
                : 'codexbar CLI not found — install it to manage providers.',
        });
        const byName = (a, b) => a.name.localeCompare(b.name);
        const enabled = providers.filter(p => p.enabled).sort(byName);
        const disabled = providers.filter(p => !p.enabled).sort(byName);
        for (const p of enabled)
            catalog.add(this._providerToggleRow(binary, p));
        if (disabled.length) {
            const more = new Adw.ExpanderRow({
                title: 'More providers',
                subtitle: `${disabled.length} available`,
            });
            for (const p of disabled)
                more.add_row(this._providerToggleRow(binary, p));
            catalog.add(more);
        }
        page.add(catalog);

        // Per-provider display settings, enabled providers only.
        for (const {id, name} of enabled) {
            const group = new Adw.PreferencesGroup({title: name});
            group.add(strvMemberRow(settings, 'hidden-chips', id, {
                title: 'Show panel chip',
                subtitle: 'The popover card stays either way',
            }));
            group.add(strvMemberRow(settings, 'notify-muted-providers', id, {
                title: 'Notifications',
                subtitle: 'Quota and pace warnings from this provider',
            }));
            if (id === 'antigravity') {
                group.add(switchRow(settings, 'antigravity-overview-gemini',
                    'Overview: Gemini models',
                    'Show Gemini 5h & weekly in All view (off shows Claude & GPT)'));
            }
            const scopeRow = statusScopeRow(settings, id);
            if (scopeRow)
                group.add(scopeRow);
            for (const row of windowToggleRows(settings, id))
                group.add(row);
            page.add(group);
        }
        window.add(page);
    }

    // Enable/disable switch backed by `codexbar config enable|disable`;
    // reverts on failure. The extension notices success by itself — it
    // watches the CLI's config.json for changes.
    _providerToggleRow(binary, provider) {
        const row = new Adw.SwitchRow({
            title: provider.name,
            subtitle: provider.id,
            active: provider.enabled,
            sensitive: !!binary,
        });
        let reverting = false;
        const revert = () => {
            row.sensitive = true;
            reverting = true;
            row.active = !row.active;
            reverting = false;
        };
        row.connect('notify::active', () => {
            if (reverting || !binary)
                return;
            const verb = row.active ? 'enable' : 'disable';
            row.sensitive = false;
            try {
                const proc = Gio.Subprocess.new(
                    [binary, 'config', verb, '--provider', provider.id],
                    Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
                proc.wait_async(null, (p, res) => {
                    let ok = false;
                    try {
                        p.wait_finish(res);
                        ok = p.get_successful();
                    } catch {
                        ok = false;
                    }
                    if (ok)
                        row.sensitive = true;
                    else
                        revert();
                });
            } catch {
                revert();
            }
        });
        return row;
    }
}
