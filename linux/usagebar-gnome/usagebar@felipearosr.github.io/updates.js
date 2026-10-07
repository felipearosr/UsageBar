// Packaged-install rules: where the bundled CLI lives, which GitHub release
// and asset an update comes from, and the first-run provider setup.
// Dependency-free so the Node tests can exercise it without GJS.

// The .deb/.rpm ship the fork's CLI (upstream + `codexbar sync`) here, so a
// separate upstream `codexbar` on PATH never shadows it.
export const PACKAGED_BIN = '/usr/libexec/usagebar/codexbar';

export const RELEASES_API = 'https://api.github.com/repos/felipearosr/UsageBar/releases?per_page=30';
export const RELEASE_TAG_PREFIX = 'usagebar-v';

export function compareVersions(a, b) {
    const pa = a.split('.').map(n => parseInt(n, 10) || 0);
    const pb = b.split('.').map(n => parseInt(n, 10) || 0);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const d = (pa[i] ?? 0) - (pb[i] ?? 0);
        if (d)
            return d;
    }
    return 0;
}

// The repo also carries other releases (CLI pre-builds, desktop app), so
// "latest" is the newest published UsageBar one, not GitHub's /latest.
export function latestUsageBarRelease(releases) {
    let best = null;
    for (const release of releases ?? []) {
        if (release?.draft || release?.prerelease)
            continue;
        const tag = release?.tag_name ?? '';
        if (!tag.startsWith(RELEASE_TAG_PREFIX))
            continue;
        const version = tag.slice(RELEASE_TAG_PREFIX.length);
        if (!/^\d+(\.\d+)*$/.test(version))
            continue;
        if (!best || compareVersions(version, best.version) > 0)
            best = {version, release};
    }
    return best;
}

// `uname -m` → package file name, matching linux/packaging/build-packages.sh.
export function packageAssetName(format, version, machine) {
    if (format === 'deb') {
        const arch = {x86_64: 'amd64', aarch64: 'arm64'}[machine];
        return arch ? `usagebar_${version}_${arch}.deb` : null;
    }
    if (format === 'rpm')
        return ['x86_64', 'aarch64'].includes(machine) ? `usagebar-${version}-1.${machine}.rpm` : null;
    return null;
}

// pkexec shows the desktop's password prompt; the package manager then
// installs the downloaded file like any local package.
export function installCommand(format, file) {
    if (format === 'deb')
        return ['pkexec', 'apt-get', 'install', '-y', file];
    if (format === 'rpm')
        return ['pkexec', 'dnf', 'install', '-y', file];
    return null;
}

export function updateReadyText(version) {
    return `UsageBar ${version} is available. Install now?`;
}

export function updateCompletionMessage(version) {
    return `UsageBar ${version} installed — log out and back in to finish the update`;
}

// First run: the claude provider needs the OAuth source on Linux; the CLI's
// default source drops per-model limits and the plan badge. Returns a new
// config, or null when nothing changes (an explicit source is the user's).
export function withClaudeOAuth(config) {
    const providers = config?.providers;
    if (!Array.isArray(providers))
        return null;
    const index = providers.findIndex(p => p?.id === 'claude');
    if (index < 0 || !providers[index].enabled || providers[index].source)
        return null;
    const next = providers.slice();
    next[index] = {...providers[index], source: 'oauth'};
    return {...config, providers: next};
}
