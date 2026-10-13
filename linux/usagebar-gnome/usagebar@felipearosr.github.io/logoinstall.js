// Downloads, installs and removes the provider logo pack (see logopack.js).
// Shared by the extension and the preferences window: either can start the
// download, and the logo-pack-version setting each writes tells the other.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup';

import {
    logoPackAsset,
    logoPackUrl,
    MAX_PACK_BYTES,
    parseChecksum,
    parseLogoPack,
    releaseVersion,
} from './logopack.js';

// The release whose pack this install downloads, from metadata.json's
// "version-name", or null for a development checkout. With
// USAGEBAR_LOGO_PACK_BASE_URL (see downloadLogoPack), a checkout can name one
// in USAGEBAR_LOGO_PACK_VERSION to test the download.
export function logoPackVersion(metadata) {
    const own = releaseVersion(metadata?.['version-name']);
    if (own || !GLib.getenv('USAGEBAR_LOGO_PACK_BASE_URL'))
        return own;
    return releaseVersion(GLib.getenv('USAGEBAR_LOGO_PACK_VERSION')?.replaceAll('-', ' '));
}

// Outside the extension directory, which an extension update replaces.
export function logoPackDir() {
    return GLib.build_filenamev([GLib.get_user_data_dir(), 'usagebar', 'icons']);
}

// The installed pack's version, or null when there is none.
export function installedLogoPack() {
    try {
        const [, bytes] = GLib.file_get_contents(GLib.build_filenamev([logoPackDir(), 'VERSION']));
        return new TextDecoder().decode(bytes).trim() || null;
    } catch {
        return null;
    }
}

// Development checkouts and the .deb/.rpm carry the logos in icons/; the
// extensions.gnome.org build doesn't, and USAGEBAR_HIDE_PROVIDER_ICONS=1
// simulates that build.
export function hasBundledLogos(extensionDir) {
    if (GLib.getenv('USAGEBAR_HIDE_PROVIDER_ICONS') === '1')
        return false;
    let children = null;
    try {
        children = extensionDir.get_child('icons').enumerate_children(
            'standard::name', Gio.FileQueryInfoFlags.NONE, null);
        let info;
        while ((info = children.next_file(null))) {
            if (/^ProviderIcon-.+\.svg$/.test(info.get_name()))
                return true;
        }
    } catch {
        // no icons/ directory
    } finally {
        children?.close(null);
    }
    return false;
}

function fetchBytes(session, url, cancellable) {
    return new Promise((resolve, reject) => {
        const msg = Soup.Message.new('GET', url);
        if (!msg) {
            reject(new Error(`bad URL ${url}`));
            return;
        }
        session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, cancellable, (s, res) => {
            try {
                const bytes = s.send_and_read_finish(res);
                if (msg.get_status() !== Soup.Status.OK)
                    throw new Error(`HTTP ${msg.get_status()} for ${GLib.path_get_basename(url)}`);
                resolve(bytes);
            } catch (e) {
                reject(e);
            }
        });
    });
}

// Downloads this release's pack and its .sha256, checks both, and installs
// the logos. USAGEBAR_LOGO_PACK_BASE_URL points the download at another
// directory of release assets, for testing a pack before it is released.
export async function downloadLogoPack(session, version, cancellable = null) {
    const asset = logoPackAsset(version);
    const base = GLib.getenv('USAGEBAR_LOGO_PACK_BASE_URL');
    const url = base ? `${base.replace(/\/+$/, '')}/${asset}` : logoPackUrl(version);
    const [bytes, sumBytes] = await Promise.all([
        fetchBytes(session, url, cancellable),
        fetchBytes(session, `${url}.sha256`, cancellable),
    ]);
    if (bytes.get_size() > MAX_PACK_BYTES)
        throw new Error('the logo pack is too large');
    const decoder = new TextDecoder();
    const expected = parseChecksum(decoder.decode(sumBytes.get_data()), asset);
    if (!expected)
        throw new Error(`${asset}.sha256 isn’t a checksum for ${asset}`);
    if (GLib.compute_checksum_for_bytes(GLib.ChecksumType.SHA256, bytes) !== expected)
        throw new Error('checksum mismatch');
    installLogoPack(parseLogoPack(decoder.decode(bytes.get_data()), version));
}

function deleteDir(path) {
    const dir = Gio.File.new_for_path(path);
    if (!dir.query_exists(null))
        return;
    const children = dir.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
    let info;
    while ((info = children.next_file(null)))
        dir.get_child(info.get_name()).delete(null);
    children.close(null);
    dir.delete(null);
}

// Moves the current pack out of the way; returns where it went, or null.
function moveAside(target) {
    const current = Gio.File.new_for_path(target);
    if (!current.query_exists(null))
        return null;
    const aside = `${target}.old-${GLib.uuid_string_random()}`;
    current.move(Gio.File.new_for_path(aside), Gio.FileCopyFlags.NONE, null, null);
    return aside;
}

// Writes the logos into a fresh directory next to the pack, then swaps it in,
// so a failure halfway leaves the previous pack (or none) in place. About 60
// small files, written once on the user's click.
function installLogoPack({version, icons}) {
    const target = logoPackDir();
    const stage = `${target}.new-${GLib.uuid_string_random()}`;
    if (GLib.mkdir_with_parents(stage, 0o755) !== 0)
        throw new Error(`can’t create ${stage}`);
    try {
        for (const [id, svg] of icons)
            GLib.file_set_contents(GLib.build_filenamev([stage, `ProviderIcon-${id}.svg`]), svg);
        GLib.file_set_contents(GLib.build_filenamev([stage, 'VERSION']), `${version}\n`);
        const aside = moveAside(target);
        Gio.File.new_for_path(stage).move(Gio.File.new_for_path(target),
            Gio.FileCopyFlags.NONE, null, null);
        if (aside)
            deleteDir(aside);
    } catch (e) {
        try {
            deleteDir(stage);
        } catch {
            // best effort
        }
        throw e;
    }
}

export function removeLogoPack() {
    const aside = moveAside(logoPackDir());
    if (aside)
        deleteDir(aside);
}
