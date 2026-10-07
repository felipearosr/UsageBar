// The codexbar CLI the extension drives: where it is looked up, how its
// version is read, and the first-run provider setup. The extension never
// installs or updates the CLI; the user installs it (see INSTALL_URL).
// Dependency-free so the Node tests can exercise it without GJS.

// The .deb/.rpm ship the fork's CLI (upstream + `codexbar sync`) here, so a
// separate upstream `codexbar` on PATH never shadows it.
export const PACKAGED_BIN = '/usr/libexec/usagebar/codexbar';

export const INSTALL_URL = 'https://github.com/felipearosr/UsageBar/tree/main/linux#readme';

// Lookup order: $CODEXBAR_BIN, the packaged CLI, PATH, then the usual
// install directories a GNOME Shell PATH may lack. `env` supplies the
// GLib lookups (getenv, isExecutable, findInPath, home) so the extension
// and the preferences window resolve the very same binary.
export function findCodexbar(env) {
    const explicit = env.getenv('CODEXBAR_BIN');
    if (explicit && env.isExecutable(explicit))
        return explicit;
    if (env.isExecutable(PACKAGED_BIN))
        return PACKAGED_BIN;
    const inPath = env.findInPath('codexbar');
    if (inPath)
        return inPath;
    for (const dir of [`${env.home}/.local/bin`,
        '/home/linuxbrew/.linuxbrew/bin', '/usr/local/bin']) {
        const p = `${dir}/codexbar`;
        if (env.isExecutable(p))
            return p;
    }
    return null;
}

// `codexbar --version` prints "CodexBar 0.69.0"; returns "0.69.0", or the
// first non-empty line when it has no version number, or null.
export function parseCliVersion(stdout) {
    const line = (stdout ?? '').split('\n').map(l => l.trim()).find(Boolean);
    if (!line)
        return null;
    return line.match(/\d+(?:\.\d+)+\S*/)?.[0] ?? line;
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
