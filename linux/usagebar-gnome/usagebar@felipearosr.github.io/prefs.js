// UsageBar — extension preferences (opened from the popover's
// Settings item or `gnome-extensions prefs`). Mirrors the macOS app's
// Preferences shape: General / Notifications / Providers, plus Machine Sync.

import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {
    decodeCatalog,
    hexColor,
    isModelHidden,
    modelColors,
    modelKey,
    providerModels,
} from './modelprefs.js';
import {PROVIDER_META} from './providermeta.js';
import {moveProviderOrder, resolveProviderOrder} from './renderstate.js';
import {scopeOf, setScope} from './statusscopes.js';
import {MachineSyncPage} from './syncpage.js';
import {PACKAGED_BIN} from './updates.js';

function findBinary() {
    const explicit = GLib.getenv('CODEXBAR_BIN');
    if (explicit && GLib.file_test(explicit, GLib.FileTest.IS_EXECUTABLE))
        return explicit;
    if (GLib.file_test(PACKAGED_BIN, GLib.FileTest.IS_EXECUTABLE))
        return PACKAGED_BIN;
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
    const row = plainSwitchRow(title, subtitle, {  // titles embed CLI labels
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

// Models: one row per model the extension has seen for this provider, with
// its chart color on the left and an include switch on the right. Excluded
// models leave chart bars, legends and model lists; totals keep them.
function modelsExpanderRow(settings, provider) {
    const catalog = decodeCatalog(settings.get_strv('known-models'));
    const models = providerModels(catalog, provider);
    const expander = new Adw.ExpanderRow({title: 'Models', use_markup: false});
    if (!models.length) {
        expander.subtitle = 'None seen yet. Models appear once cost or Machine Sync data arrives.';
        expander.enable_expansion = false;
        return expander;
    }

    const brand = PROVIDER_META[provider]?.color ?? null;
    const overrides = () => settings.get_value('model-colors').deepUnpack();
    const ownOverrides = () => Object.keys(overrides()).filter(key => key.startsWith(`${provider}:`));
    const writeOverrides = next => settings.set_value('model-colors', new GLib.Variant('a{ss}', next));
    const updateSubtitle = () => {
        const hidden = new Set(settings.get_strv('hidden-models'));
        const shown = models.filter(model => !isModelHidden(hidden, provider, model)).length;
        expander.subtitle = shown === models.length
            ? `All ${models.length} included in charts and lists`
            : `${shown} of ${models.length} included in charts and lists`;
    };

    const buttons = new Map();
    let syncing = false;
    const syncColors = () => {
        const colors = modelColors(provider, {catalog, overrides: overrides(), brand});
        syncing = true;
        for (const [model, button] of buttons) {
            const rgba = new Gdk.RGBA();
            if (rgba.parse(colors.get(model)) && !rgba.equal(button.rgba))
                button.rgba = rgba;
        }
        syncing = false;
        resetButton.sensitive = ownOverrides().length > 0;
    };

    const hidden = new Set(settings.get_strv('hidden-models'));
    for (const model of models) {
        const key = modelKey(provider, model);
        const row = new Adw.ActionRow({title: model, use_markup: false});
        const button = new Gtk.ColorDialogButton({
            dialog: new Gtk.ColorDialog({title: `Chart color for ${model}`, with_alpha: false}),
            valign: Gtk.Align.CENTER,
            tooltip_text: 'Chart color',
        });
        button.connect('notify::rgba', () => {
            if (!syncing)
                writeOverrides({...overrides(), [key]: hexColor(button.rgba)});
        });
        buttons.set(model, button);
        row.add_prefix(button);

        const toggle = new Gtk.Switch({
            active: !hidden.has(key),
            valign: Gtk.Align.CENTER,
            tooltip_text: 'Include in charts and model lists',
        });
        toggle.connect('notify::active', () => {
            const next = new Set(settings.get_strv('hidden-models'));
            if (toggle.active)
                next.delete(key);
            else
                next.add(key);
            settings.set_strv('hidden-models', [...next].sort());
            updateSubtitle();
        });
        row.add_suffix(toggle);
        row.activatable_widget = toggle;
        expander.add_row(row);
    }

    const resetRow = new Adw.ActionRow({
        title: 'Default colors',
        subtitle: 'Largest model in the brand color, the rest from the palette',
    });
    const resetButton = new Gtk.Button({label: 'Reset', valign: Gtk.Align.CENTER});
    resetButton.connect('clicked', () => {
        const next = overrides();
        for (const key of ownOverrides())
            delete next[key];
        writeOverrides(next);
    });
    resetRow.add_suffix(resetButton);
    expander.add_row(resetRow);

    const changedId = settings.connect('changed::model-colors', syncColors);
    expander.connect('destroy', () => settings.disconnect(changedId));
    syncColors();
    updateSubtitle();
    return expander;
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

// Plain-text row: use_markup must be off before title/subtitle are set —
// passed together to the constructor, the text can be parsed as markup
// first ("Gemini 5h & weekly" renders blank).
function plainSwitchRow(title, subtitle = '', props = {}) {
    const row = new Adw.SwitchRow({use_markup: false, ...props});
    row.title = title;
    row.subtitle = subtitle;
    return row;
}

function switchRow(settings, key, title, subtitle = '') {
    const row = plainSwitchRow(title, subtitle);
    settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

function providerOrderGroup(settings, providers) {
    const group = new Adw.PreferencesGroup({
        title: 'Display order',
        description: 'Controls provider order in the panel and overview. ' +
            'Moving a provider turns off alphabetical sorting.',
    });
    let rows = [];
    let rebuildId = 0;
    const rebuild = () => {
        for (const row of rows)
            group.remove(row);
        const names = Object.fromEntries(providers.map(provider => [provider.id, provider.name]));
        const order = resolveProviderOrder(
            providers.map(provider => provider.id),
            settings.get_strv('provider-order'),
            settings.get_boolean('sort-alphabetical') ? names : null);
        const byId = new Map(providers.map(provider => [provider.id, provider]));
        rows = order.map((id, index) => {
            const provider = byId.get(id);
            const row = new Adw.ActionRow({title: provider.name, subtitle: provider.id});
            const addMoveButton = (direction, iconName, tooltip, sensitive) => {
                const button = new Gtk.Button({
                    icon_name: iconName,
                    tooltip_text: tooltip,
                    valign: Gtk.Align.CENTER,
                    sensitive,
                    css_classes: ['flat'],
                });
                button.connect('clicked', () => {
                    settings.set_strv('provider-order', moveProviderOrder(order, id, direction));
                    settings.set_boolean('sort-alphabetical', false);
                });
                row.add_suffix(button);
            };
            addMoveButton(-1, 'go-up-symbolic', `Move ${provider.name} up`, index > 0);
            addMoveButton(1, 'go-down-symbolic', `Move ${provider.name} down`,
                index < order.length - 1);
            group.add(row);
            return row;
        });
    };
    const queueRebuild = () => {
        if (rebuildId)
            return;
        rebuildId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            rebuildId = 0;
            rebuild();
            return GLib.SOURCE_REMOVE;
        });
    };
    rebuild();
    settings.connect('changed::provider-order', queueRebuild);
    settings.connect('changed::sort-alphabetical', queueRebuild);
    return group;
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

// Browser-cookie import is macOS-only, so on Linux web-backed providers need
// their session cookie pasted by hand. It lives in the CLI's config.json as
// cookieSource "manual" + cookieHeader — the CLI has no verb for it.
const COOKIE_PROVIDERS = {
    opencodego: {
        site: 'https://opencode.ai',
        cookie: 'auth',
        valueHint: 'a long string starting with <tt>Fe26.2**</tt>',
        without: 'Without it, bars are estimated from local OpenCode history against ' +
            'the plan’s dollar caps ($12 / 5 h, $30 / week, $60 / month) and miss ' +
            'usage from other machines.',
    },
    opencode: {
        site: 'https://opencode.ai',
        cookie: 'auth',
        valueHint: 'a long string starting with <tt>Fe26.2**</tt>',
        without: 'Without it, bars are estimated from local OpenCode history.',
    },
};

function configPath() {
    return GLib.build_filenamev([GLib.get_user_config_dir(), 'codexbar', 'config.json']);
}

function readConfig() {
    const [, bytes] = GLib.file_get_contents(configPath());
    return JSON.parse(new TextDecoder().decode(bytes));
}

function configEntry(config, id) {
    return config.providers?.find(p => p.id === id) ?? null;
}

// Accepts the bare value, "auth=…", or a whole Cookie header; the CLI keeps
// only the named cookie. Returns null for empty input.
function normalizeCookie(text, name) {
    const t = text.trim().replace(/^cookie:\s*/i, '');
    if (!t)
        return null;
    const asHeader = new RegExp(`(^|;\\s*)(__Host-)?${name}=`);
    return asHeader.test(t) ? t : `${name}=${t}`;
}

// null header removes the cookie (back to browser/auto behavior).
function writeCookie(id, header) {
    const config = readConfig();
    const entry = configEntry(config, id);
    if (!entry)
        throw new Error(`${id} is not in the codexbar config`);
    if (header) {
        entry.cookieSource = 'manual';
        entry.cookieHeader = header;
    } else {
        delete entry.cookieSource;
        delete entry.cookieHeader;
    }
    // 0600: the file now holds a session credential. The mode argument only
    // applies to new files, so tighten an existing one explicitly.
    GLib.file_set_contents_full(configPath(),
        new TextEncoder().encode(`${JSON.stringify(config, null, 2)}\n`),
        GLib.FileSetContentsFlags.CONSISTENT, 0o600);
    GLib.chmod(configPath(), 0o600);
}

// Which source the CLI actually used: "web" means the cookie worked; auto
// mode falls back to "local" estimates when it's missing or rejected.
function checkSource(binary, id, cb) {
    try {
        const proc = Gio.Subprocess.new(
            [binary, 'usage', '--provider', id, '--json'],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        proc.communicate_utf8_async(null, null, (p, res) => {
            try {
                const [, out] = p.communicate_utf8_finish(res);
                const row = JSON.parse(out.slice(out.indexOf('[')))[0];
                const error = row?.error?.message ?? (typeof row?.error === 'string' ? row.error : null);
                cb(row?.source ?? null, error);
            } catch {
                cb(null, null);
            }
        });
    } catch {
        cb(null, null);
    }
}

export default class UsageBarPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        // Our own symbolic icons (Machine Sync page), looked up by name.
        const iconTheme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
        const iconDir = this.dir.get_child('icons').get_path();
        if (!iconTheme.get_search_path().includes(iconDir))
            iconTheme.add_search_path(iconDir);

        // --- General ---
        const general = new Adw.PreferencesPage({
            title: 'General',
            icon_name: 'preferences-system-symbolic',
        });

        const appearance = new Adw.PreferencesGroup({
            title: 'Appearance',
            description: 'Choose how UsageBar fits your desktop.',
        });
        const themeRow = new Adw.ComboRow({
            title: 'Theme',
            subtitle: 'System follows the GNOME Shell colors',
            model: Gtk.StringList.new(['CodexBar dark', 'System']),
        });
        const THEMES = ['codexbar', 'system'];
        themeRow.selected = Math.max(0, THEMES.indexOf(settings.get_string('app-theme')));
        themeRow.connect('notify::selected', () => {
            settings.set_string('app-theme', THEMES[themeRow.selected]);
        });
        appearance.add(themeRow);
        general.add(appearance);

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
        behavior.add(switchRow(settings, 'update-check-enabled', 'Check for UsageBar updates',
            'Download verified releases from GitHub and offer to install them'));
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
        const enabledInConfigOrder = providers.filter(p => p.enabled);
        const enabled = [...enabledInConfigOrder].sort(byName);
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
        page.add(providerOrderGroup(settings, enabledInConfigOrder));

        const costChart = new Adw.PreferencesGroup({
            title: 'Cost chart',
            description: 'Plot up to four eligible providers. When more are enabled, ' +
                'the providers with the highest cost appear.',
        });
        for (const {id, name} of enabled) {
            costChart.add(strvMemberRow(settings, 'hidden-cost-chart-providers', id, {
                title: name,
                subtitle: 'Show when cost data is available',
            }));
        }
        page.add(costChart);

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
            if (COOKIE_PROVIDERS[id])
                group.add(this._cookieRow(binary, id));
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
            group.add(modelsExpanderRow(settings, id));
            page.add(group);
        }
        window.add(page);

        // --- Machine Sync ---
        window.add(new MachineSyncPage(window, binary, settings).page);
    }

    // Paste-a-cookie section for web-backed providers, with step-by-step
    // instructions and a live check of whether the CLI accepted it. The
    // extension picks changes up itself (it watches config.json).
    _cookieRow(binary, id) {
        const spec = COOKIE_PROVIDERS[id];
        const host = GLib.Uri.parse(spec.site, GLib.UriFlags.NONE).get_host();
        // Plain text: the subtitle can carry CLI error messages.
        const expander = new Adw.ExpanderRow({title: `Exact usage from ${host}`, use_markup: false});
        let alive = true;
        expander.connect('destroy', () => {
            alive = false;
        });

        const savedCookie = () => {
            try {
                return configEntry(readConfig(), id)?.cookieHeader ?? null;
            } catch {
                return null;
            }
        };
        const refreshStatus = () => {
            if (!savedCookie()) {
                expander.subtitle = 'Off — bars are estimates from local history';
                return;
            }
            if (!binary) {
                expander.subtitle = 'Cookie saved';
                return;
            }
            expander.subtitle = 'Checking the saved cookie…';
            checkSource(binary, id, (source, error) => {
                if (!alive)
                    return;
                expander.subtitle = source === 'web'
                    ? `Working — bars show exact usage from ${host}`
                    : `Cookie not accepted${error ? ` (${error})` : ''} — it may have ` +
                      'expired; paste a fresh one';
            });
        };

        const help = new Gtk.Label({
            label: `Browser cookie import only works on macOS, so on Linux paste your ${host} ` +
                'login cookie here.\n\n' +
                `1. Sign in at <a href="${spec.site}">${host}</a> in your browser.\n` +
                '2. Open developer tools (F12 or Ctrl+Shift+I).\n' +
                `3. Chrome / Edge: <b>Application</b> tab → Storage → Cookies → ${spec.site}\n` +
                `    Firefox: <b>Storage</b> tab → Cookies → ${spec.site}\n` +
                `4. Find the cookie named <b>${spec.cookie}</b> and copy its Value ` +
                `(${spec.valueHint}).\n` +
                '5. Paste it below and press Enter.\n\n' +
                'It’s saved to ~/.config/codexbar/config.json, readable only by you. ' +
                `Signing out of ${host} invalidates it — if the status above says it’s ` +
                `not accepted, repeat these steps.\n\n${spec.without}`,
            use_markup: true,
            wrap: true,
            xalign: 0,
            selectable: true,
            margin_top: 12,
            margin_bottom: 12,
            margin_start: 12,
            margin_end: 12,
        });
        expander.add_row(new Gtk.ListBoxRow({child: help, activatable: false}));

        const openRow = new Adw.ActionRow({
            title: `Open ${host}`,
            subtitle: 'Sign in there first',
            activatable: true,
        });
        openRow.add_suffix(new Gtk.Image({icon_name: 'adw-external-link-symbolic'}));
        openRow.connect('activated', () => Gio.AppInfo.launch_default_for_uri(spec.site, null));
        expander.add_row(openRow);

        const entry = new Adw.PasswordEntryRow({
            title: `Paste the “${spec.cookie}” cookie value`,
            show_apply_button: true,
        });
        entry.connect('apply', () => {
            const header = normalizeCookie(entry.text, spec.cookie);
            if (!header) {
                entry.add_css_class('error');
                return;
            }
            try {
                writeCookie(id, header);
                entry.remove_css_class('error');
                entry.text = '';
                refreshStatus();
            } catch (e) {
                entry.add_css_class('error');
                expander.subtitle = `Couldn’t save: ${e.message}`;
            }
        });
        expander.add_row(entry);

        const removeRow = new Adw.ActionRow({title: 'Remove saved cookie'});
        const removeBtn = new Gtk.Button({
            label: 'Remove',
            valign: Gtk.Align.CENTER,
            css_classes: ['destructive-action'],
        });
        removeBtn.connect('clicked', () => {
            try {
                writeCookie(id, null);
                refreshStatus();
            } catch (e) {
                expander.subtitle = `Couldn’t remove: ${e.message}`;
            }
        });
        removeRow.add_suffix(removeBtn);
        expander.add_row(removeRow);

        expander.expanded = !savedCookie(); // show the steps until it's set up
        refreshStatus();
        return expander;
    }

    // Enable/disable switch backed by `codexbar config enable|disable`;
    // reverts on failure. The extension notices success by itself — it
    // watches the CLI's config.json for changes.
    _providerToggleRow(binary, provider) {
        // CLI display names are plain text ("ai&").
        const row = plainSwitchRow(provider.name, provider.id, {
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
