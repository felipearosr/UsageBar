// CodexBar Tray — extension preferences (opened from the popover's
// Settings item or `gnome-extensions prefs`). Mirrors the macOS app's
// Preferences shape: General / Notifications / per-provider sections.

import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

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

function enabledProviders() {
    const fallback = [
        {id: 'codex', name: 'Codex'},
        {id: 'claude', name: 'Claude'},
    ];
    const binary = findBinary();
    if (!binary)
        return fallback;
    try {
        const proc = Gio.Subprocess.new(
            [binary, 'config', 'providers', '--format', 'json'],
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        const [, out] = proc.communicate_utf8(null, null);
        const list = JSON.parse(out)
            .filter(p => p.enabled)
            .map(p => ({id: p.provider, name: p.displayName}));
        return list.length ? list : fallback;
    } catch {
        return fallback;
    }
}

function spinRow(settings, key, title, subtitle) {
    const row = new Adw.SpinRow({
        title,
        subtitle,
        adjustment: new Gtk.Adjustment({
            lower: 1,
            upper: 100,
            step_increment: 1,
            page_increment: 10,
        }),
    });
    settings.bind(key, row, 'value', Gio.SettingsBindFlags.DEFAULT);
    return row;
}

export default class CodexBarPreferences extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();

        // --- General ---
        const general = new Adw.PreferencesPage({
            title: 'General',
            icon_name: 'preferences-system-symbolic',
        });
        const thresholds = new Adw.PreferencesGroup({
            title: 'Severity thresholds',
            description: 'Usage percent at which bars and panel chips change color.',
        });
        thresholds.add(spinRow(settings, 'warn-threshold',
            'Warn above', 'Yellow from this percent up'));
        thresholds.add(spinRow(settings, 'crit-threshold',
            'Critical above', 'Red from this percent up'));
        general.add(thresholds);
        window.add(general);

        // --- Notifications ---
        const notifications = new Adw.PreferencesPage({
            title: 'Notifications',
            icon_name: 'preferences-system-notifications-symbolic',
        });
        const quota = new Adw.PreferencesGroup({
            title: 'Quota warnings',
            description: 'Notify when a rate window crosses a threshold, once per reset cycle.',
        });
        const enabledRow = new Adw.SwitchRow({title: 'Notify on high usage'});
        settings.bind('notify-enabled', enabledRow, 'active', Gio.SettingsBindFlags.DEFAULT);
        quota.add(enabledRow);
        for (const row of [
            spinRow(settings, 'notify-warn-percent',
                'First notification at', 'Percent used'),
            spinRow(settings, 'notify-crit-percent',
                'Critical notification at', 'A second, escalated notification'),
        ]) {
            settings.bind('notify-enabled', row, 'sensitive', Gio.SettingsBindFlags.GET);
            quota.add(row);
        }
        notifications.add(quota);
        window.add(notifications);

        // --- Providers ---
        const providers = new Adw.PreferencesPage({
            title: 'Providers',
            icon_name: 'network-server-symbolic',
        });
        for (const {id, name} of enabledProviders()) {
            const group = new Adw.PreferencesGroup({title: name});
            const hidden = new Set(settings.get_strv('hidden-chips'));
            const chipRow = new Adw.SwitchRow({
                title: 'Show panel chip',
                subtitle: 'The popover card stays either way',
                active: !hidden.has(id),
            });
            chipRow.connect('notify::active', () => {
                const h = new Set(settings.get_strv('hidden-chips'));
                if (chipRow.active)
                    h.delete(id);
                else
                    h.add(id);
                settings.set_strv('hidden-chips', [...h].sort());
            });
            group.add(chipRow);
            providers.add(group);
        }
        window.add(providers);
    }
}
