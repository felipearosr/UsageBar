// Screenshot driver for the website. capture-screenshots.sh loads it next to
// UsageBar in a headless GNOME Shell of its own; it opens each surface, saves
// a full-stage PNG to $USAGEBAR_SHOTS_OUT, and records where the popover or
// window sits so the script can crop it.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const USAGEBAR = 'usagebar@felipearosr.github.io';
const DISPLAY_CONFIG = ['org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
    'org.gnome.Mutter.DisplayConfig'];

const sleep = ms => new Promise(resolve => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
    resolve();
    return GLib.SOURCE_REMOVE;
}));

function descendants(actor) {
    return actor.get_children().flatMap(child => [child, ...descendants(child)]);
}

function call(method, params, replyType) {
    return new Promise((resolve, reject) => {
        Gio.DBus.session.call(...DISPLAY_CONFIG, method, params, replyType,
            Gio.DBusCallFlags.NONE, -1, null, (connection, result) => {
                try {
                    resolve(connection.call_finish(result));
                } catch (error) {
                    reject(error);
                }
            });
    });
}

// Scale the virtual monitor so the screenshots come out at 2x.
async function setScale(scale) {
    const state = await call('GetCurrentState', null, null);
    const [serial, monitors] = state.recursiveUnpack();
    const [[connector], modes] = monitors[0];
    const mode = modes.find(candidate => candidate[6]['is-current']) ?? modes[0];
    await call('ApplyMonitorsConfig', new GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})', [
        serial, 1, [[0, 0, scale, 0, true, [[connector, mode[0], {}]]]], {},
    ]), null);
}

export default class ShotsDriver extends Extension {
    enable() {
        this._out = GLib.getenv('USAGEBAR_SHOTS_OUT');
        if (!this._out)
            return;
        this._bounds = {};
        this._run().catch(error => {
            console.error(`usagebar-shots: ${error.message}\n${error.stack}`);
            GLib.file_set_contents(`${this._out}/error`, `${error.message}\n${error.stack}\n`);
        });
    }

    disable() {
        this._out = null;
    }

    _shot(name, actor = null) {
        if (actor) {
            const [x, y] = actor.get_transformed_position();
            const [width, height] = actor.get_transformed_size();
            this._bounds[name] = {x, y, width, height};
        }
        return new Promise(resolve => {
            const stream = Gio.File.new_for_path(`${this._out}/${name}.png`)
                .replace(null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
            new Shell.Screenshot().screenshot(false, stream, (source, result) => {
                try {
                    source.screenshot_finish(result);
                    stream.close(null);
                } catch (error) {
                    console.error(`usagebar-shots: ${name}: ${error.message}`);
                }
                resolve();
            });
        });
    }

    async _waitFor(what, test, seconds = 30) {
        for (let i = 0; i < seconds * 4; i++) {
            if (test())
                return;
            await sleep(250);
        }
        throw new Error(`timed out waiting for ${what}`);
    }

    async _prefs(name, page) {
        const settings = this._usagebar.getSettings();
        settings.set_string('prefs-page', page);
        const before = new Set(global.get_window_actors());
        Main.extensionManager.openExtensionPrefs(USAGEBAR, '', {});
        let actor = null;
        await this._waitFor('the Settings window', () => {
            actor = global.get_window_actors().find(candidate => !before.has(candidate));
            return !!actor;
        });
        // Wide enough that the page switcher shows every page name. The
        // window only takes a size once it has settled, so ask until it has.
        const [width, height] = [780, 660];
        const x = Math.round((global.stage.width - width) / 2);
        const y = Math.round((global.stage.height - height) / 2) + 12;
        await sleep(1500);
        await this._waitFor('the Settings window to resize', () => {
            if (actor.meta_window.get_frame_rect().width === width)
                return true;
            actor.meta_window.move_resize_frame(false, x, y, width, height);
            return false;
        }, 10);
        await sleep(1500);
        const rect = actor.meta_window.get_frame_rect();
        this._bounds[name] = {x: rect.x, y: rect.y, width: rect.width, height: rect.height};
        await this._shot(name);
        actor.meta_window.delete(global.get_current_time());
        await sleep(800);
    }

    async _run() {
        await this._waitFor('the shell to start', () => !Main.layoutManager._startingUp);
        const scale = Number(GLib.getenv('USAGEBAR_SHOTS_SCALE') || 2);
        if (scale !== 1)
            await setScale(scale);
        await sleep(1500);
        Main.overview.hide();

        const entry = () => Main.extensionManager.lookup(USAGEBAR);
        await this._waitFor('UsageBar to load', () => entry()?.stateObj?._indicator);
        const usagebar = this._usagebar = entry().stateObj;
        const indicator = usagebar._indicator;
        await this._waitFor('usage rows', () => usagebar._rows?.length > 0);
        await this._waitFor('cost reports', () => usagebar._costs?.length >= 2);
        await this._waitFor('Machine Sync', () => usagebar._sync?.payload?.status?.machines?.length > 0);
        await sleep(4000); // provider status pages

        indicator.menu.open();
        await sleep(3000);
        await this._shot('popover-all', indicator.menu.actor);

        usagebar._selectedProvider = 'claude';
        usagebar._render();
        await sleep(1500);
        await this._shot('popover-claude', indicator.menu.actor);
        usagebar._selectedProvider = null;
        usagebar._render();
        await sleep(500);

        // The Spend summary opens the dashboard beside the popover, as a click does.
        const summary = descendants(indicator.menu.actor)
            .find(actor => actor.has_style_class_name?.('usagebar-spend-summary-button'));
        if (!summary)
            throw new Error('no Spend summary in the popover');
        summary.emit('clicked', 1);
        await sleep(2000);
        // The whole screen down to just below the lower of the two.
        const bottom = actor => actor.get_transformed_position()[1] + actor.get_transformed_size()[1];
        await this._shot('desktop');
        this._bounds.desktop = {x: 0, y: 0, width: global.stage.width,
            height: Math.min(global.stage.height,
                Math.max(bottom(indicator._costPanel), bottom(indicator.menu.actor)) + 56)};
        // Then the dashboard on its own, without the popover's edge beside it.
        indicator.menu.actor.opacity = 0;
        await sleep(300);
        await this._shot('cost-dashboard', indicator._costPanel);
        indicator.menu.actor.opacity = 255;
        indicator._closeCostPanel();
        await sleep(500);

        indicator._tabButtons.get('machines').emit('clicked', 1);
        await sleep(2000);
        await this._shot('machines', indicator.menu.actor);
        indicator._tabButtons.get('providers').emit('clicked', 1);
        indicator.menu.close();
        await sleep(800);

        await this._prefs('settings', '');
        await this._prefs('settings-sync', 'sync');

        const themeContext = St.ThemeContext.get_for_stage(global.stage);
        GLib.file_set_contents(`${this._out}/bounds.json`, JSON.stringify({
            scale,
            themeScale: themeContext.scale_factor,
            stage: {width: global.stage.width, height: global.stage.height},
            shots: this._bounds,
        }, null, 2));
        GLib.file_set_contents(`${this._out}/done`, 'ok\n');
    }
}
