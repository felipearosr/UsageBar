#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The background job a headless Machine uses to run `codexbar sync push` about every 150 s with ±20 s jitter
/// (§8.1, §9): a systemd user timer on Linux, a launchd agent on macOS. Each push takes the push lock, so the
/// job can run next to the desktop app or GNOME extension on the same Machine.
public enum MachineSyncTimer {
    public static let systemdUnitName = "codexbar-sync-push"
    public static let launchdLabel = "com.steipete.codexbar.sync-push"

    /// Seconds between pushes, before jitter.
    public static let interval = 150
    /// Pushes land up to this many seconds early or late.
    public static let jitter = 20

    public enum Platform: String, Sendable, Codable {
        case systemd
        case launchd

        public static var current: Platform {
            #if os(macOS)
            .launchd
            #else
            .systemd
            #endif
        }
    }

    /// A file the job consists of, with the exact bytes `install` writes.
    public struct File: Sendable, Equatable {
        public let url: URL
        public let contents: String
    }

    /// The files for `platform`, running `executablePath sync push`.
    public static func files(
        platform: Platform,
        executablePath: String,
        home: URL,
        environment: [String: String]) -> [File]
    {
        switch platform {
        case .systemd:
            let directory = self.systemdUserDirectory(home: home, environment: environment)
            return [
                File(
                    url: directory.appendingPathComponent("\(self.systemdUnitName).service"),
                    contents: self.systemdService(
                        executablePath: executablePath,
                        environment: self.carriedEnvironment(environment))),
                File(
                    url: directory.appendingPathComponent("\(self.systemdUnitName).timer"),
                    contents: self.systemdTimer()),
            ]
        case .launchd:
            return [
                File(
                    url: self.launchAgentsDirectory(home: home)
                        .appendingPathComponent("\(self.launchdLabel).plist"),
                    contents: self.launchdPlist(
                        executablePath: executablePath,
                        environment: self.carriedEnvironment(environment))),
            ]
        }
    }

    public static func systemdUserDirectory(home: URL, environment: [String: String]) -> URL {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return configHome
            .appendingPathComponent("systemd", isDirectory: true)
            .appendingPathComponent("user", isDirectory: true)
    }

    public static func launchAgentsDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    // MARK: - systemd

    /// Variables that change what `sync push` reads. `CODEXBAR_CONFIG` and `XDG_CONFIG_HOME` move `config.json`,
    /// and with it `sync.json`; `CODEX_HOME` and `CLAUDE_CONFIG_DIR` choose the logs the Spend scan reads.
    /// The service manager doesn't share the installing shell's environment, so the ones that are set are written
    /// into the job; otherwise the timer could push as a different, unpaired Machine, or push day blobs built from
    /// the default `~/.codex` and `~/.claude` over the correct ones.
    public static let carriedEnvironmentKeys = [
        CodexBarConfigStore.pathEnvironmentKey,
        CodexBarConfigStore.xdgConfigHomeEnvironmentKey,
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
    ]

    public static func carriedEnvironment(_ environment: [String: String]) -> [(key: String, value: String)] {
        self.carriedEnvironmentKeys.compactMap { key in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return (key, value)
        }
    }

    public static func systemdService(
        executablePath: String,
        environment: [(key: String, value: String)] = []) -> String
    {
        var service = [
            "[Unit]",
            "Description=CodexBar Machine Sync push",
            "After=network-online.target",
            "Wants=network-online.target",
            "",
            "[Service]",
            "Type=oneshot",
        ]
        for (key, value) in environment {
            service.append("Environment=\(self.systemdQuoted("\(key)=\(value)"))")
        }
        service += [
            "ExecStart=\(self.systemdQuoted(executablePath)) sync push",
            "Nice=10",
            "",
        ]
        return service.joined(separator: "\n")
    }

    /// `OnUnitActiveSec` counts from the previous start, and `RandomizedDelaySec` adds 0-40 s to each one, so
    /// pushes start 130-170 s apart.
    public static func systemdTimer() -> String {
        """
        [Unit]
        Description=Run CodexBar Machine Sync push every ~\(self.interval) s

        [Timer]
        OnActiveSec=\(self.jitter)s
        OnUnitActiveSec=\(self.interval - self.jitter)s
        RandomizedDelaySec=\(2 * self.jitter)s
        AccuracySec=1s
        Unit=\(self.systemdUnitName).service

        [Install]
        WantedBy=timers.target

        """
    }

    /// Double-quoted for `ExecStart=` and `Environment=`, with `%` doubled so systemd doesn't read it as a specifier.
    static func systemdQuoted(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        return "\"\(escaped)\""
    }

    // MARK: - launchd

    /// launchd has no jitter setting. The agent fires every 150 s and each run first sleeps 0-20 s (picked from
    /// its PID), so consecutive pushes start 130-170 s apart. The executable is passed as `$0` so its path is
    /// never parsed by the shell.
    public static func launchdPlist(
        executablePath: String,
        environment: [(key: String, value: String)] = []) -> String
    {
        let script = "sleep $(($$ % \(self.jitter + 1))); exec \"$0\" sync push"
        let arguments = ["/bin/sh", "-c", script, executablePath]
            .map { "        <string>\(self.xmlEscaped($0))</string>" }
            .joined(separator: "\n")
        var environmentXML = ""
        if !environment.isEmpty {
            let entries = environment
                .map { key, value in
                    "        <key>\(self.xmlEscaped(key))</key>\n"
                        + "        <string>\(self.xmlEscaped(value))</string>"
                }
                .joined(separator: "\n")
            environmentXML = "\n    <key>EnvironmentVariables</key>\n    <dict>\n\(entries)\n    </dict>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(self.launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(arguments)
            </array>
            <key>StartInterval</key>
            <integer>\(self.interval)</integer>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>LowPriorityIO</key>
            <true/>\(environmentXML)
        </dict>
        </plist>

        """
    }

    static func xmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Install / uninstall

/// Runs a service-manager command (`systemctl`, `launchctl`) and returns its exit status and combined output.
public typealias MachineSyncTimerCommandRunner = @Sendable (_ executable: String, _ arguments: [String])
    -> (status: Int32, output: String)

public struct MachineSyncTimerResult: Sendable, Equatable {
    public var platform: MachineSyncTimer.Platform
    /// Files written (install) or removed (uninstall).
    public var files: [URL]
    /// Service-manager commands that failed; the files are in place, so the user can rerun them.
    public var failedCommands: [String]
    /// systemd only: `nil` when unknown, `false` when the timer stops at logout.
    public var lingerEnabled: Bool?
}

public struct MachineSyncTimerInstaller: Sendable {
    public var platform: MachineSyncTimer.Platform
    public var home: URL
    public var environment: [String: String]
    public var userName: String
    public var userID: UInt32
    /// Directory systemd-logind marks lingering users in (`/var/lib/systemd/linger`).
    public var lingerDirectory: URL
    public var runCommand: MachineSyncTimerCommandRunner

    public init(
        platform: MachineSyncTimer.Platform = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        userID: UInt32 = UInt32(getuid()),
        lingerDirectory: URL = URL(fileURLWithPath: "/var/lib/systemd/linger", isDirectory: true),
        runCommand: @escaping MachineSyncTimerCommandRunner = MachineSyncTimerInstaller.run)
    {
        self.platform = platform
        self.home = home
        self.environment = environment
        self.userName = userName
        self.userID = userID
        self.lingerDirectory = lingerDirectory
        self.runCommand = runCommand
    }

    public func files(executablePath: String) -> [MachineSyncTimer.File] {
        MachineSyncTimer.files(
            platform: self.platform,
            executablePath: executablePath,
            home: self.home,
            environment: self.environment)
    }

    /// Writes the job's files (replacing an earlier install) and starts it.
    public func install(executablePath: String) throws -> MachineSyncTimerResult {
        let files = self.files(executablePath: executablePath)
        for file in files {
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(file.contents.utf8).write(to: file.url, options: .atomic)
        }
        var failed: [String] = []
        switch self.platform {
        case .systemd:
            self.run("systemctl", ["--user", "daemon-reload"], failed: &failed)
            self.run(
                "systemctl",
                ["--user", "enable", "--now", "\(MachineSyncTimer.systemdUnitName).timer"],
                failed: &failed)
        case .launchd:
            // Unload a previous copy first so a reinstall picks up the new plist; failure means none was loaded.
            self.bootoutLaunchAgent()
            failed += self.bootstrapLaunchAgent(plist: files[0].url.path)
        }
        return MachineSyncTimerResult(
            platform: self.platform,
            files: files.map(\.url),
            failedCommands: failed,
            lingerEnabled: self.lingerEnabled)
    }

    /// Stops the job and deletes exactly the files `install` writes. Missing files are not an error.
    public func uninstall() throws -> MachineSyncTimerResult {
        let urls = self.files(executablePath: "").map(\.url)
        var failed: [String] = []
        switch self.platform {
        case .systemd:
            if urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                self.run(
                    "systemctl",
                    ["--user", "disable", "--now", "\(MachineSyncTimer.systemdUnitName).timer"],
                    failed: &failed)
            }
        case .launchd:
            self.bootoutLaunchAgent()
        }
        var removed: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        if self.platform == .systemd, !removed.isEmpty {
            self.run("systemctl", ["--user", "daemon-reload"], failed: &failed)
        }
        return MachineSyncTimerResult(
            platform: self.platform,
            files: removed,
            failedCommands: failed,
            lingerEnabled: nil)
    }

    /// systemd only. User timers stop when the user's last session ends unless lingering is on.
    public var lingerEnabled: Bool? {
        guard self.platform == .systemd else { return nil }
        guard FileManager.default.fileExists(atPath: self.lingerDirectory.path) else { return nil }
        return FileManager.default.fileExists(atPath: self.lingerDirectory.appendingPathComponent(self.userName).path)
    }

    /// `gui/<uid>` exists only while the user is logged in at the screen; over SSH on a headless Mac the agent
    /// goes into the `user/<uid>` domain instead.
    var launchdDomains: [String] {
        ["gui/\(self.userID)", "user/\(self.userID)"]
    }

    /// Returns the failures when no domain accepted the agent, or `[]` once one did.
    private func bootstrapLaunchAgent(plist: String) -> [String] {
        var failed: [String] = []
        for domain in self.launchdDomains {
            var attempt: [String] = []
            self.run("/bin/launchctl", ["bootstrap", domain, plist], failed: &attempt)
            if attempt.isEmpty {
                return []
            }
            failed += attempt
        }
        return failed
    }

    /// Unloads the agent from every domain. Not being loaded is not an error.
    private func bootoutLaunchAgent() {
        for domain in self.launchdDomains {
            _ = self.runCommand("/bin/launchctl", ["bootout", "\(domain)/\(MachineSyncTimer.launchdLabel)"])
        }
    }

    private func run(_ executable: String, _ arguments: [String], failed: inout [String]) {
        let result = self.runCommand(executable, arguments)
        guard result.status != 0 else { return }
        let command = ([executable] + arguments).joined(separator: " ")
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        failed.append(detail.isEmpty ? command : "\(command): \(detail)")
    }

    /// Runs `executable` (a bare name is looked up on `PATH`) and captures stdout and stderr together.
    public static let run: MachineSyncTimerCommandRunner = { executable, arguments in
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (127, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }
}
