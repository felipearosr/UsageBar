// Provider logos for installs that don't ship them. The extensions.gnome.org
// build leaves the logo SVGs out (third-party trademarks), so on the user's
// click UsageBar downloads them as one JSON "logo pack" from its own GitHub
// release, the release the extension itself came from. Nothing is fetched
// without that click, and an update never re-downloads on its own.
// Dependency-free so the Node tests can exercise it without GJS.

export const LOGO_PACK_FORMAT = 1;
const RELEASES_URL = 'https://github.com/felipearosr/UsageBar/releases/download';

// Limits on what a pack may hold; the release pack is ~75 KB of SVG.
export const MAX_PACK_BYTES = 2 * 1024 * 1024;
export const MAX_ICONS = 200;
export const MAX_SVG_CHARS = 64 * 1024;

export const LOGO_PROMPT = {
    title: 'Show provider logos?',
    body: 'This version of UsageBar doesn’t include provider logos, so it ' +
        'shows provider names instead. UsageBar can download the logos from ' +
        'its GitHub release. Nothing is downloaded unless you click Download.',
    download: 'Download',
    downloading: 'Downloading…',
    dismiss: 'Not now',
    failed: message => `Couldn’t download the logos: ${message}`,
};

// metadata.json "version-name" is the release version with "-" written as a
// space (resolve-version.sh: 1.1.0-rc.2 → "1.1.0 rc.2"). Returns the release
// version, or null for a development checkout, which has no version-name.
export function releaseVersion(versionName) {
    const name = typeof versionName === 'string' ? versionName.trim() : '';
    if (!/^\d+\.\d+\.\d+( [0-9A-Za-z.]+)*$/.test(name))
        return null;
    return name.replaceAll(' ', '-');
}

// The release asset name; resolve-version.sh's logos_asset.
export function logoPackAsset(version) {
    return `usagebar-provider-icons-${version}.json`;
}

export function logoPackUrl(version) {
    return `${RELEASES_URL}/usagebar-v${version}/${logoPackAsset(version)}`;
}

// The checksum in a sha256sum line naming `asset`, or null.
export function parseChecksum(text, asset) {
    const match = /^([0-9a-f]{64}) [ *](.+)$/.exec((text ?? '').trim());
    return match && match[2] === asset ? match[1] : null;
}

// An SVG the panel can draw that can't reach outside itself: no scripts,
// event handlers, foreign content, entity definitions or links other than
// in-document #fragments.
export function isSafeSvg(svg) {
    if (typeof svg !== 'string' || !svg.length || svg.length > MAX_SVG_CHARS)
        return false;
    if (!/^\s*(<\?xml[^>]*\?>\s*)?(<!DOCTYPE svg[^>[]*>\s*)?<svg[\s>]/.test(svg))
        return false;
    if (/<script|<foreignObject|<!ENTITY|\son[a-z]+\s*=/i.test(svg))
        return false;
    for (const [, target] of svg.matchAll(/href\s*=\s*["']([^"']*)["']/gi)) {
        if (!target.startsWith('#'))
            return false;
    }
    return true;
}

export function isProviderId(id) {
    return typeof id === 'string' && /^[a-z0-9]{1,40}$/.test(id);
}

// Parses and checks a downloaded pack: {"format": 1, "version": "<release>",
// "icons": {"<provider id>": "<svg>", ...}}. Returns {version, icons} with
// icons as [id, svg] pairs, or throws an Error saying what's wrong.
export function parseLogoPack(text, version) {
    if (typeof text !== 'string' || text.length > MAX_PACK_BYTES)
        throw new Error('the logo pack is too large');
    let pack;
    try {
        pack = JSON.parse(text);
    } catch {
        throw new Error('the logo pack isn’t valid JSON');
    }
    if (pack?.format !== LOGO_PACK_FORMAT)
        throw new Error(`unsupported logo pack format ${JSON.stringify(pack?.format)}`);
    if (pack.version !== version)
        throw new Error(`the logo pack is for version ${pack.version}, expected ${version}`);
    const icons = Object.entries(pack.icons ?? {});
    if (!icons.length || icons.length > MAX_ICONS)
        throw new Error(`the logo pack has ${icons.length} logos`);
    for (const [id, svg] of icons) {
        if (!isProviderId(id))
            throw new Error(`bad provider id ${JSON.stringify(id)}`);
        if (!isSafeSvg(svg))
            throw new Error(`the ${id} logo isn’t a plain SVG`);
    }
    return {version, icons};
}

// What Settings → General → Provider logos shows. `bundled`: the install
// ships logos (a development checkout or the .deb/.rpm). `installed`: the
// downloaded pack's version, or null. `version`: this release's version, or
// null (no pack to download).
export function logoPackState({bundled, installed, version}) {
    if (bundled)
        return {status: 'Included with this install', actions: []};
    if (installed && installed === version)
        return {status: `Downloaded (version ${installed})`, actions: ['remove']};
    if (installed) {
        return {
            status: version
                ? `Downloaded (version ${installed}) · logos for ${version} available`
                : `Downloaded (version ${installed})`,
            actions: version ? ['update', 'remove'] : ['remove'],
        };
    }
    if (!version)
        return {status: 'Not available for development builds', actions: []};
    return {status: 'Not downloaded · provider names are shown instead', actions: ['download']};
}

// The popover offers the download only when it can help: no logos anywhere,
// a release to download from, and the user hasn't said "Not now".
export function wantsLogoPrompt({bundled, installed, version, dismissed}) {
    return !bundled && !installed && !!version && !dismissed;
}
