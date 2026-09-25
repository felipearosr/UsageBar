import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLISyncStatusTextTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    private static func status() -> MachineSyncStatus {
        var cache = MachineSyncCache(groupID: "g")
        cache.retentionDays = 400
        var laptop = MachineSyncCache.Machine(lastSeen: Self.now.addingTimeInterval(-60))
        laptop.profile = MachineSyncProfile(
            displayName: "laptop",
            platform: "linux",
            clientVersion: "0.24.0",
            coverageStart: "2026-06-25",
            pushedAt: nil)
        laptop.days["2026-09-24"] = MachineSyncDayBlob(buckets: [
            .init(
                hour: 9,
                provider: "claude",
                model: "claude-sonnet-4-5",
                costUSD: 1.84,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 435_683,
                requests: 41),
            .init(
                hour: 10,
                provider: "codex",
                model: "gpt-5",
                costUSD: nil,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: 1000,
                requests: 1),
        ])
        cache.machines["oKGio6SlpqeoqaqrrK2urw"] = laptop
        cache.machines["AAAAAAAAAAAAAAAAAAAAAA"] = MachineSyncCache
            .Machine(lastSeen: Self.now.addingTimeInterval(-7200))
        cache.errors["AAAAAAAAAAAAAAAAAAAAAA/day-2026-09-24"] = MachineSyncCache.BlobError(
            machineID: "AAAAAAAAAAAAAAAAAAAAAA",
            name: "day-2026-09-24",
            reason: "couldn't decrypt")
        return MachineSyncStatus(
            cache: cache,
            thisMachineID: "oKGio6SlpqeoqaqrrK2urw",
            reportingDay: MachineSyncReportingDay(timeZone: "UTC", startHour: 4),
            now: Self.now)
    }

    @Test
    func `status text shows Coverage as a date range and every Machine`() {
        let text = CodexBarCLI.syncStatusText(Self.status())

        #expect(text.contains("Today is 2026-09-24 (Reporting Day: UTC, days start at 04:00)."))
        #expect(text.contains("laptop (this Machine) · active · last seen 1 min ago"))
        #expect(text.contains("  Today    $1.84 + unpriced · 437K tokens · 42 requests"))
        #expect(text.contains("  Coverage 2026-06-25 to 2026-09-24"))
        #expect(text.contains("    claude claude-sonnet-4-5  $1.84"))
        #expect(text.contains("    codex gpt-5               $0.00 + unpriced"))
        #expect(text.contains("AAAAAAAAAAAAAAAAAAAAAA · inactive · last seen 2 h ago"))
        #expect(text.contains("  Coverage none yet"))
        #expect(text.contains("All Machines: today $1.84 + unpriced · 30 days $1.84 + unpriced"))
        #expect(text.contains("Skipped 1 unreadable blob:\n  AAAAAAAAAAAAAAAAAAAAAA day-2026-09-24: couldn't decrypt"))
    }

    @Test
    func `neither the text nor the JSON ever says lifetime`() throws {
        let status = Self.status()
        let json = try #require(CodexBarCLI.encodeJSON(status, pretty: true))

        #expect(!CodexBarCLI.syncStatusText(status).lowercased().contains("lifetime"))
        #expect(!json.lowercased().contains("lifetime"))
        #expect(json.contains(#""coverage" : {"#))
        #expect(json.contains(#""from" : "2026-06-25""#))
        #expect(json.contains(#""machineId" : "AAAAAAAAAAAAAAAAAAAAAA""#))
        #expect(!json.contains("machineID"))
    }

    @Test
    func `last seen reads as a relative time`() {
        #expect(CodexBarCLI.syncLastSeenText(nil, now: Self.now) == "never")
        #expect(CodexBarCLI.syncLastSeenText(Self.now.addingTimeInterval(-30), now: Self.now) == "just now")
        #expect(CodexBarCLI.syncLastSeenText(Self.now.addingTimeInterval(-90000), now: Self.now) == "1 d ago")
    }
}
