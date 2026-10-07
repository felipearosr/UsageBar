import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
@Suite
struct OpenCodeLinuxTests {
    @Test
    func autoSourceDoesNotRequireWebSupport() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(.auto, provider: .opencode))
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(.web, provider: .opencode))
    }

    @Test
    func localReaderLoadsOpenCodeDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLinuxTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let databaseURL = root.appendingPathComponent("opencode.db")
        let authURL = root.appendingPathComponent("auth.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let createdMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        try Self.createDatabase(at: databaseURL, createdMs: createdMs)

        let snapshot = try OpenCodeLocalUsageReader(authURL: authURL, databaseURL: databaseURL).fetch(now: now)

        #expect(snapshot.rollingUsagePercent == 50)
        #expect(snapshot.weeklyUsagePercent == 20)
    }

    private static func createDatabase(at url: URL, createdMs: Int64) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw OpenCodeLocalUsageError.sqliteFailed("open failed")
        }
        defer { sqlite3_close(database) }

        let data = "{\"time\":{\"created\":\(createdMs)},\"cost\":6,\"providerID\":\"opencode\",\"role\":\"assistant\"}"
        let sql = """
        CREATE TABLE message (id TEXT PRIMARY KEY, time_created INTEGER NOT NULL, data TEXT NOT NULL);
        INSERT INTO message (id, time_created, data) VALUES ('message-1', \(createdMs), '\(data)');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeLocalUsageError.sqliteFailed("fixture creation failed")
        }
    }
}
#endif
