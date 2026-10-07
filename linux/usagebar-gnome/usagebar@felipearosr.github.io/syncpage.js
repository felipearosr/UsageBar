// Machine Sync page of the preferences window. Every action runs a
// `codexbar sync …` command (see syncprefs.js for the invocations and the
// plain-language errors), so the app, the CLI, and this page share one
// `sync.json`. The running extension notices pairing changes on its next
// GET /sync/status poll.
//
// The Pairing Link is a secret: it goes to the CLI on stdin, is shown only in
// the dialog that offers to copy it, and is never logged.

import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Gtk from 'gi://Gtk';
import Pango from 'gi://Pango';

import {needsCliNote} from './clicompat.js';
import {hexColor} from './modelprefs.js';
import {
    CLI_WITHOUT_SYNC,
    canCreate,
    cleartextHost,
    cleartextWarning,
    colorMachines,
    createArgs,
    createdText,
    forgetArgs,
    forgetWarning,
    friendlyError,
    hourLabels,
    infoArgs,
    LEAVE_WARNING,
    leaveArgs,
    linkArgs,
    otherMachines,
    pairArgs,
    pairedText,
    pairStdin,
    parseResult,
    pushArgs,
    pushText,
    RECOVERY_GUIDANCE,
    renameArgs,
    reportingDaySummary,
    retireArgs,
    serverSummary,
    settingsArgs,
    statusArgs,
    timeZoneChoices,
    tokenField,
} from './syncprefs.js';

const INFO_DEBOUNCE_MS = 700;

// Adw.ButtonRow needs libadwaita 1.6; GNOME 46 (Ubuntu 24.04) ships 1.5, where
// an activatable ActionRow stands in and emits the same `activated` signal.
function buttonRow(props) {
    if (Adw.ButtonRow)
        return new Adw.ButtonRow(props);
    return new Adw.ActionRow({...props, activatable: true});
}

// Runs `binary args…` and resolves with syncprefs.parseResult's shape. stdin
// is always a pipe (closed when `stdin` is null) so nothing can prompt.
// stderr is read only to recognise a CLI without `codexbar sync`.
export function runSync(binary, args, stdin = null) {
    return new Promise(resolve => {
        let proc;
        try {
            proc = Gio.Subprocess.new([binary, ...args],
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            resolve({ok: false, reason: null, message: e.message});
            return;
        }
        proc.communicate_utf8_async(stdin, null, (p, res) => {
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(res);
                resolve(parseResult({success: p.get_successful(), stdout, stderr}));
            } catch (e) {
                resolve({ok: false, reason: null, message: e.message});
            }
        });
    });
}

function zoneTab() {
    try {
        const [, bytes] = GLib.file_get_contents('/usr/share/zoneinfo/zone1970.tab');
        return new TextDecoder().decode(bytes);
    } catch {
        return '';
    }
}

function copyText(widget, text) {
    const value = new GObject.Value();
    value.init(GObject.TYPE_STRING);
    value.set_string(text);
    widget.get_clipboard().set_content(Gdk.ContentProvider.new_for_value(value));
}

export class MachineSyncPage {
    constructor(window, binary, settings = null) {
        this._window = window;
        this._binary = binary;
        this._gsettings = settings; // extension GSettings (machine colors)
        this._statusListeners = [];
        this._groups = [];
        this._alive = true;
        this._infoTimer = 0;
        this.page = new Adw.PreferencesPage({
            title: 'Machine Sync',
            icon_name: 'usagebar-machines-symbolic',
        });
        this.page.connect('destroy', () => {
            this._alive = false;
            this._disconnectColors();
            if (this._infoTimer)
                GLib.source_remove(this._infoTimer);
            this._infoTimer = 0;
        });
        this.reload();
    }

    // ---------- plumbing ----------

    _run(args, stdin = null) {
        return runSync(this._binary, args, stdin);
    }

    _setGroups(groups) {
        if (this._infoTimer)
            GLib.source_remove(this._infoTimer);
        this._infoTimer = 0;
        this._disconnectColors();
        for (const group of this._groups)
            this.page.remove(group);
        this._groups = groups;
        for (const group of groups) {
            this.page.add(group);
            group._usagebarAttach?.();
        }
    }

    _toast(title) {
        if (this._alive)
            this._window.add_toast(new Adw.Toast({title, timeout: 4, use_markup: false}));
    }

    _alert(heading, body) {
        if (!this._alive)
            return;
        const dialog = new Adw.AlertDialog({heading, body});
        dialog.add_response('close', 'Close');
        dialog.present(this._window);
    }

    _failed(heading, result) {
        this._alert(heading, friendlyError(result));
    }

    // Resolves true when the user picked `confirmLabel`.
    _confirm(heading, body, confirmLabel, {destructive = true} = {}) {
        return new Promise(resolve => {
            const dialog = new Adw.AlertDialog({heading, body});
            dialog.add_response('cancel', 'Cancel');
            dialog.add_response('confirm', confirmLabel);
            dialog.set_response_appearance('confirm', destructive
                ? Adw.ResponseAppearance.DESTRUCTIVE : Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = 'cancel';
            dialog.close_response = 'cancel';
            dialog.connect('response', (_d, response) => resolve(response === 'confirm'));
            dialog.present(this._window);
        });
    }

    // The link and how to keep it, with a Copy button. `link` lives only in
    // this dialog's label.
    _showLink(link, heading = 'Pairing Link') {
        const label = new Gtk.Label({
            label: link,
            selectable: true,
            wrap: true,
            wrap_mode: Pango.WrapMode.CHAR, // the key has no spaces
            xalign: 0,
            css_classes: ['monospace', 'card'],
            margin_top: 6,
        });
        const dialog = new Adw.AlertDialog({heading, body: RECOVERY_GUIDANCE, extra_child: label});
        dialog.add_response('close', 'Close');
        dialog.add_response('copy', 'Copy');
        dialog.set_response_appearance('copy', Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = 'copy';
        dialog.close_response = 'close';
        dialog.connect('response', (_d, response) => {
            if (response === 'copy')
                this._copyLink(link);
        });
        dialog.present(this._window);
    }

    _copyLink(link) {
        copyText(this._window, link);
        this._toast('Pairing Link copied. Paste it somewhere safe.');
    }

    async _withLink(action) {
        const result = await this._run(linkArgs());
        if (!this._alive)
            return;
        if (!result.ok) {
            this._failed('Couldn’t read the Pairing Link', result);
            return;
        }
        action(result.data.pairingLink);
    }

    // ---------- state ----------

    async reload() {
        if (!this._binary) {
            this._setGroups([new Adw.PreferencesGroup({
                title: 'Machine Sync',
                description: 'codexbar CLI not found — install it to use Machine Sync.',
            })]);
            return;
        }
        const result = await this._run(settingsArgs());
        if (!this._alive)
            return;
        if (result.reason === CLI_WITHOUT_SYNC) {
            this._setGroups([this._needsCliGroup()]);
            return;
        }
        if (!result.ok) {
            this._setGroups([new Adw.PreferencesGroup({
                title: 'Machine Sync',
                description: `Couldn’t read the Machine Sync settings: ${friendlyError(result)}`,
            })]);
            return;
        }
        this._settings = result.data;
        if (this._settings.paired)
            this._renderPaired();
        else
            this._renderUnpaired();
    }

    // Upstream's CLI has no `codexbar sync`: say so instead of showing the
    // pairing UI, and link to the install page.
    _needsCliGroup() {
        const note = needsCliNote('machineSync');
        const group = new Adw.PreferencesGroup({title: note.title, description: note.body});
        const install = new Gtk.Button({label: note.button, valign: Gtk.Align.CENTER});
        install.connect('clicked', () =>
            new Gtk.UriLauncher({uri: note.url}).launch(this._window, null, null));
        group.header_suffix = install;
        return group;
    }

    // ---------- not paired ----------

    _renderUnpaired() {
        const intro = new Adw.PreferencesGroup({
            title: 'Machine Sync',
            description: 'See the Spend of all your Machines in one place. Each Machine ' +
                'uploads its own Spend to a Sync Server you choose, end-to-end encrypted so ' +
                'the server can’t read it. Start a Sync Group here, or join one you started ' +
                'on another Machine.',
        });
        const nameRow = new Adw.EntryRow({title: 'Name of this Machine (optional)'});
        nameRow.text = this._settings.displayName ?? '';
        intro.add(nameRow);

        this._setGroups([intro, this._createGroup(nameRow), this._joinGroup(nameRow)]);
    }

    _createGroup(nameRow) {
        const group = new Adw.PreferencesGroup({
            title: 'Create a Sync Group',
            description: 'Enter the address of a Sync Server you run yourself, or one whose ' +
                'operator gave you access.',
        });
        const serverRow = new Adw.EntryRow({title: 'Sync Server URL', show_apply_button: true});
        serverRow.input_purpose = Gtk.InputPurpose.URL;
        const infoRow = new Adw.ActionRow({title: 'Server', visible: false, use_markup: false});
        const tokenRow = new Adw.PasswordEntryRow({title: 'Enrollment Token', visible: false});
        const createRow = buttonRow({title: 'Create Sync Group', sensitive: false});
        createRow.add_css_class('suggested-action');
        for (const row of [serverRow, infoRow, tokenRow, createRow])
            group.add(row);

        let info = null;
        let checkSeq = 0;
        let busy = false;
        const update = () => {
            const field = tokenField(info);
            tokenRow.visible = field.visible;
            tokenRow.title = field.required ? 'Enrollment Token' : 'Enrollment Token (optional)';
            createRow.sensitive = !busy && canCreate({info, token: tokenRow.text});
        };
        const check = async () => {
            const server = serverRow.text.trim();
            const seq = ++checkSeq;
            info = null;
            update();
            if (!server) {
                infoRow.visible = false;
                return;
            }
            infoRow.visible = true;
            infoRow.subtitle = 'Asking the server…';
            const result = await this._run(infoArgs(server));
            if (!this._alive || seq !== checkSeq)
                return;
            if (result.ok) {
                info = result.data;
                infoRow.subtitle = serverSummary(info);
                serverRow.remove_css_class('error');
            } else {
                infoRow.subtitle = friendlyError(result);
                serverRow.add_css_class('error');
            }
            update();
        };
        serverRow.connect('changed', () => {
            info = null;
            checkSeq++;
            update();
            if (this._infoTimer)
                GLib.source_remove(this._infoTimer);
            this._infoTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, INFO_DEBOUNCE_MS, () => {
                this._infoTimer = 0;
                check();
                return GLib.SOURCE_REMOVE;
            });
        });
        serverRow.connect('apply', () => check());
        tokenRow.connect('changed', update);

        createRow.connect('activated', async () => {
            if (!info || busy)
                return;
            if (info.cleartextWarning && !await this._confirm('Use plain http://?',
                cleartextWarning(info.host), 'Use http://'))
                return;
            busy = true;
            createRow.title = 'Creating…';
            update();
            const result = await this._run(createArgs({
                server: serverRow.text,
                token: tokenField(info).visible ? tokenRow.text : '',
                name: nameRow.text,
                allowCleartext: info.cleartextWarning,
            }));
            if (!this._alive)
                return;
            busy = false;
            createRow.title = 'Create Sync Group';
            update();
            if (!result.ok) {
                this._failed('Couldn’t create the Sync Group', result);
                return;
            }
            this._toast(createdText(result.data));
            this._showLink(result.data.pairingLink, 'Save your Pairing Link');
            this.reload();
        });
        return group;
    }

    _joinGroup(nameRow) {
        const group = new Adw.PreferencesGroup({
            title: 'Join a Sync Group',
            description: 'Paste the Pairing Link from a Machine that is already in the group. ' +
                'There, open these settings and use Pairing Link → Copy, or run ' +
                '“codexbar sync link”.',
        });
        const linkRow = new Adw.PasswordEntryRow({title: 'Pairing Link'});
        const joinRow = buttonRow({title: 'Join Sync Group', sensitive: false});
        group.add(linkRow);
        group.add(joinRow);
        let busy = false;
        linkRow.connect('changed', () => {
            joinRow.sensitive = !busy && linkRow.text.trim().length > 0;
        });

        const join = async allowCleartext => {
            busy = true;
            joinRow.sensitive = false;
            joinRow.title = 'Joining…';
            const link = linkRow.text;
            const result = await this._run(pairArgs({name: nameRow.text, allowCleartext}),
                pairStdin(link));
            if (!this._alive)
                return;
            busy = false;
            joinRow.title = 'Join Sync Group';
            joinRow.sensitive = linkRow.text.trim().length > 0;
            if (!result.ok && result.reason === 'cleartext_not_confirmed' && !allowCleartext) {
                const host = cleartextHost(link) ?? 'the server';
                if (await this._confirm('Use plain http://?', cleartextWarning(host), 'Use http://'))
                    join(true);
                return;
            }
            if (!result.ok) {
                linkRow.add_css_class('error');
                this._failed('Couldn’t join the Sync Group', result);
                return;
            }
            linkRow.text = '';
            this._toast(pairedText(result.data));
            this.reload();
        };
        joinRow.connect('activated', () => {
            if (!busy && linkRow.text.trim())
                join(false);
        });
        linkRow.connect('entry-activated', () => {
            if (!busy && linkRow.text.trim())
                join(false);
        });
        return group;
    }

    // ---------- paired ----------

    _renderPaired() {
        this._setGroups([
            this._syncGroupGroup(),
            this._thisMachineGroup(),
            this._reportingDayGroup(),
            this._otherMachinesGroup(),
            ...(this._gsettings ? [this._machineColorsGroup()] : []),
            this._leaveGroup(),
        ]);
    }

    _syncGroupGroup() {
        const group = new Adw.PreferencesGroup({
            title: 'Sync Group',
            description: 'This Machine shares its Spend with the other Machines in this group.',
        });
        const serverRow = new Adw.ActionRow({
            title: 'Sync Server',
            subtitle: this._settings.server ?? '',
            subtitle_selectable: true,
            use_markup: false,
        });
        group.add(serverRow);

        const linkRow = new Adw.ActionRow({
            title: 'Pairing Link',
            subtitle: 'Joins another Machine to this group, and is your only recovery key. ' +
                'Keep it somewhere safe.',
        });
        const show = new Gtk.Button({label: 'Show', valign: Gtk.Align.CENTER});
        show.connect('clicked', () => this._withLink(link => this._showLink(link)));
        const copy = new Gtk.Button({
            icon_name: 'edit-copy-symbolic',
            tooltip_text: 'Copy the Pairing Link',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
        });
        copy.connect('clicked', () => this._withLink(link => this._copyLink(link)));
        linkRow.add_suffix(show);
        linkRow.add_suffix(copy);
        group.add(linkRow);

        const pushRow = new Adw.ActionRow({
            title: 'Sync now',
            subtitle: 'UsageBar syncs about every 2½ minutes on its own',
        });
        const pushButton = new Gtk.Button({label: 'Sync', valign: Gtk.Align.CENTER});
        pushButton.connect('clicked', async () => {
            pushButton.sensitive = false;
            const result = await this._run(pushArgs());
            if (!this._alive)
                return;
            pushButton.sensitive = true;
            if (result.ok)
                this._toast(pushText(result.data));
            else
                this._failed('Couldn’t sync', result);
        });
        pushRow.add_suffix(pushButton);
        group.add(pushRow);
        return group;
    }

    _thisMachineGroup() {
        const group = new Adw.PreferencesGroup({
            title: 'This Machine',
            description: 'The name other Machines see for this one.',
        });
        const nameRow = new Adw.EntryRow({title: 'Name', show_apply_button: true});
        nameRow.text = this._settings.displayName ?? '';
        nameRow.connect('apply', async () => {
            const name = nameRow.text.trim();
            if (!name) {
                nameRow.add_css_class('error');
                return;
            }
            nameRow.remove_css_class('error');
            nameRow.sensitive = false;
            const result = await this._run(renameArgs(name));
            if (!this._alive)
                return;
            nameRow.sensitive = true;
            if (!result.ok) {
                this._failed('Couldn’t rename this Machine', result);
                return;
            }
            this._settings.displayName = result.data.displayName;
            this._toast(result.data.pushError
                ? `Renamed. Other Machines see it after the next sync: ${friendlyError({
                    reason: result.data.pushErrorReason, message: result.data.pushError})}`
                : `This Machine is now “${result.data.displayName}”.`);
        });
        group.add(nameRow);
        return group;
    }

    _reportingDayGroup() {
        const day = this._settings.reportingDay;
        const group = new Adw.PreferencesGroup({
            title: 'Reporting Day',
            description: 'How the Machines tab splits Spend into days. Machines in other ' +
                'timezones are shown in yours.',
        });
        const zones = timeZoneChoices(zoneTab(), day.timeZone);
        const systemLabel = `System (${day.effectiveTimeZone})`;
        const zoneRow = new Adw.ComboRow({
            title: 'Timezone',
            model: Gtk.StringList.new([systemLabel, ...zones]),
            enable_search: true,
            expression: Gtk.PropertyExpression.new(Gtk.StringObject, null, 'string'),
            use_markup: false,
        });
        zoneRow.selected = day.timeZone ? zones.indexOf(day.timeZone) + 1 : 0;
        const hourRow = new Adw.ComboRow({
            title: 'Day starts at',
            model: Gtk.StringList.new(hourLabels()),
        });
        hourRow.selected = day.startHour;
        group.add(zoneRow);
        group.add(hourRow);

        let saved = {zone: zoneRow.selected, hour: hourRow.selected};
        let reverting = false;
        const save = async () => {
            if (reverting)
                return;
            const timeZone = zoneRow.selected === 0 ? null : zones[zoneRow.selected - 1];
            const result = await this._run(settingsArgs({timeZone, startHour: hourRow.selected}));
            if (!this._alive)
                return;
            if (result.ok) {
                saved = {zone: zoneRow.selected, hour: hourRow.selected};
                this._settings.reportingDay = result.data.reportingDay;
                group.description = 'How the Machines tab splits Spend into days. ' +
                    `${reportingDaySummary(result.data.reportingDay)}.`;
                return;
            }
            reverting = true;
            zoneRow.selected = saved.zone;
            hourRow.selected = saved.hour;
            reverting = false;
            this._failed('Couldn’t save the Reporting Day', result);
        };
        zoneRow.connect('notify::selected', save);
        hourRow.connect('notify::selected', save);
        return group;
    }

    _otherMachinesGroup() {
        const group = new Adw.PreferencesGroup({
            title: 'Other Machines',
            description: 'Retire a Machine you replaced: its Spend stays in the totals, but ' +
                'it no longer shows as active. Forget deletes its Spend from the Sync Server.',
        });
        const refresh = new Gtk.Button({
            icon_name: 'view-refresh-symbolic',
            tooltip_text: 'Reload from the Sync Server',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
        });
        group.header_suffix = refresh;

        let rows = [];
        const setRows = newRows => {
            for (const row of rows)
                group.remove(row);
            rows = newRows;
            for (const row of rows)
                group.add(row);
        };
        const load = async () => {
            refresh.sensitive = false;
            setRows([new Adw.ActionRow({title: 'Loading…'})]);
            const result = await this._run(statusArgs());
            if (!this._alive)
                return;
            refresh.sensitive = true;
            if (!result.ok) {
                setRows([new Adw.ActionRow({
                    title: 'Couldn’t load the Machines',
                    subtitle: friendlyError(result),
                    use_markup: false,
                })]);
                return;
            }
            for (const listener of this._statusListeners)
                listener(result.data);
            const machines = otherMachines(result.data);
            if (!machines.length) {
                setRows([new Adw.ActionRow({
                    title: 'No other Machines yet',
                    subtitle: 'Join another Machine with the Pairing Link',
                })]);
                return;
            }
            setRows(machines.map(machine => this._machineRow(machine, load)));
        };
        refresh.connect('clicked', load);
        load();
        return group;
    }

    // One color button per Machine, this one included, for the Machines
    // tab's summary bar, chart and legend. Filled from the status the Other
    // Machines group loads, so its reload button refreshes both.
    _machineColorsGroup() {
        const settings = this._gsettings;
        const group = new Adw.PreferencesGroup({
            title: 'Machine Colors',
            description: 'How each Machine is colored on the Machines tab.',
        });
        const reset = new Gtk.Button({
            label: 'Reset',
            tooltip_text: 'Back to the default colors',
            valign: Gtk.Align.CENTER,
            css_classes: ['flat'],
        });
        reset.connect('clicked', () => settings.set_value('machine-colors', new GLib.Variant('a{ss}', {})));
        group.header_suffix = reset;

        const overrides = () => settings.get_value('machine-colors').deepUnpack();
        let status = null;
        let rows = [];
        const buttons = new Map();
        let syncing = false;
        const syncColors = () => {
            const current = overrides();
            reset.sensitive = Object.keys(current).length > 0;
            syncing = true;
            for (const machine of colorMachines(status, current)) {
                const button = buttons.get(machine.machineId);
                const rgba = new Gdk.RGBA();
                if (button && rgba.parse(machine.color) && !rgba.equal(button.rgba))
                    button.rgba = rgba;
            }
            syncing = false;
        };
        const build = data => {
            status = data;
            for (const row of rows)
                group.remove(row);
            buttons.clear();
            rows = colorMachines(status, overrides()).map(machine => {
                const row = new Adw.ActionRow({title: machine.label, use_markup: false});
                const button = new Gtk.ColorDialogButton({
                    dialog: new Gtk.ColorDialog({title: `Color for ${machine.label}`, with_alpha: false}),
                    valign: Gtk.Align.CENTER,
                    tooltip_text: 'Machine color',
                });
                button.connect('notify::rgba', () => {
                    if (!syncing) {
                        settings.set_value('machine-colors', new GLib.Variant('a{ss}',
                            {...overrides(), [machine.machineId]: hexColor(button.rgba)}));
                    }
                });
                buttons.set(machine.machineId, button);
                row.add_suffix(button);
                row.activatable_widget = button;
                group.add(row);
                return row;
            });
            syncColors();
        };
        build(null);
        // Hooked up by _setGroups once the previous page's group is gone.
        group._usagebarAttach = () => {
            this._statusListeners.push(build);
            this._colorsChangedId = settings.connect('changed::machine-colors', syncColors);
        };
        return group;
    }

    // The Machine Colors group is rebuilt with the page's groups; drop the
    // old one's listeners first.
    _disconnectColors() {
        this._statusListeners = [];
        if (this._colorsChangedId)
            this._gsettings?.disconnect(this._colorsChangedId);
        this._colorsChangedId = 0;
    }

    _machineRow(machine, reload) {
        const row = new Adw.ActionRow({
            title: machine.label,
            subtitle: machine.retired ? 'Retired' : machine.active ? 'Active' : 'Not active',
            use_markup: false,
        });
        const act = async (args, heading, done) => {
            row.sensitive = false;
            const result = await this._run(args);
            if (!this._alive)
                return;
            row.sensitive = true;
            if (!result.ok) {
                this._failed(heading, result);
                return;
            }
            this._toast(done);
            reload();
        };
        if (!machine.retired) {
            const retire = new Gtk.Button({label: 'Retire', valign: Gtk.Align.CENTER});
            retire.connect('clicked', () => act(retireArgs(machine.machineId),
                `Couldn’t retire ${machine.label}`, `Retired ${machine.label}.`));
            row.add_suffix(retire);
        }
        const forget = new Gtk.Button({
            label: 'Forget',
            valign: Gtk.Align.CENTER,
            css_classes: ['destructive-action'],
        });
        forget.connect('clicked', async () => {
            if (await this._confirm(`Forget ${machine.label}?`, forgetWarning(machine.label), 'Forget'))
                act(forgetArgs(machine.machineId), `Couldn’t forget ${machine.label}`,
                    `Forgot ${machine.label}.`);
        });
        row.add_suffix(forget);
        return row;
    }

    _leaveGroup() {
        const group = new Adw.PreferencesGroup();
        const leaveRow = buttonRow({title: 'Leave Sync Group'});
        leaveRow.add_css_class('destructive-action');
        leaveRow.connect('activated', async () => {
            if (!await this._confirm('Leave the Sync Group?', LEAVE_WARNING, 'Leave'))
                return;
            leaveRow.sensitive = false;
            const result = await this._run(leaveArgs());
            if (!this._alive)
                return;
            leaveRow.sensitive = true;
            if (!result.ok) {
                this._failed('Couldn’t leave the Sync Group', result);
                return;
            }
            this._toast('This Machine left the Sync Group. Its Spend stays on the server.');
            this.reload();
        });
        group.add(leaveRow);
        return group;
    }
}
