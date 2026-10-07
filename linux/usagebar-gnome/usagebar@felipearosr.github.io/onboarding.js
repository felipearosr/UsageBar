// What the popover and Settings show when no codexbar CLI is found, and the
// install page both link to. Dependency-free so the Node tests can check it.

// linux/INSTALL.md on main. Its "# Install UsageBar" heading is the stable
// anchor; the page covers every way to get the CLI.
export const INSTALL_URL =
    'https://github.com/felipearosr/UsageBar/blob/main/linux/INSTALL.md#install-usagebar';

export const MISSING_CLI = {
    title: 'UsageBar needs its command-line helper',
    body: 'UsageBar reads your usage through the codexbar command-line tool, ' +
        'which isn’t installed on this computer. Install it, and UsageBar ' +
        'picks it up on the next refresh.',
    button: 'Install instructions',
};
