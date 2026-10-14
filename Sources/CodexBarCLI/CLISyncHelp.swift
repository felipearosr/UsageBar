import Commander

extension CodexBarCLI {
    // MARK: - Machine Sync: `codexbar sync` descriptor and help

    static func syncCommandDescriptor() -> CommandDescriptor {
        let syncCreateSignature = CommandSignature.describe(SyncCreateOptions())
        let syncPushSignature = CommandSignature.describe(SyncPushOptions())
        let syncPairSignature = CommandSignature.describe(SyncPairOptions())
        let syncStatusSignature = CommandSignature.describe(SyncStatusOptions())
        let syncLinkSignature = CommandSignature.describe(SyncLinkOptions())
        let syncRenameSignature = CommandSignature.describe(SyncRenameOptions())
        let syncMachineSignature = CommandSignature.describe(SyncMachineOptions())
        let syncLeaveSignature = CommandSignature.describe(SyncLeaveOptions())
        let syncInstallTimerSignature = CommandSignature.describe(SyncInstallTimerOptions())
        let syncInfoSignature = CommandSignature.describe(SyncInfoOptions())
        let syncSettingsSignature = CommandSignature.describe(SyncSettingsOptions())
        return CommandDescriptor(
            name: "sync",
            abstract: "Machine Sync: share Spend across your Machines",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "create",
                    abstract: "Create a Sync Group on a Sync Server and start pushing",
                    discussion: nil,
                    signature: syncCreateSignature),
                CommandDescriptor(
                    name: "pair",
                    abstract: "Join a Sync Group with its Pairing Link and backfill this Machine's Spend",
                    discussion: nil,
                    signature: syncPairSignature),
                CommandDescriptor(
                    name: "push",
                    abstract: "Push this Machine's Spend to its Sync Group",
                    discussion: nil,
                    signature: syncPushSignature),
                CommandDescriptor(
                    name: "status",
                    abstract: "Show every Machine's Spend, Last Seen, and Coverage",
                    discussion: nil,
                    signature: syncStatusSignature),
                CommandDescriptor(
                    name: "link",
                    abstract: "Print this Sync Group's Pairing Link",
                    discussion: nil,
                    signature: syncLinkSignature),
                CommandDescriptor(
                    name: "rename",
                    abstract: "Change this Machine's display name",
                    discussion: nil,
                    signature: syncRenameSignature),
                CommandDescriptor(
                    name: "retire",
                    abstract: "Mark another Machine as gone; its Spend stays in totals",
                    discussion: nil,
                    signature: syncMachineSignature),
                CommandDescriptor(
                    name: "forget",
                    abstract: "Delete another Machine and its Spend from the Sync Server",
                    discussion: nil,
                    signature: syncMachineSignature),
                CommandDescriptor(
                    name: "leave",
                    abstract: "Unpair this Machine; its Spend stays on the server",
                    discussion: nil,
                    signature: syncLeaveSignature),
                CommandDescriptor(
                    name: "install-timer",
                    abstract: "Run `sync push` every ~150 s from a systemd user timer or launchd agent",
                    discussion: nil,
                    signature: syncInstallTimerSignature),
                CommandDescriptor(
                    name: "info",
                    abstract: "Ask a Sync Server whether creating a Sync Group needs an Enrollment Token",
                    discussion: nil,
                    signature: syncInfoSignature),
                CommandDescriptor(
                    name: "settings",
                    abstract: "Show this Machine's Machine Sync settings, or set its Reporting Day",
                    discussion: nil,
                    signature: syncSettingsSignature),
            ],
            defaultSubcommandName: "push")
    }

    static func syncHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>] [--yes]
                               [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync pair <pairing-link> [--name <display-name>] [--yes]
                             [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync push [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync status [--timezone <iana-id>] [--day-start <hour>]
                               [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync install-timer [--uninstall] [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync link [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync rename <display-name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync retire <machine-id-or-name> [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync forget <machine-id-or-name> [--yes] [--format text|json] [--json] [--json-only] [--pretty]
          codexbar sync leave [--yes] [--format text|json] [--json] [--json-only] [--pretty]

        Description:
          Machine Sync shares each Machine's Spend (local-log cost, tokens, and requests) with your other
          Machines through a Sync Server, end-to-end encrypted. It stays off until you create a Sync Group.

          create  Generates the Sync Group key on this Machine, registers the group on the server (with an
                  Enrollment Token if the server requires one), backfills this Machine's Spend, and prints the
                  Pairing Link. Store the link somewhere safe: it is the recovery key for the group.
                  A plain http:// server that isn't loopback asks first; --yes skips the question.
          pair    Joins the Sync Group in a Pairing Link and backfills this Machine's Spend for every day the
                  server keeps. A codexbar-sync+http:// link to a host that isn't loopback asks first; --yes
                  skips the question.
          push    Uploads today's and yesterday's UTC Spend plus this Machine's profile, skipping anything
                  unchanged since the last push. Only one push runs at a time per Machine.
          status  Shows every Machine: display name, active (Last Seen under 5 minutes), today's and 30-day
                  Spend, the split by provider and model, and Coverage. Days follow the Reporting Day: the
                  system timezone and midnight unless sync.json sets "reportingDay" or the flags override it.
          install-timer
                  For Machines without a desktop surface (VPS, SSH devbox): installs a systemd user timer
                  (Linux) or launchd agent (macOS) that runs `codexbar sync push` about every 150 s, with
                  +/-20 s of jitter. It needs no graphical session. On Linux the timer stops at logout unless
                  lingering is on: `loginctl enable-linger $USER`. Pushes take the push lock, so the timer can
                  run next to the desktop app or GNOME extension. --uninstall stops the job and removes only
                  its unit or agent files.
          link    Prints the Pairing Link (the warning goes to stderr). Anyone who has it can read and change
                  the group's Spend.
          rename  Changes this Machine's display name and pushes it so the other Machines see it.
          retire  Marks another Machine as gone, for example after a reinstall. Its Spend stays in totals but
                  it no longer shows as active. If it pushes again, it shows as active again.
          forget  Deletes another Machine and all its Spend from the Sync Server. Asks first; --yes skips the
                  question (needed without a terminal or with JSON output).
          leave   Unpairs this Machine and forgets the Pairing Link. Its Spend stays on the server, and pairing
                  again restores the same Machine. Asks first; --yes skips the question.

        Examples:
          codexbar sync create --server https://sync.example.com --token tok_123 --name laptop
          codexbar sync pair 'codexbar-sync://sync.example.com#<key>' --name desk
          codexbar sync push
          codexbar sync status --timezone America/Los_Angeles --day-start 4
          codexbar sync status --json --pretty
          codexbar sync install-timer
          codexbar sync install-timer --uninstall
          codexbar sync rename "work laptop"
          codexbar sync retire old-desktop
          codexbar sync forget old-desktop --yes
        """
    }
}
