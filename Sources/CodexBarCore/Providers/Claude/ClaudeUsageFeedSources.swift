import CoreFoundation
import Foundation

// UsageBar: Claude quota readings from tools that run Claude Code without drawing its statusLine. See
// docs/claude-statusline-feed.md.
//
// The statusLine command only runs in Claude Code's interactive terminal UI. T3 Code drives Claude through the Agent
// SDK and Orca's agent view runs it headless, so neither feeds `codexbar claude statusline capture`. Both still see
// the same 5-hour and weekly windows:
//
// - T3 Code writes every SDK `rate_limit_event` to its provider event logs. Each event names the Claude Code session,
//   and that session's transcript opens with a `session-owner` line holding the account UUID, so a reading is only
//   used when it provably belongs to the account signed in now.
// - Orca keeps the last Claude usage it read and prints it from `orca-ide account list --json`. Only a reading made
//   with the system Claude sign-in (no Orca-managed account selected) counts, and only for the default profile.
//
// `ClaudeUsageFeedHarvester` copies the newest reading into the statusLine store when it is newer than what is there,
// so routing, freshness and the GNOME extension's health check treat every origin the same way.

/// One reading of the two windows, before it is bound to a profile and account.
public struct ClaudeUsageFeedReading: Equatable, Sendable {
    public let capturedAt: Date
    public let fiveHour: ClaudeStatusLineWindow?
    public let sevenDay: ClaudeStatusLineWindow?
    public let origin: ClaudeUsageFeedOrigin

    public init(
        capturedAt: Date,
        fiveHour: ClaudeStatusLineWindow?,
        sevenDay: ClaudeStatusLineWindow?,
        origin: ClaudeUsageFeedOrigin)
    {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.origin = origin
    }
}

public enum ClaudeUsageFeedHarvester {
    /// Writes the newest reading for the profile's signed-in account to the store when it is newer than the stored
    /// observation, and returns what it wrote. Readings older than the stale window, or from the future beyond the
    /// allowed clock skew, are ignored.
    @discardableResult
    public static func harvest(
        environment: [String: String],
        applicationSupport: URL,
        now: Date = Date(),
        t3LogsDirectory: URL? = nil,
        orcaInstances: [ClaudeOrcaFeedReader.Instance]? = nil,
        orcaRunner: ClaudeOrcaFeedReader.Runner = ClaudeOrcaFeedReader.defaultRunner) async
        -> ClaudeStatusLineRateLimits?
    {
        guard let accountUuid = ClaudeAccountProfile.accountUuid(environment: environment) else { return nil }
        let notBefore = now.addingTimeInterval(-ClaudeStatusLineDropStore.staleWindow)
        let home = ClaudeConfigPaths.homeDirectory(environment: environment)

        var readings: [ClaudeUsageFeedReading] = []
        if let reading = ClaudeT3CodeFeedReader.latest(
            logsDirectory: t3LogsDirectory ?? ClaudeT3CodeFeedReader.defaultLogsDirectory(home: home),
            projectsDirectory: ClaudeConfigPaths.configRoot(environment: environment)
                .appendingPathComponent("projects", isDirectory: true),
            accountUuid: accountUuid,
            notBefore: notBefore)
        {
            readings.append(reading)
        }
        if ClaudeOrcaFeedReader.readsProfile(environment: environment) {
            for instance in orcaInstances ?? ClaudeOrcaFeedReader.instances(environment: environment) {
                if let reading = await ClaudeOrcaFeedReader.latest(
                    instance: instance,
                    environment: environment,
                    runner: orcaRunner)
                {
                    readings.append(reading)
                }
            }
        }

        let latestAllowed = now.addingTimeInterval(ClaudeStatusLineDropStore.maximumClockSkew)
        guard let newest = readings
            .filter({ $0.capturedAt >= notBefore && $0.capturedAt <= latestAllowed })
            .max(by: { $0.capturedAt < $1.capturedAt })
        else { return nil }

        let profileID = ClaudeStatusLineProfile.identifier(environment: environment)
        let accountID = ClaudeStatusLineProfile.accountID(accountUuid: accountUuid)
        if let stored = ClaudeStatusLineDropStore.storedObservation(
            applicationSupport: applicationSupport,
            profileID: profileID),
            stored.accountID == accountID,
            stored.capturedAt >= newest.capturedAt
        {
            return nil
        }
        let observation = ClaudeStatusLineRateLimits(
            profileID: profileID,
            accountID: accountID,
            capturedAt: newest.capturedAt,
            fiveHour: newest.fiveHour,
            sevenDay: newest.sevenDay,
            origin: newest.origin)
        do {
            try ClaudeStatusLineDropStore.write(observation, applicationSupport: applicationSupport)
        } catch {
            return nil
        }
        // The GNOME extension judges the feed's health by the file's age; make it the reading's age.
        try? FileManager.default.setAttributes(
            [.modificationDate: newest.capturedAt],
            ofItemAtPath: ClaudeStatusLineDropStore.observationURL(
                applicationSupport: applicationSupport,
                profileID: profileID).path)
        return observation
    }
}

// MARK: - T3 Code

public enum ClaudeT3CodeFeedReader {
    /// Bytes read from the end of each log; rate-limit events are a few hundred bytes among much larger lines.
    static let tailBytes = 2 * 1024 * 1024
    /// Logs are one per thread; only the most recently written ones can hold the newest event.
    static let maximumFiles = 16
    /// Bytes read from the start of a transcript when looking for its `session-owner` line.
    static let transcriptHeadBytes = 64 * 1024
    static let eventMarker = "\"rate_limit_event\""

    public static func defaultLogsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".t3/userdata/logs/provider", isDirectory: true)
    }

    /// The newest `rate_limit_event` in T3 Code's provider logs whose session belongs to `accountUuid`.
    public static func latest(
        logsDirectory: URL,
        projectsDirectory: URL,
        accountUuid: String,
        notBefore: Date,
        fileManager: FileManager = .default) -> ClaudeUsageFeedReading?
    {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        else { return nil }
        let logs = entries.compactMap { url -> (url: URL, modified: Date)? in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= notBefore
            else { return nil }
            return (url, modified)
        }
        .sorted { $0.modified > $1.modified }
        .prefix(self.maximumFiles)

        let owners = SessionOwnerLookup(projectsDirectory: projectsDirectory, fileManager: fileManager)
        let expected = accountUuid.lowercased()
        var best: ClaudeUsageFeedReading?
        for log in logs {
            if let best, log.modified <= best.capturedAt { continue }
            guard let tail = self.readTail(of: log.url) else { continue }
            for line in self.lines(tail).reversed() where line.contains(self.eventMarker) {
                guard let event = self.parseEvent(line) else { continue }
                if event.reading.capturedAt < notBefore { break }
                guard owners.owner(of: event.sessionID) == expected else { continue }
                if best.map({ event.reading.capturedAt > $0.capturedAt }) ?? true {
                    best = event.reading
                }
                break
            }
        }
        return best
    }

    struct Event {
        let reading: ClaudeUsageFeedReading
        let sessionID: String
    }

    /// One log line: `[<ISO 8601 time>] <tag>: {"event":{"payload":{"type":"rate_limit_event",...}}}`.
    static func parseEvent(_ line: Substring) -> Event? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]"),
              let capturedAt = self.parseTimestamp(String(line[line.index(after: line.startIndex)..<close])),
              let brace = line[close...].firstIndex(of: "{"),
              let root = try? JSONSerialization.jsonObject(with: Data(line[brace...].utf8)) as? [String: Any],
              let event = root["event"] as? [String: Any],
              let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "rate_limit_event",
              let info = payload["rate_limit_info"] as? [String: Any],
              let sessionID = payload["session_id"] as? String
        else { return nil }

        var fiveHour: ClaudeStatusLineWindow?
        var sevenDay: ClaudeStatusLineWindow?
        if let unified = info["unifiedWindows"] as? [String: Any] {
            fiveHour = self.window(unified["five_hour"])
            sevenDay = self.window(unified["seven_day"])
        } else {
            switch info["rateLimitType"] as? String {
            case "five_hour": fiveHour = self.window(info)
            case "seven_day": sevenDay = self.window(info)
            default: break
            }
        }
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return Event(
            reading: ClaudeUsageFeedReading(
                capturedAt: capturedAt,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                origin: .t3Code),
            sessionID: sessionID)
    }

    /// `utilization` is a fraction (0.03 is 3%); `resetsAt` is epoch seconds.
    private static func window(_ raw: Any?) -> ClaudeStatusLineWindow? {
        guard let object = raw as? [String: Any],
              let utilization = ClaudeUsageFeedNumbers.finite(object["utilization"]),
              utilization >= 0
        else { return nil }
        return ClaudeStatusLineWindow(
            usedPercent: min(utilization, 1) * 100,
            resetsAt: ClaudeUsageFeedNumbers.resetDate(seconds: ClaudeUsageFeedNumbers.finite(object["resetsAt"])))
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func readTail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(self.tailBytes) ? size - UInt64(self.tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        // A tail that starts mid-line drops the partial first line.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            return data[data.index(after: newline)...]
        }
        return data
    }

    /// The UTF-8 lines of `data`. A line cut mid-character (at the edge of a partial read) is skipped.
    static func lines(_ data: Data) -> [Substring] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { bytes in
            String(bytes: bytes, encoding: .utf8).map { Substring($0) }
        }
    }

    /// Finds the account that owns a Claude Code session from its transcript's `session-owner` line.
    final class SessionOwnerLookup {
        private let projectsDirectory: URL
        private let fileManager: FileManager
        private var projectDirectories: [URL]?
        private var owners: [String: String?] = [:]

        init(projectsDirectory: URL, fileManager: FileManager) {
            self.projectsDirectory = projectsDirectory
            self.fileManager = fileManager
        }

        /// The lowercased account UUID, or nil when no transcript in this profile proves an owner.
        func owner(of sessionID: String) -> String? {
            if let cached = self.owners[sessionID] { return cached }
            let owner = self.lookUp(sessionID)
            self.owners[sessionID] = owner
            return owner
        }

        private func lookUp(_ sessionID: String) -> String? {
            // Session ids are UUIDs; anything else could escape the projects directory.
            guard !sessionID.isEmpty,
                  sessionID.count <= 64,
                  sessionID.allSatisfy({ $0.isHexDigit || $0 == "-" })
            else { return nil }
            let directories = self.projectDirectories ?? ((try? self.fileManager.contentsOfDirectory(
                at: self.projectsDirectory,
                includingPropertiesForKeys: nil)) ?? [])
            self.projectDirectories = directories
            for directory in directories {
                let transcript = directory.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
                guard self.fileManager.fileExists(atPath: transcript.path) else { continue }
                return Self.owner(inTranscript: transcript)
            }
            return nil
        }

        private static func owner(inTranscript url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: ClaudeT3CodeFeedReader.transcriptHeadBytes) else {
                return nil
            }
            for line in ClaudeT3CodeFeedReader.lines(data) where line.contains("\"session-owner\"") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "session-owner",
                      let uuid = object["accountUuid"] as? String,
                      !uuid.isEmpty
                else { continue }
                return uuid.lowercased()
            }
            return nil
        }
    }
}

// MARK: - Orca

public enum ClaudeOrcaFeedReader {
    public struct Instance: Equatable, Sendable {
        public let origin: ClaudeUsageFeedOrigin
        /// The Orca user-data directory the CLI is pointed at (`ORCA_USER_DATA_PATH`).
        public let userDataDirectory: URL
        /// CLI names tried in order on `PATH`.
        public let commands: [String]

        public init(origin: ClaudeUsageFeedOrigin, userDataDirectory: URL, commands: [String]) {
            self.origin = origin
            self.userDataDirectory = userDataDirectory
            self.commands = commands
        }
    }

    public typealias Runner = @Sendable (_ binary: String, _ arguments: [String], _ environment: [String: String])
        async -> Data?

    static let timeout: TimeInterval = 5
    static let maximumOutputBytes = 1024 * 1024
    /// Variables a terminal inside Orca sets that would point the CLI at that session's Orca instead.
    static let inheritedSessionKeys = [
        "ORCA_CLI_COMMAND",
        "ORCA_CLI_HANDOFF",
        "ORCA_DEV_CLI_INVOCATION",
        "ORCA_DEV_USER_DATA_PATH",
        "ORCA_USER_DATA_PATH",
    ]

    public static let defaultRunner: Runner = { binary, arguments, environment in
        guard let result = try? await SubprocessRunner.run(
            binary: binary,
            arguments: arguments,
            environment: environment,
            timeout: ClaudeOrcaFeedReader.timeout,
            maxOutputBytes: ClaudeOrcaFeedReader.maximumOutputBytes,
            label: "orca-account-list")
        else { return nil }
        return Data(result.stdout.utf8)
    }

    /// Orca reads Claude with the system sign-in, which lives in the default profile; a profile picked with
    /// `CLAUDE_CONFIG_DIR` may be another account.
    public static func readsProfile(environment: [String: String]) -> Bool {
        environment[ClaudeConfigPaths.configDirectoryEnvironmentKey]?.isEmpty ?? true
    }

    /// The release build (`~/.config/orca`, `orca-ide`) and the development build (`~/.config/orca-dev`, `orca-dev`).
    /// The release CLI reaches either instance when `ORCA_USER_DATA_PATH` names its directory.
    public static func instances(environment: [String: String]) -> [Instance] {
        let home = ClaudeConfigPaths.homeDirectory(environment: environment)
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return [
            Instance(
                origin: .orca,
                userDataDirectory: configHome.appendingPathComponent("orca", isDirectory: true),
                commands: ["orca-ide"]),
            Instance(
                origin: .orcaDev,
                userDataDirectory: configHome.appendingPathComponent("orca-dev", isDirectory: true),
                commands: ["orca-dev", "orca-ide"]),
        ]
    }

    /// Orca's last Claude reading, when that instance is running and read Claude with the system sign-in.
    public static func latest(
        instance: Instance,
        environment: [String: String],
        runner: Runner,
        fileManager: FileManager = .default) async -> ClaudeUsageFeedReading?
    {
        // Without runtime metadata the CLI can only report that Orca is not running.
        let runtime = instance.userDataDirectory.appendingPathComponent("orca-runtime.json", isDirectory: false)
        guard fileManager.fileExists(atPath: runtime.path),
              let binary = self.binary(for: instance, environment: environment, fileManager: fileManager)
        else { return nil }
        var launchEnvironment = environment
        for key in self.inheritedSessionKeys {
            launchEnvironment.removeValue(forKey: key)
        }
        launchEnvironment["ORCA_USER_DATA_PATH"] = instance.userDataDirectory.path
        if instance.origin == .orcaDev {
            launchEnvironment["ORCA_DEV_USER_DATA_PATH"] = instance.userDataDirectory.path
        }
        guard let data = await runner(binary, ["account", "list", "--json"], launchEnvironment) else { return nil }
        return self.parse(data, origin: instance.origin)
    }

    /// Reads `result.rateLimits.claude` from `orca-ide account list --json`.
    static func parse(_ data: Data, origin: ClaudeUsageFeedOrigin) -> ClaudeUsageFeedReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let result = root["result"] as? [String: Any],
              let accounts = result["claude"] as? [String: Any],
              self.usesSystemSignIn(accounts),
              let rateLimits = result["rateLimits"] as? [String: Any],
              let claude = rateLimits["claude"] as? [String: Any],
              claude["status"] as? String == "ok",
              self.isAbsent(claude["error"]),
              let metadata = claude["usageMetadata"] as? [String: Any],
              metadata["authProvenance"] as? String == "system",
              let updatedAt = ClaudeUsageFeedNumbers.finite(claude["updatedAt"]),
              updatedAt > 0
        else { return nil }
        let fiveHour = self.window(claude["session"], minutes: 300)
        let sevenDay = self.window(claude["weekly"], minutes: 10080)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeUsageFeedReading(
            capturedAt: Date(timeIntervalSince1970: updatedAt / 1000),
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            origin: origin)
    }

    /// No Orca-managed Claude account is selected, so Orca read the same sign-in Claude Code uses.
    private static func usesSystemSignIn(_ accounts: [String: Any]) -> Bool {
        guard self.isAbsent(accounts["activeAccountId"]) else { return false }
        if let byRuntime = accounts["activeAccountIdsByRuntime"] as? [String: Any] {
            return self.isAbsent(byRuntime["host"])
        }
        return true
    }

    private static func window(_ raw: Any?, minutes: Int) -> ClaudeStatusLineWindow? {
        guard let object = raw as? [String: Any],
              let used = ClaudeUsageFeedNumbers.finite(object["usedPercent"]),
              (0...100).contains(used)
        else { return nil }
        if let windowMinutes = ClaudeUsageFeedNumbers.finite(object["windowMinutes"]),
           Int(windowMinutes) != minutes
        {
            return nil
        }
        let resetMilliseconds = ClaudeUsageFeedNumbers.finite(object["resetsAt"])
        return ClaudeStatusLineWindow(
            usedPercent: used,
            resetsAt: ClaudeUsageFeedNumbers.resetDate(seconds: resetMilliseconds.map { $0 / 1000 }))
    }

    private static func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func binary(
        for instance: Instance,
        environment: [String: String],
        fileManager: FileManager) -> String?
    {
        let home = ClaudeConfigPaths.homeDirectory(environment: environment)
        var directories = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        // The Orca AppImage registers its CLI here; a desktop session's PATH may not include it.
        directories.append(home.appendingPathComponent(".local/bin", isDirectory: true).path)
        for command in instance.commands {
            if let found = BinaryLocator.find(command, in: directories, fileManager: fileManager) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Numbers

enum ClaudeUsageFeedNumbers {
    static func finite(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    static func resetDate(seconds: Double?) -> Date? {
        guard let seconds, ClaudeStatusLineFeed.validResetEpochSecondsRange.contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
