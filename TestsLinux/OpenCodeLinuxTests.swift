import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
@Suite
struct OpenCodeLinuxTests {
    @Test
    func `auto source and manual cookies do not require browser cookie import`() {
        let manual = ProviderSettingsSnapshot.make(
            opencode: .init(cookieSource: .manual, manualCookieHeader: "auth=manual", workspaceID: nil))

        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .opencode))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .opencode))
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .opencode, settings: manual))
    }

    @Test
    func `auto mode tries web first and then local history`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)

        let auto = await descriptor.fetchPlan.pipeline.resolveStrategies(Self.makeContext(sourceMode: .auto))
        let web = await descriptor.fetchPlan.pipeline.resolveStrategies(Self.makeContext(sourceMode: .web))

        #expect(auto.map(\.id) == ["opencode.web", "opencode.local"])
        #expect(web.map(\.id) == ["opencode.web"])
    }

    @Test
    func `web strategy falls back to local history only for missing browser cookies in auto mode`() {
        let strategy = OpenCodeUsageFetchStrategy()
        let auto = Self.makeContext(sourceMode: .auto)
        let web = Self.makeContext(sourceMode: .web)
        let manual = Self.makeContext(
            sourceMode: .auto,
            settings: ProviderSettingsSnapshot.make(
                opencode: .init(cookieSource: .manual, manualCookieHeader: "auth=manual", workspaceID: nil)))

        #expect(strategy.shouldFallback(on: OpenCodeSettingsError.missingCookie, context: auto))
        #expect(strategy.shouldFallback(on: OpenCodeSettingsError.invalidCookie, context: auto))
        #expect(strategy.shouldFallback(on: OpenCodeUsageError.invalidCredentials, context: auto))
        #expect(!strategy.shouldFallback(on: URLError(.timedOut), context: auto))
        #expect(!strategy.shouldFallback(on: OpenCodeSettingsError.missingCookie, context: web))
        #expect(!strategy.shouldFallback(on: OpenCodeUsageError.invalidCredentials, context: manual))
    }

    @Test
    func `local strategy hands reader errors to the next strategy`() {
        let strategy = OpenCodeLocalUsageFetchStrategy()
        let auto = Self.makeContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: OpenCodeLocalUsageError.notDetected, context: auto))
        #expect(!strategy.shouldFallback(on: URLError(.timedOut), context: auto))
    }

    @Test
    func `local reader loads OpenCode message costs into rolling and weekly windows`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.exec(at: env.databaseURL, sql: Self.messageTableSQL + Self.insertMessageSQL(
            id: "message-1",
            createdMs: createdMs,
            cost: "6"))

        let snapshot = try OpenCodeLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)

        #expect(snapshot.rollingUsagePercent == 50)
        #expect(snapshot.weeklyUsagePercent == 20)
        #expect(snapshot.rollingResetInSec == 5 * 60 * 60 - 60)
    }

    @Test
    func `local reader ignores other providers and counts step-finish parts for uncosted messages`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        let partData = "{\"type\":\"step-finish\",\"cost\":3,\"time\":{\"created\":\(createdMs)}}"
        try Self.exec(
            at: env.databaseURL,
            sql: Self.messageTableSQL
                + Self.partTableSQL
                + Self.insertMessageSQL(id: "message-1", createdMs: createdMs, cost: nil)
                + Self.insertMessageSQL(id: "message-2", createdMs: createdMs, cost: "9", provider: "opencode-go")
                + """
                INSERT INTO part (id, message_id, time_created, data)
                VALUES ('part-1', 'message-1', \(createdMs), '\(partData)');
                """)

        let snapshot = try OpenCodeLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 10)
    }

    @Test
    func `local reader reads a WAL database after a clean shutdown`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.exec(
            at: env.databaseURL,
            sql: "PRAGMA journal_mode=WAL;" + Self.messageTableSQL + Self.insertMessageSQL(
                id: "message-1",
                createdMs: createdMs,
                cost: "6"))
        #expect(!FileManager.default.fileExists(atPath: env.databaseURL.path + "-wal"))

        let snapshot = try OpenCodeLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)

        #expect(snapshot.rollingUsagePercent == 50)
    }

    @Test
    func `local reader reports missing history and missing installs`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reader = OpenCodeLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeLocalUsageError.notDetected) {
            _ = try reader.fetch()
        }

        try Data(#"{"opencode":{"type":"api","key":"oc-test"}}"#.utf8).write(to: env.authURL)
        #expect(throws: OpenCodeLocalUsageError.historyUnavailable("database not found")) {
            _ = try reader.fetch()
        }

        try Self.exec(at: env.databaseURL, sql: Self.messageTableSQL)
        #expect(throws: OpenCodeLocalUsageError.historyUnavailable("no local usage rows")) {
            _ = try reader.fetch()
        }
    }

    // MARK: - Fixtures

    private static let messageTableSQL =
        "CREATE TABLE message (id TEXT PRIMARY KEY, time_created INTEGER NOT NULL, data TEXT NOT NULL);"

    private static let partTableSQL = """
    CREATE TABLE part (
      id TEXT PRIMARY KEY, message_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
    """

    private static func insertMessageSQL(
        id: String,
        createdMs: Int64,
        cost: String?,
        provider: String = "opencode") -> String
    {
        let costField = cost.map { ",\"cost\":\($0)" } ?? ""
        let data = "{\"time\":{\"created\":\(createdMs)}\(costField),\"providerID\":\"\(provider)\","
            + "\"role\":\"assistant\"}"
        return "INSERT INTO message (id, time_created, data) VALUES ('\(id)', \(createdMs), '\(data)');"
    }

    private static func makeEnvironment() throws -> (root: URL, authURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLinuxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("auth.json"), root.appendingPathComponent("opencode.db"))
    }

    private static func exec(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw OpenCodeLocalUsageError.sqliteFailed("open failed")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalUsageError.sqliteFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func makeContext(
        sourceMode: ProviderSourceMode,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
#endif
