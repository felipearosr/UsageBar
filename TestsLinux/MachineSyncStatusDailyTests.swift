import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct MachineSyncStatusDailyTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)
    private static let laptopID = "oKGio6SlpqeoqaqrrK2urw"
    private static let deskID = "AAAAAAAAAAAAAAAAAAAAAA"

    private static func bucket(
        _ hour: Int,
        _ provider: String,
        _ model: String,
        cost: Double?) -> MachineSyncDayBlob.Bucket
    {
        .init(
            hour: hour,
            provider: provider,
            model: model,
            costUSD: cost,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 10,
            cacheCreationTokens: 5,
            totalTokens: 135,
            requests: 3)
    }

    /// Two Machines, several providers and models, priced and unpriced buckets, and buckets on both sides of a
    /// Reporting Day boundary (UTC, days starting at 04:00).
    private static func cache(retentionDays: Int? = 400) -> MachineSyncCache {
        var cache = MachineSyncCache(groupID: "g")
        cache.retentionDays = retentionDays
        var laptop = MachineSyncCache.Machine(lastSeen: Self.now.addingTimeInterval(-60))
        laptop.profile = MachineSyncProfile(
            displayName: "laptop",
            platform: "linux",
            clientVersion: "0.24.0",
            coverageStart: "2026-06-01",
            pushedAt: nil)
        laptop.days = [
            // 91 Reporting Days back: outside the 90-day window.
            "2026-06-26": MachineSyncDayBlob(buckets: [Self.bucket(10, "claude", "claude-sonnet-4-5", cost: 8)]),
            // Oldest Reporting Day inside the window.
            "2026-06-27": MachineSyncDayBlob(buckets: [Self.bucket(10, "claude", "claude-sonnet-4-5", cost: 1)]),
            "2026-08-24": MachineSyncDayBlob(buckets: [Self.bucket(10, "codex", "gpt-5", cost: 0.5)]),
            "2026-08-25": MachineSyncDayBlob(buckets: [Self.bucket(10, "codex", "gpt-5", cost: 0.75)]),
            // Only unpriced Spend.
            "2026-09-20": MachineSyncDayBlob(buckets: [Self.bucket(10, "codex", "gpt-5", cost: nil)]),
            "2026-09-23": MachineSyncDayBlob(buckets: [Self.bucket(10, "codex", "gpt-5", cost: nil)]),
            "2026-09-24": MachineSyncDayBlob(buckets: [
                // 03:00 is before the 04:00 day start, so it belongs to the 23rd.
                Self.bucket(3, "codex", "gpt-5", cost: 1),
                Self.bucket(9, "claude", "claude-sonnet-4-5", cost: 2),
                Self.bucket(9, "claude", "claude-opus-4-1", cost: 5),
                Self.bucket(10, "codex", "gpt-5", cost: 0.25),
            ]),
        ]
        var desk = MachineSyncCache.Machine(lastSeen: Self.now.addingTimeInterval(-7200))
        desk.profile = MachineSyncProfile(
            displayName: "desk",
            platform: "macos",
            clientVersion: "0.24.0",
            coverageStart: "2026-09-24",
            pushedAt: nil)
        desk.days = [
            "2026-09-24": MachineSyncDayBlob(buckets: [
                Self.bucket(12, "claude", "claude-sonnet-4-5", cost: 0.5),
                Self.bucket(13, "gemini", "gemini-2.5-pro", cost: nil),
            ]),
        ]
        cache.machines[Self.laptopID] = laptop
        cache.machines[Self.deskID] = desk
        return cache
    }

    private static func status(_ cache: MachineSyncCache) -> MachineSyncStatus {
        MachineSyncStatus(
            cache: cache,
            thisMachineID: self.laptopID,
            reportingDay: MachineSyncReportingDay(timeZone: "UTC", startHour: 4),
            now: self.now)
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(data: encoder.encode(value), encoding: .utf8))
    }

    private static func model(_ name: String, cost: String, buckets: Int) -> String {
        "{\"cost\":\(cost),\"modelName\":\"\(name)\",\"totalTokens\":\(135 * buckets)}"
    }

    private static func provider(
        _ id: String,
        cost: String,
        incomplete: Bool,
        buckets: Int,
        models: [String]) -> String
    {
        "{\"cacheCreationTokens\":\(5 * buckets),\"cacheReadTokens\":\(10 * buckets),"
            + "\"costIncomplete\":\(incomplete),\"inputTokens\":\(100 * buckets),"
            + "\"modelBreakdowns\":[\(models.joined(separator: ","))],\"outputTokens\":\(20 * buckets),"
            + "\"provider\":\"\(id)\",\"requests\":\(3 * buckets),\"totalCost\":\(cost),"
            + "\"totalTokens\":\(135 * buckets)}"
    }

    private static func day(
        _ date: String,
        cost: String,
        incomplete: Bool,
        buckets: Int,
        providers: [String]) -> String
    {
        "{\"cacheCreationTokens\":\(5 * buckets),\"cacheReadTokens\":\(10 * buckets),"
            + "\"costIncomplete\":\(incomplete),\"date\":\"\(date)\",\"inputTokens\":\(100 * buckets),"
            + "\"outputTokens\":\(20 * buckets),\"providers\":[\(providers.joined(separator: ","))],"
            + "\"requests\":\(3 * buckets),\"totalCost\":\(cost),\"totalTokens\":\(135 * buckets)}"
    }

    @Test
    func `daily splits each Reporting Day by provider and model with the token split`() throws {
        let status = Self.status(Self.cache())
        let laptop = try #require(status.machines.first { $0.machineId == Self.laptopID })
        let desk = try #require(status.machines.first { $0.machineId == Self.deskID })

        let sonnet = "claude-sonnet-4-5"
        let expectedLaptop = "[" + [
            Self.day("2026-06-27", cost: "1", incomplete: false, buckets: 1, providers: [
                Self.provider("claude", cost: "1", incomplete: false, buckets: 1, models: [
                    Self.model(sonnet, cost: "1", buckets: 1),
                ]),
            ]),
            Self.day("2026-08-24", cost: "0.5", incomplete: false, buckets: 1, providers: [
                Self.provider("codex", cost: "0.5", incomplete: false, buckets: 1, models: [
                    Self.model("gpt-5", cost: "0.5", buckets: 1),
                ]),
            ]),
            Self.day("2026-08-25", cost: "0.75", incomplete: false, buckets: 1, providers: [
                Self.provider("codex", cost: "0.75", incomplete: false, buckets: 1, models: [
                    Self.model("gpt-5", cost: "0.75", buckets: 1),
                ]),
            ]),
            Self.day("2026-09-20", cost: "null", incomplete: true, buckets: 1, providers: [
                Self.provider("codex", cost: "null", incomplete: true, buckets: 1, models: [
                    Self.model("gpt-5", cost: "null", buckets: 1),
                ]),
            ]),
            Self.day("2026-09-23", cost: "1", incomplete: true, buckets: 2, providers: [
                Self.provider("codex", cost: "1", incomplete: true, buckets: 2, models: [
                    Self.model("gpt-5", cost: "1", buckets: 2),
                ]),
            ]),
            Self.day("2026-09-24", cost: "7.25", incomplete: false, buckets: 3, providers: [
                Self.provider("claude", cost: "7", incomplete: false, buckets: 2, models: [
                    Self.model("claude-opus-4-1", cost: "5", buckets: 1),
                    Self.model(sonnet, cost: "2", buckets: 1),
                ]),
                Self.provider("codex", cost: "0.25", incomplete: false, buckets: 1, models: [
                    Self.model("gpt-5", cost: "0.25", buckets: 1),
                ]),
            ]),
        ].joined(separator: ",") + "]"
        #expect(try Self.json(laptop.daily) == expectedLaptop)

        let expectedDesk = "[" + Self.day("2026-09-24", cost: "0.5", incomplete: true, buckets: 2, providers: [
            Self.provider("claude", cost: "0.5", incomplete: false, buckets: 1, models: [
                Self.model(sonnet, cost: "0.5", buckets: 1),
            ]),
            Self.provider("gemini", cost: "null", incomplete: true, buckets: 1, models: [
                Self.model("gemini-2.5-pro", cost: "null", buckets: 1),
            ]),
        ]) + "]"
        #expect(try Self.json(desk.daily) == expectedDesk)

        // The 30-day `days` field keeps its window; `daily` reaches further back.
        #expect(laptop.days.map(\.date) == ["2026-09-20", "2026-09-23", "2026-09-24"])
    }

    @Test
    func `daily leaves out days outside retention`() throws {
        // 30 days of retention: the oldest kept UTC date is 2026-08-25.
        let status = Self.status(Self.cache(retentionDays: 30))
        let laptop = try #require(status.machines.first { $0.machineId == Self.laptopID })
        #expect(laptop.daily.map(\.date) == ["2026-08-25", "2026-09-20", "2026-09-23", "2026-09-24"])
    }

    @Test
    func `daily follows the Reporting Day timezone`() throws {
        let status = MachineSyncStatus(
            cache: Self.cache(),
            thisMachineID: Self.laptopID,
            reportingDay: MachineSyncReportingDay(timeZone: "Asia/Tokyo"),
            now: Self.now)
        let desk = try #require(status.machines.first { $0.machineId == Self.deskID })
        // UTC+9: 12:00 and 13:00 UTC on the 24th are 21:00 and 22:00 on the 24th in Tokyo.
        #expect(desk.daily.map(\.date) == ["2026-09-24"])
        let laptop = try #require(status.machines.first { $0.machineId == Self.laptopID })
        // 10:00 UTC on the 23rd is 19:00 on the 23rd; 03:00 UTC on the 24th is 12:00 on the 24th.
        #expect(laptop.daily.first { $0.date == "2026-09-23" }?.spend.totalCost == nil)
        #expect(laptop.daily.first { $0.date == "2026-09-24" }?.spend.totalCost == 8.25)
    }

    /// The `--json` payload of every field but `daily`, captured before `daily` was added.
    private static let existingFields = """
    {"errors":[],"generatedAt":"2026-09-24T12:30:00Z","machines":[{"active":true,"clientVersion":"0.24.0",\
    "coverage":{"from":"2026-06-01","to":"2026-09-24"},"days":[{"date":"2026-09-20","spend":{"costIncomplete":true,\
    "costUSD":0,"requests":3,"totalTokens":135}},{"date":"2026-09-23","spend":{"costIncomplete":true,"costUSD":1,\
    "requests":6,"totalTokens":270}},{"date":"2026-09-24","spend":{"costIncomplete":false,"costUSD":7.25,\
    "requests":9,"totalTokens":405}}],"displayName":"laptop","isThisMachine":true,"lastSeen":\
    "2026-09-24T12:29:00Z","last30Days":{"costIncomplete":true,"costUSD":8.25,"requests":18,"totalTokens":810},\
    "machineId":"oKGio6SlpqeoqaqrrK2urw","models":[{"model":"claude-opus-4-1","provider":"claude","spend":\
    {"costIncomplete":false,"costUSD":5,"requests":3,"totalTokens":135}},{"model":"claude-sonnet-4-5","provider":\
    "claude","spend":{"costIncomplete":false,"costUSD":2,"requests":3,"totalTokens":135}},{"model":"gpt-5",\
    "provider":"codex","spend":{"costIncomplete":true,"costUSD":1.25,"requests":12,"totalTokens":540}}],\
    "platform":"linux","retired":false,"today":{"costIncomplete":false,"costUSD":7.25,"requests":9,\
    "totalTokens":405}},{"active":false,"clientVersion":"0.24.0","coverage":{"from":"2026-09-24","to":\
    "2026-09-24"},"days":[{"date":"2026-09-24","spend":{"costIncomplete":true,"costUSD":0.5,"requests":6,\
    "totalTokens":270}}],"displayName":"desk","isThisMachine":false,"lastSeen":"2026-09-24T10:30:00Z",\
    "last30Days":{"costIncomplete":true,"costUSD":0.5,"requests":6,"totalTokens":270},"machineId":\
    "AAAAAAAAAAAAAAAAAAAAAA","models":[{"model":"claude-sonnet-4-5","provider":"claude","spend":\
    {"costIncomplete":false,"costUSD":0.5,"requests":3,"totalTokens":135}},{"model":"gemini-2.5-pro",\
    "provider":"gemini","spend":{"costIncomplete":true,"costUSD":0,"requests":3,"totalTokens":135}}],\
    "platform":"macos","retired":false,"today":{"costIncomplete":true,"costUSD":0.5,"requests":6,\
    "totalTokens":270}}],"reportingDay":{"startHour":4,"timeZone":"UTC"},"today":"2026-09-24","total":\
    {"last30Days":{"costIncomplete":true,"costUSD":8.75,"requests":24,"totalTokens":1080},"today":\
    {"costIncomplete":true,"costUSD":7.75,"requests":15,"totalTokens":675}}}
    """

    @Test
    func `existing status fields are unchanged`() throws {
        let encoded = try #require(CodexBarCLI.encodeJSON(Self.status(Self.cache()), pretty: false))
        var object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let machines = try #require(object["machines"] as? [[String: Any]])
        #expect(machines.allSatisfy { $0["daily"] is [Any] })
        object["machines"] = machines.map { $0.filter { $0.key != "daily" } }
        let stripped = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let expected = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(Self.existingFields.utf8)),
            options: [.sortedKeys])
        #expect(String(bytes: stripped, encoding: .utf8) == String(bytes: expected, encoding: .utf8))
    }
}
