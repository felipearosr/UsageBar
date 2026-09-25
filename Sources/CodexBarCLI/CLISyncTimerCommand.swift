import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runSyncInstallTimer(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let installer = MachineSyncTimerInstaller()
        let uninstall = values.flags.contains("uninstall")

        let result: MachineSyncTimerResult
        do {
            if uninstall {
                result = try installer.uninstall()
            } else {
                // A timer on an unpaired Machine would only fail every 150 s.
                guard try MachineSyncStore().loadSettings()?.pairingLink != nil else {
                    Self.exit(
                        code: .failure,
                        message: "This Machine isn't in a Sync Group. Run `codexbar sync create` or "
                            + "`codexbar sync pair` first.",
                        output: output,
                        kind: .args)
                }
                guard let executable = Self.syncTimerExecutablePath() else {
                    Self.exit(
                        code: .failure,
                        message: "Couldn't find the path of the codexbar executable.",
                        output: output,
                        kind: .runtime)
                }
                result = try installer.install(executablePath: executable)
            }
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }

        switch output.format {
        case .text:
            print(uninstall
                ? Self.syncUninstallTimerText(result)
                : Self.syncInstallTimerText(result, userName: installer.userName))
        case .json:
            Self.printJSON(SyncTimerPayload(result, uninstall: uninstall), pretty: output.pretty)
        }
        Self.exit(code: result.failedCommands.isEmpty ? .success : .failure, output: output)
    }

    /// The absolute path the timer should run. Keeps a symlink (e.g. a Homebrew `bin/codexbar`) unresolved so
    /// an upgrade doesn't strand the job on an old version.
    static func syncTimerExecutablePath(
        argument0: String? = CommandLine.arguments.first,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        fallback: String? = Bundle.main.executablePath) -> String?
    {
        let isExecutable = { (path: String) in FileManager.default.isExecutableFile(atPath: path) }
        if let argument0, !argument0.isEmpty {
            if argument0.hasPrefix("/") {
                return argument0
            }
            if argument0.contains("/") {
                return URL(fileURLWithPath: currentDirectory, isDirectory: true)
                    .appendingPathComponent(argument0).standardizedFileURL.path
            }
            for directory in (searchPath ?? "").split(separator: ":") where directory.hasPrefix("/") {
                let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                    .appendingPathComponent(argument0).path
                if isExecutable(candidate) {
                    return candidate
                }
            }
        }
        return fallback
    }

    static func syncInstallTimerText(_ result: MachineSyncTimerResult, userName: String) -> String {
        var lines: [String] = []
        let paths = result.files.map { "  \($0.path)" }
        switch result.platform {
        case .systemd:
            lines.append("Wrote the systemd user timer:")
            lines += paths
            if result.failedCommands.isEmpty {
                lines.append("Started \(MachineSyncTimer.systemdUnitName).timer: `codexbar sync push` runs about "
                    + "every \(MachineSyncTimer.interval) s. Check it with "
                    + "`systemctl --user list-timers \(MachineSyncTimer.systemdUnitName).timer`.")
            }
            switch result.lingerEnabled {
            case .some(true):
                break
            case .some(false):
                lines += [
                    "",
                    "Lingering is off for \(userName), so the timer stops when you log out. To keep pushing "
                        + "without a login session, run:",
                    "  loginctl enable-linger \(userName)",
                ]
            case .none:
                lines += [
                    "",
                    "If the timer should keep running while you're logged out, run: loginctl enable-linger \(userName)",
                ]
            }
        case .launchd:
            lines.append("Wrote the launchd agent:")
            lines += paths
            if result.failedCommands.isEmpty {
                lines.append("Loaded \(MachineSyncTimer.launchdLabel): `codexbar sync push` runs about every "
                    + "\(MachineSyncTimer.interval) s.")
            }
        }
        if !result.failedCommands.isEmpty {
            lines += ["", "The files are in place, but starting the job failed:"]
            lines += result.failedCommands.map { "  \($0)" }
        }
        lines += [
            "",
            "Pushes take the push lock, so the desktop app or GNOME extension can keep running on this Machine.",
            "Remove the job with `codexbar sync install-timer --uninstall`.",
        ]
        return lines.joined(separator: "\n")
    }

    static func syncUninstallTimerText(_ result: MachineSyncTimerResult) -> String {
        var lines: [String]
        if result.files.isEmpty {
            lines = ["No sync timer was installed."]
        } else {
            lines = ["Stopped the sync timer and removed:"]
            lines += result.files.map { "  \($0.path)" }
        }
        if !result.failedCommands.isEmpty {
            lines += ["", "Some service-manager commands failed:"]
            lines += result.failedCommands.map { "  \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

private struct SyncTimerPayload: Encodable {
    let action: String
    let platform: String
    let files: [String]
    let failedCommands: [String]
    let lingerEnabled: Bool?

    init(_ result: MachineSyncTimerResult, uninstall: Bool) {
        self.action = uninstall ? "uninstalled" : "installed"
        self.platform = result.platform.rawValue
        self.files = result.files.map(\.path)
        self.failedCommands = result.failedCommands
        self.lingerEnabled = result.lingerEnabled
    }
}

struct SyncInstallTimerOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(name: .long("uninstall"), help: "Stop the timer and remove its files")
    var uninstall: Bool = false
}
