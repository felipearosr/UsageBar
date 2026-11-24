import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeUsageFeedSourcesLinuxTests {
    private static let account = "B034059D-753C-4A3F-859C-AF1A92F54E5C"
    private static let otherAccount = "11111111-2222-3333-4444-555555555555"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: T3 Code

    @Test
    func `a T3 Code rate-limit event yields both unified windows as percentages`() throws {
        let line = Self.t3Line(at: "2027-01-15T08:00:00.250Z", session: "aaaa-1", five: 0.47, seven: 0.39)
        let event = try #require(ClaudeT3CodeFeedReader.parseEvent(Substring(line)))
        #expect(event.sessionID == "aaaa-1")
        #expect(event.reading.origin == .t3Code)
        #expect(event.reading.capturedAt == Date(timeIntervalSince1970: 1_800_000_000.25))
        #expect(event.reading.fiveHour == ClaudeStatusLineWindow(
            usedPercent: 47, resetsAt: Date(timeIntervalSince1970: 1_800_010_000)))
        #expect(event.reading.sevenDay?.usedPercent == 39)
    }

    @Test
    func `a T3 Code event without unified windows falls back to its single typed window`() throws {
        let line = """
        [2027-01-15T08:00:00.000Z] NATIVE: {"event":{"payload":{"type":"rate_limit_event","session_id":"ab",\
        "rate_limit_info":{"status":"allowed","rateLimitType":"seven_day","utilization":0.82,\
        "resetsAt":1800500000}}}}
        """
        let event = try #require(ClaudeT3CodeFeedReader.parseEvent(Substring(line)))
        #expect(event.reading.fiveHour == nil)
        #expect(event.reading.sevenDay?.usedPercent == 82)
    }

    @Test
    func `T3 Code lines that are not rate-limit events or carry no usable window are ignored`() {
        let assistant = """
        [2027-01-15T08:00:00.000Z] NATIVE: {"event":{"payload":{"type":"assistant","session_id":"ab",\
        "text":"\\"rate_limit_event\\""}}}
        """
        let statusOnly = """
        [2027-01-15T08:00:00.000Z] NATIVE: {"event":{"payload":{"type":"rate_limit_event","session_id":"ab",\
        "rate_limit_info":{"status":"allowed","rateLimitType":"seven_day"}}}}
        """
        #expect(ClaudeT3CodeFeedReader.parseEvent(Substring(assistant)) == nil)
        #expect(ClaudeT3CodeFeedReader.parseEvent(Substring(statusOnly)) == nil)
        #expect(ClaudeT3CodeFeedReader.parseEvent("not a log line") == nil)
    }

    @Test
    func `the T3 Code reader takes the newest event of a session the signed-in account owns`() throws {
        let home = try Home()
        try home.transcript(session: "aaaa-1", owner: Self.account)
        try home.transcript(session: "bbbb-2", owner: Self.otherAccount)
        try home.transcript(session: "cccc-3", owner: Self.account)
        // Older file, but its last owned event is the newest overall.
        try home.t3Log("events.one.log", modified: Self.now.addingTimeInterval(-60), lines: [
            Self.t3Line(at: "2027-01-15T07:50:00.000Z", session: "aaaa-1", five: 0.10, seven: 0.20),
            Self.t3Line(at: "2027-01-15T07:59:00.000Z", session: "cccc-3", five: 0.30, seven: 0.40),
        ])
        // Newest file: its last event belongs to another account and must be skipped.
        try home.t3Log("events.two.log", modified: Self.now, lines: [
            Self.t3Line(at: "2027-01-15T07:55:00.000Z", session: "aaaa-1", five: 0.25, seven: 0.35),
            Self.t3Line(at: "2027-01-15T07:59:30.000Z", session: "bbbb-2", five: 0.99, seven: 0.99),
            #"[2027-01-15T07:59:40.000Z] NATIVE: {"event":{"payload":{"type":"assistant"}}}"#,
        ])
        let reading = try #require(ClaudeT3CodeFeedReader.latest(
            logsDirectory: home.t3Logs,
            projectsDirectory: home.projects,
            accountUuid: Self.account,
            notBefore: Self.now.addingTimeInterval(-ClaudeStatusLineDropStore.staleWindow)))
        #expect(reading.capturedAt == Self.date("2027-01-15T07:59:00.000Z"))
        #expect(reading.fiveHour?.usedPercent == 30)
    }

    @Test
    func `the T3 Code reader refuses sessions it cannot attribute and events older than the window`() throws {
        let home = try Home()
        try home.transcript(session: "aaaa-1", owner: nil)
        try home.transcript(session: "dddd-4", owner: Self.account)
        try home.t3Log("events.one.log", modified: Self.now, lines: [
            Self.t3Line(at: "2027-01-15T01:00:00.000Z", session: "dddd-4", five: 0.5, seven: 0.5),
            Self.t3Line(at: "2027-01-15T07:00:00.000Z", session: "aaaa-1", five: 0.5, seven: 0.5),
            Self.t3Line(at: "2027-01-15T07:30:00.000Z", session: "../../etc/passwd", five: 0.5, seven: 0.5),
            Self.t3Line(at: "2027-01-15T07:40:00.000Z", session: "eeee-5", five: 0.5, seven: 0.5),
        ])
        #expect(ClaudeT3CodeFeedReader.latest(
            logsDirectory: home.t3Logs,
            projectsDirectory: home.projects,
            accountUuid: Self.account,
            notBefore: Self.now.addingTimeInterval(-ClaudeStatusLineDropStore.staleWindow)) == nil)
    }

    // MARK: Orca

    @Test
    func `Orca's reading counts only with the system sign-in and an ok status`() throws {
        let reading = try #require(ClaudeOrcaFeedReader.parse(Self.orcaJSON(), origin: .orca))
        #expect(reading.origin == .orca)
        #expect(reading.capturedAt == Date(timeIntervalSince1970: 1_799_999_900))
        #expect(reading.fiveHour == nil)
        #expect(reading.sevenDay == ClaudeStatusLineWindow(
            usedPercent: 4, resetsAt: Date(timeIntervalSince1970: 1_800_500_000)))

        let session = try #require(ClaudeOrcaFeedReader.parse(
            Self.orcaJSON(session: #"{"usedPercent":12,"windowMinutes":300,"resetsAt":1800010000000}"#),
            origin: .orcaDev))
        #expect(session.fiveHour?.usedPercent == 12)
        #expect(session.origin == .orcaDev)

        #expect(ClaudeOrcaFeedReader.parse(Self.orcaJSON(activeAccount: #""acct-1""#), origin: .orca) == nil)
        #expect(ClaudeOrcaFeedReader.parse(Self.orcaJSON(hostAccount: #""acct-1""#), origin: .orca) == nil)
        #expect(ClaudeOrcaFeedReader.parse(Self.orcaJSON(status: "error"), origin: .orca) == nil)
        #expect(ClaudeOrcaFeedReader.parse(Self.orcaJSON(provenance: "managed"), origin: .orca) == nil)
        #expect(ClaudeOrcaFeedReader.parse(Self.orcaJSON(ok: false), origin: .orca) == nil)
        #expect(ClaudeOrcaFeedReader.parse(
            Self.orcaJSON(weekly: #"{"usedPercent":4,"windowMinutes":300,"resetsAt":1800500000000}"#),
            origin: .orca) == nil)
    }

    @Test
    func `Orca is only asked when that instance is running, pointed at its own data`() async throws {
        let home = try Home(defaultProfile: true)
        let bin = home.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("orca-ide")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        var env = home.env
        env["PATH"] = bin.path
        env["ORCA_USER_DATA_PATH"] = "/somewhere/else"
        env["ORCA_CLI_COMMAND"] = "/somewhere/else/orca"

        let instances = ClaudeOrcaFeedReader.instances(environment: env)
        #expect(instances.map(\.origin) == [.orca, .orcaDev])
        let calls = Calls()
        let runner: ClaudeOrcaFeedReader.Runner = { binary, arguments, environment in
            calls.append(binary: binary, arguments: arguments, environment: environment)
            return Self.orcaJSON()
        }

        #expect(await ClaudeOrcaFeedReader.latest(instance: instances[1], environment: env, runner: runner) == nil)
        #expect(calls.all.isEmpty)

        try FileManager.default.createDirectory(at: instances[1].userDataDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: instances[1].userDataDirectory.appendingPathComponent("orca-runtime.json"))
        let reading = await ClaudeOrcaFeedReader.latest(instance: instances[1], environment: env, runner: runner)
        #expect(reading?.origin == .orcaDev)
        let call = try #require(calls.all.first)
        // No `orca-dev` on PATH: the release CLI reaches the dev build through its data directory.
        #expect(call.binary == cli.path)
        #expect(call.arguments == ["account", "list", "--json"])
        #expect(call.environment["ORCA_USER_DATA_PATH"] == instances[1].userDataDirectory.path)
        #expect(call.environment["ORCA_DEV_USER_DATA_PATH"] == instances[1].userDataDirectory.path)
        #expect(call.environment["ORCA_CLI_COMMAND"] == nil)
    }

    // MARK: Harvester

    @Test
    func `the harvester stores the newest reading with its origin and dates the file by it`() async throws {
        let home = try Home(defaultProfile: true)
        try home.transcript(session: "aaaa-1", owner: Self.account)
        try home.t3Log("events.one.log", modified: Self.now, lines: [
            Self.t3Line(at: "2027-01-15T07:59:00.000Z", session: "aaaa-1", five: 0.47, seven: 0.39),
        ])
        let orca = try home.orcaInstance()
        let written = try #require(await ClaudeUsageFeedHarvester.harvest(
            environment: home.env,
            applicationSupport: home.support,
            now: Self.now,
            t3LogsDirectory: home.t3Logs,
            orcaInstances: [orca],
            orcaRunner: { _, _, _ in Self.orcaJSON() }))
        // T3 Code's event (07:59:00) is newer than Orca's reading (07:58:20).
        #expect(written.origin == .t3Code)
        #expect(written.fiveHour?.usedPercent == 47)

        // Orca's next reading (07:59:50) is newer still and replaces it.

        let fromOrca = try #require(await ClaudeUsageFeedHarvester.harvest(
            environment: home.env,
            applicationSupport: home.support,
            now: Self.now,
            t3LogsDirectory: home.t3Logs,
            orcaInstances: [orca],
            orcaRunner: { _, _, _ in Self.orcaJSON(updatedAt: 1_799_999_990_000) }))
        #expect(fromOrca.origin == .orca)
        #expect(fromOrca.accountID == ClaudeStatusLineProfile.accountID(accountUuid: Self.account))

        let url = ClaudeStatusLineDropStore.observationURL(
            applicationSupport: home.support,
            profileID: ClaudeStatusLineProfile.identifier(environment: home.env))
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(fromOrca.capturedAt)) < 1)
        let loaded = ClaudeStatusLineDropStore.load(
            applicationSupport: home.support,
            expectedProfileID: fromOrca.profileID,
            expectedAccountID: fromOrca.accountID,
            now: Self.now)
        #expect(loaded?.resolvedOrigin == .orca)
        #expect(ClaudeSwapStatusLineOverride.sourceLabel(for: fromOrca, now: Self.now) == "orca")
    }

    @Test
    func `the harvester never replaces a newer capture`() async throws {
        let home = try Home(defaultProfile: true)
        let profileID = ClaudeStatusLineProfile.identifier(environment: home.env)
        let accountID = ClaudeStatusLineProfile.accountID(accountUuid: Self.account)
        let statusLine = ClaudeStatusLineRateLimits(
            profileID: profileID,
            accountID: accountID,
            capturedAt: Self.now.addingTimeInterval(-10),
            fiveHour: nil,
            sevenDay: ClaudeStatusLineWindow(usedPercent: 50, resetsAt: nil),
            origin: .statusLine)
        try ClaudeStatusLineDropStore.write(statusLine, applicationSupport: home.support)
        let orca = try home.orcaInstance()
        let written = await ClaudeUsageFeedHarvester.harvest(
            environment: home.env,
            applicationSupport: home.support,
            now: Self.now,
            t3LogsDirectory: home.t3Logs,
            orcaInstances: [orca],
            orcaRunner: { _, _, _ in Self.orcaJSON() })
        #expect(written == nil)
        #expect(ClaudeStatusLineDropStore.storedObservation(applicationSupport: home.support, profileID: profileID)
            == statusLine)
    }

    @Test
    func `Orca is not read for a profile chosen with CLAUDE_CONFIG_DIR`() async throws {
        let home = try Home(defaultProfile: false)
        let calls = Calls()
        let orca = try home.orcaInstance()
        let written = await ClaudeUsageFeedHarvester.harvest(
            environment: home.env,
            applicationSupport: home.support,
            now: Self.now,
            t3LogsDirectory: home.t3Logs,
            orcaInstances: [orca],
            orcaRunner: { binary, arguments, environment in
                calls.append(binary: binary, arguments: arguments, environment: environment)
                return Self.orcaJSON()
            })
        #expect(written == nil)
        #expect(calls.all.isEmpty)
    }

    @Test
    func `feed source labels cover every origin`() {
        #expect(ClaudeStatusLineFeed.isFeedSourceLabel("t3code"))
        #expect(ClaudeStatusLineFeed.isFeedSourceLabel("orca-dev-stale"))
        #expect(!ClaudeStatusLineFeed.isFeedSourceLabel("oauth"))
        #expect(ClaudeStatusLineFeed.isStaleFeedSourceLabel("statusline-stale"))
        #expect(!ClaudeStatusLineFeed.isStaleFeedSourceLabel("orca"))
        #expect(ClaudeStatusLineFeed.staleFeedSourceLabel(for: "orca") == "orca-stale")
        #expect(ClaudeStatusLineFeed.staleFeedSourceLabel(for: "claude-swap") == nil)
    }

    @Test
    func `a capture written before origins existed reads as the statusLine`() throws {
        let home = try Home(defaultProfile: true)
        let profileID = ClaudeStatusLineProfile.identifier(environment: home.env)
        let url = ClaudeStatusLineDropStore.observationURL(applicationSupport: home.support, profileID: profileID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("""
        {"observation":{"accountID":"x","capturedAt":1800000000,"profileID":"\(profileID)",
         "sevenDay":{"resetsAt":1800500000,"usedPercent":39}},"schema":2}
        """.utf8).write(to: url)
        let stored = try #require(ClaudeStatusLineDropStore.storedObservation(
            applicationSupport: home.support,
            profileID: profileID))
        #expect(stored.origin == nil)
        #expect(stored.resolvedOrigin == .statusLine)
    }

    // MARK: Helpers

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    private static func t3Line(at time: String, session: String, five: Double, seven: Double) -> String {
        """
        [\(time)] NATIVE: {"provider":"claudeAgent","event":{"direction":"incoming","payload":\
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1800010000,\
        "rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":\(five),"resetsAt":1800010000,\
        "status":"allowed"},"seven_day":{"utilization":\(seven),"resetsAt":1800500000,"status":"allowed"}}},\
        "uuid":"u","session_id":"\(session)"}}}
        """
    }

    private static func orcaJSON(
        ok: Bool = true,
        activeAccount: String = "null",
        hostAccount: String = "null",
        status: String = "ok",
        provenance: String = "system",
        updatedAt: Double = 1_799_999_900_000,
        session: String = "null",
        weekly: String = #"{"usedPercent":4,"windowMinutes":10080,"resetsAt":1800500000000}"#) -> Data
    {
        Data("""
        {"id":"x","ok":\(ok),"result":{
          "claude":{"accounts":[],"activeAccountId":\(activeAccount),
                    "activeAccountIdsByRuntime":{"host":\(hostAccount),"wsl":{}}},
          "rateLimits":{"claude":{"provider":"claude","session":\(session),"weekly":\(weekly),
            "fableWeekly":{"usedPercent":2,"windowMinutes":10080,"resetsAt":1800500000000},
            "updatedAt":\(updatedAt),"error":null,"status":"\(status)","planType":"max_20x",
            "usageMetadata":{"credentialSource":"credentials-file","authProvenance":"\(provenance)"}}}}}
        """.utf8)
    }

    private final class Calls: @unchecked Sendable {
        struct Call {
            let binary: String
            let arguments: [String]
            let environment: [String: String]
        }

        private let lock = NSLock()
        private var calls: [Call] = []

        var all: [Call] {
            self.lock.withLock { self.calls }
        }

        func append(binary: String, arguments: [String], environment: [String: String]) {
            self.lock
                .withLock { self.calls.append(Call(binary: binary, arguments: arguments, environment: environment)) }
        }
    }

    private struct Home {
        let root: URL
        let support: URL
        let projects: URL
        let t3Logs: URL
        let env: [String: String]

        /// A home whose Claude account is `ClaudeUsageFeedSourcesLinuxTests.account`, in the default profile or in one
        /// chosen with `CLAUDE_CONFIG_DIR`.
        init(defaultProfile: Bool = true) throws {
            let fileManager = FileManager.default
            self.root = fileManager.temporaryDirectory
                .appendingPathComponent("usage-feed-\(UUID().uuidString)", isDirectory: true)
            self.support = self.root.appendingPathComponent("support", isDirectory: true)
            self.t3Logs = self.root.appendingPathComponent(".t3/userdata/logs/provider", isDirectory: true)
            let configDir = self.root.appendingPathComponent(
                defaultProfile ? ".claude" : "profile",
                isDirectory: true)
            self.projects = configDir.appendingPathComponent("projects", isDirectory: true)
            try fileManager.createDirectory(at: self.projects, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: self.t3Logs, withIntermediateDirectories: true)
            let account = Data(#"{"oauthAccount":{"accountUuid":"\#(ClaudeUsageFeedSourcesLinuxTests.account)"}}"#
                .utf8)
            if defaultProfile {
                try account.write(to: self.root.appendingPathComponent(".claude.json"))
                self.env = ["HOME": self.root.path, "XDG_CONFIG_HOME": self.root.appendingPathComponent(".config").path]
            } else {
                try account.write(to: configDir.appendingPathComponent(".claude.json"))
                self.env = [
                    "HOME": self.root.path,
                    "CLAUDE_CONFIG_DIR": configDir.path,
                    "XDG_CONFIG_HOME": self.root.appendingPathComponent(".config").path,
                ]
            }
        }

        func transcript(session: String, owner: String?) throws {
            let directory = self.projects.appendingPathComponent("-home-u-\(session)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var lines = [#"{"type":"custom-title","customTitle":"t","sessionId":"\#(session)"}"#]
            if let owner {
                lines.append(#"{"type":"session-owner","accountUuid":"\#(owner)","sessionId":"\#(session)"}"#)
            }
            try Data(lines.joined(separator: "\n").utf8)
                .write(to: directory.appendingPathComponent("\(session).jsonl"))
        }

        func t3Log(_ name: String, modified: Date, lines: [String]) throws {
            let url = self.t3Logs.appendingPathComponent(name)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        /// A running Orca instance (runtime metadata present) under this home.
        func orcaInstance() throws -> ClaudeOrcaFeedReader.Instance {
            let directory = self.root.appendingPathComponent(".config/orca", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("orca-runtime.json"))
            let bin = self.root.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let cli = bin.appendingPathComponent("orca-ide")
            try Data("#!/bin/sh\n".utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
            return ClaudeOrcaFeedReader.Instance(origin: .orca, userDataDirectory: directory, commands: ["orca-ide"])
        }
    }
}
