import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Records service-manager calls instead of running them.
private final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    /// Exit status per command prefix (e.g. `"/bin/launchctl bootstrap gui/501"`); everything else exits 0.
    var failures: [String: Int32] = [:]

    var calls: [[String]] {
        self.lock.withLock { self._calls }
    }

    var runner: MachineSyncTimerCommandRunner {
        { executable, arguments in
            let call = [executable] + arguments
            self.lock.withLock { self._calls.append(call) }
            let joined = call.joined(separator: " ")
            for (prefix, status) in self.failures where joined.hasPrefix(prefix) {
                return (status, "boom")
            }
            return (0, "")
        }
    }
}

struct MachineSyncTimerTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sync-timer-\(UUID().uuidString)", isDirectory: true)

    private var home: URL {
        self.root.appendingPathComponent("home", isDirectory: true)
    }

    private var lingerDirectory: URL {
        self.root.appendingPathComponent("linger", isDirectory: true)
    }

    private func installer(
        _ platform: MachineSyncTimer.Platform,
        log: CommandLog,
        environment: [String: String] = [:]) -> MachineSyncTimerInstaller
    {
        MachineSyncTimerInstaller(
            platform: platform,
            home: self.home,
            environment: environment,
            userName: "dev",
            userID: 501,
            lingerDirectory: self.lingerDirectory,
            runCommand: log.runner)
    }

    private static func files(
        _ platform: MachineSyncTimer.Platform,
        home: String,
        environment: [String: String]) -> [MachineSyncTimer.File]
    {
        MachineSyncTimer.files(
            platform: platform,
            executablePath: "/bin/codexbar",
            home: URL(fileURLWithPath: home),
            environment: environment)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    // MARK: - systemd

    @Test
    func `systemd timer pushes every 130 to 170 seconds`() {
        let timer = MachineSyncTimer.systemdTimer()
        #expect(timer.contains("OnUnitActiveSec=130s\n"))
        #expect(timer.contains("RandomizedDelaySec=40s\n"))
        #expect(timer.contains("Unit=codexbar-sync-push.service\n"))
        #expect(timer.contains("WantedBy=timers.target\n"))
    }

    @Test
    func `systemd service runs sync push as a oneshot`() {
        let service = MachineSyncTimer.systemdService(executablePath: "/usr/local/bin/codexbar")
        #expect(service.contains("Type=oneshot\n"))
        #expect(service.contains("ExecStart=\"/usr/local/bin/codexbar\" sync push\n"))
        #expect(!service.contains("Environment="))
    }

    @Test
    func `systemd service quotes odd paths and escapes specifiers`() {
        let service = MachineSyncTimer.systemdService(executablePath: "/opt/my \"bar\"/100%/codexbar")
        #expect(service.contains(#"ExecStart="/opt/my \"bar\"/100%%/codexbar" sync push"#))
    }

    @Test
    func `the job carries the variables that move sync json and the Spend logs`() throws {
        let environment = [
            "CODEXBAR_CONFIG": " ~/cfg/config.json ",
            "XDG_CONFIG_HOME": "/xdg",
            "CODEX_HOME": "/work/codex",
            "CLAUDE_CONFIG_DIR": "/work/claude",
            "XDG_DATA_HOME": "/data",
            "PATH": "/usr/bin",
        ]
        let carried = MachineSyncTimer.carriedEnvironment(environment)
        #expect(carried.map(\.key) == ["CODEXBAR_CONFIG", "XDG_CONFIG_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR"])
        #expect(carried.map(\.value) == ["~/cfg/config.json", "/xdg", "/work/codex", "/work/claude"])
        #expect(MachineSyncTimer.carriedEnvironment(["CODEXBAR_CONFIG": "  "]).isEmpty)

        let files = Self.files(.systemd, home: "/home/dev", environment: environment)
        #expect(files[0].contents.contains("Environment=\"CODEXBAR_CONFIG=~/cfg/config.json\"\n"))
        #expect(files[0].contents.contains("Environment=\"XDG_CONFIG_HOME=/xdg\"\n"))
        #expect(files[0].contents.contains("Environment=\"CODEX_HOME=/work/codex\"\n"))
        #expect(files[0].contents.contains("Environment=\"CLAUDE_CONFIG_DIR=/work/claude\"\n"))
        #expect(!files[0].contents.contains("XDG_DATA_HOME"))

        let plist = Self.files(
            .launchd,
            home: "/Users/dev",
            environment: ["XDG_CONFIG_HOME": "/a&b", "CODEX_HOME": "/c", "CLAUDE_CONFIG_DIR": "/d"])[0].contents
        let parsed = try #require(
            try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        #expect(parsed["EnvironmentVariables"] as? [String: String] == [
            "XDG_CONFIG_HOME": "/a&b",
            "CODEX_HOME": "/c",
            "CLAUDE_CONFIG_DIR": "/d",
        ])
    }

    @Test
    func `systemd units go under XDG_CONFIG_HOME when it is absolute`() {
        let defaultFiles = Self.files(.systemd, home: "/home/dev", environment: [:])
        #expect(defaultFiles.map(\.url.path) == [
            "/home/dev/.config/systemd/user/codexbar-sync-push.service",
            "/home/dev/.config/systemd/user/codexbar-sync-push.timer",
        ])
        let custom = Self.files(.systemd, home: "/home/dev", environment: ["XDG_CONFIG_HOME": "/cfg"])
        #expect(custom.map(\.url.path).allSatisfy { $0.hasPrefix("/cfg/systemd/user/") })
        let relative = Self.files(.systemd, home: "/home/dev", environment: ["XDG_CONFIG_HOME": "cfg"])
        #expect(relative.map(\.url.path).allSatisfy { $0.hasPrefix("/home/dev/.config/systemd/user/") })
    }

    @Test
    func `systemd install writes both units and enables the timer`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        let result = try self.installer(.systemd, log: log).install(executablePath: "/usr/bin/codexbar")

        let directory = self.home.appendingPathComponent(".config/systemd/user")
        let service = try String(
            contentsOf: directory.appendingPathComponent("codexbar-sync-push.service"), encoding: .utf8)
        let timer = try String(
            contentsOf: directory.appendingPathComponent("codexbar-sync-push.timer"), encoding: .utf8)
        #expect(service == MachineSyncTimer.systemdService(executablePath: "/usr/bin/codexbar"))
        #expect(timer == MachineSyncTimer.systemdTimer())
        #expect(result.files.count == 2)
        #expect(result.failedCommands.isEmpty)
        #expect(log.calls == [
            ["systemctl", "--user", "daemon-reload"],
            ["systemctl", "--user", "enable", "--now", "codexbar-sync-push.timer"],
        ])
    }

    @Test
    func `systemd reinstall replaces the previous units`() throws {
        defer { self.cleanup() }
        let installer = self.installer(.systemd, log: CommandLog())
        _ = try installer.install(executablePath: "/old/codexbar")
        _ = try installer.install(executablePath: "/new/codexbar")
        let service = try String(
            contentsOf: self.home.appendingPathComponent(".config/systemd/user/codexbar-sync-push.service"),
            encoding: .utf8)
        #expect(service.contains("\"/new/codexbar\" sync push"))
        #expect(!service.contains("/old/"))
    }

    @Test
    func `systemd install reports a failed systemctl but keeps the files`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        log.failures["systemctl --user enable"] = 1
        let result = try self.installer(.systemd, log: log).install(executablePath: "/usr/bin/codexbar")
        #expect(result.failedCommands == ["systemctl --user enable --now codexbar-sync-push.timer: boom"])
        #expect(result.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test
    func `linger is reported off unless logind marks the user`() throws {
        defer { self.cleanup() }
        let installer = self.installer(.systemd, log: CommandLog())
        #expect(installer.lingerEnabled == nil)

        try FileManager.default.createDirectory(at: self.lingerDirectory, withIntermediateDirectories: true)
        #expect(installer.lingerEnabled == false)

        FileManager.default.createFile(atPath: self.lingerDirectory.appendingPathComponent("dev").path, contents: nil)
        #expect(installer.lingerEnabled == true)
        #expect(self.installer(.launchd, log: CommandLog()).lingerEnabled == nil)
    }

    @Test
    func `systemd uninstall removes the two units and nothing else`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        let installer = self.installer(.systemd, log: log)
        _ = try installer.install(executablePath: "/usr/bin/codexbar")
        let directory = self.home.appendingPathComponent(".config/systemd/user")
        let neighbor = directory.appendingPathComponent("other.service")
        try Data("[Service]\n".utf8).write(to: neighbor)
        let store = MachineSyncStore(directory: self.root.appendingPathComponent("config"))
        try store.saveSettings(MachineSyncSettings(machineID: "m1", displayName: "vps"))

        let result = try installer.uninstall()

        #expect(result.files.map(\.lastPathComponent) == ["codexbar-sync-push.service", "codexbar-sync-push.timer"])
        #expect(result.failedCommands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: result.files[0].path))
        #expect(!FileManager.default.fileExists(atPath: result.files[1].path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
        #expect(try store.loadSettings()?.machineID == "m1")
        #expect(log.calls.suffix(2) == [
            ["systemctl", "--user", "disable", "--now", "codexbar-sync-push.timer"],
            ["systemctl", "--user", "daemon-reload"],
        ])
    }

    @Test
    func `uninstall without an install touches nothing`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        let result = try self.installer(.systemd, log: log).uninstall()
        #expect(result.files.isEmpty)
        #expect(log.calls.isEmpty)
    }

    // MARK: - launchd

    @Test
    func `launchd plist runs sync push every 150 seconds with up to 20 seconds of delay`() throws {
        let plist = MachineSyncTimer.launchdPlist(executablePath: "/Users/dev/A & B/codexbar")
        let parsed = try #require(
            try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        #expect(parsed["Label"] as? String == "com.steipete.codexbar.sync-push")
        #expect(parsed["StartInterval"] as? Int == 150)
        #expect(parsed["RunAtLoad"] as? Bool == true)
        #expect(parsed["EnvironmentVariables"] == nil)
        #expect(parsed["ProgramArguments"] as? [String] == [
            "/bin/sh",
            "-c",
            "sleep $(($$ % 21)); exec \"$0\" sync push",
            "/Users/dev/A & B/codexbar",
        ])
    }

    @Test
    func `launchd install writes the agent and bootstraps it into the GUI domain`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        let result = try self.installer(.launchd, log: log).install(executablePath: "/opt/homebrew/bin/codexbar")
        let plist = self.home.appendingPathComponent("Library/LaunchAgents/com.steipete.codexbar.sync-push.plist")
        #expect(result.files == [plist])
        #expect(try String(contentsOf: plist, encoding: .utf8)
            == MachineSyncTimer.launchdPlist(executablePath: "/opt/homebrew/bin/codexbar"))
        #expect(result.failedCommands.isEmpty)
        #expect(log.calls == [
            ["/bin/launchctl", "bootout", "gui/501/com.steipete.codexbar.sync-push"],
            ["/bin/launchctl", "bootout", "user/501/com.steipete.codexbar.sync-push"],
            ["/bin/launchctl", "bootstrap", "gui/501", plist.path],
        ])
    }

    @Test
    func `launchd install falls back to the user domain without a GUI login`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        log.failures["/bin/launchctl bootstrap gui/501"] = 125
        let result = try self.installer(.launchd, log: log).install(executablePath: "/usr/local/bin/codexbar")
        #expect(result.failedCommands.isEmpty)
        #expect(log.calls.last?.prefix(3) == ["/bin/launchctl", "bootstrap", "user/501"])

        log.failures["/bin/launchctl bootstrap user/501"] = 5
        let failed = try self.installer(.launchd, log: log).install(executablePath: "/usr/local/bin/codexbar")
        #expect(failed.failedCommands.count == 2)
    }

    @Test
    func `launchd uninstall boots out the agent and removes only its plist`() throws {
        defer { self.cleanup() }
        let log = CommandLog()
        let installer = self.installer(.launchd, log: log)
        _ = try installer.install(executablePath: "/usr/local/bin/codexbar")
        let neighbor = self.home.appendingPathComponent("Library/LaunchAgents/com.example.other.plist")
        try Data("<plist/>".utf8).write(to: neighbor)

        let result = try installer.uninstall()
        #expect(result.files.map(\.lastPathComponent) == ["com.steipete.codexbar.sync-push.plist"])
        #expect(!FileManager.default.fileExists(atPath: result.files[0].path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
        #expect(log.calls.suffix(2) == [
            ["/bin/launchctl", "bootout", "gui/501/com.steipete.codexbar.sync-push"],
            ["/bin/launchctl", "bootout", "user/501/com.steipete.codexbar.sync-push"],
        ])
    }

    // MARK: - CLI

    @Test
    func `executable path keeps absolute paths and resolves relative ones`() {
        #expect(CodexBarCLI.syncTimerExecutablePath(
            argument0: "/opt/homebrew/bin/codexbar", currentDirectory: "/tmp", searchPath: nil, fallback: nil)
            == "/opt/homebrew/bin/codexbar")
        #expect(CodexBarCLI.syncTimerExecutablePath(
            argument0: "./bin/../codexbar", currentDirectory: "/work", searchPath: nil, fallback: nil)
            == "/work/codexbar")
    }

    @Test
    func `executable path searches PATH for a bare name`() throws {
        defer { self.cleanup() }
        let bin = self.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("codexbar")
        FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])

        let found = CodexBarCLI.syncTimerExecutablePath(
            argument0: "codexbar",
            currentDirectory: "/",
            searchPath: "relative:/nowhere:\(bin.path)",
            fallback: "/proc/self/exe")
        #expect(found == executable.path)
        #expect(CodexBarCLI.syncTimerExecutablePath(
            argument0: "codexbar", currentDirectory: "/", searchPath: "/nowhere", fallback: "/fallback")
            == "/fallback")
    }

    @Test
    func `install text tells the user to enable lingering when it is off`() {
        let result = MachineSyncTimerResult(
            platform: .systemd,
            files: [URL(fileURLWithPath: "/home/dev/.config/systemd/user/codexbar-sync-push.timer")],
            failedCommands: [],
            lingerEnabled: false)
        let text = CodexBarCLI.syncInstallTimerText(result, userName: "dev")
        #expect(text.contains("loginctl enable-linger dev"))
        #expect(text.contains("push lock"))
        #expect(text.contains("--uninstall"))

        var lingering = result
        lingering.lingerEnabled = true
        #expect(!CodexBarCLI.syncInstallTimerText(lingering, userName: "dev").contains("enable-linger"))
    }

    @Test
    func `uninstall text says when nothing was installed`() {
        let result = MachineSyncTimerResult(platform: .launchd, files: [], failedCommands: [], lingerEnabled: nil)
        #expect(CodexBarCLI.syncUninstallTimerText(result) == "No sync timer was installed.")
    }
}
