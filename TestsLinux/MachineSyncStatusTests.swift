import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct MachineSyncStatusTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    /// A laptop that created the group and a desk that paired, both pushed once.
    private func twoMachines() async throws -> (laptop: MachineSyncTestContext, desk: MachineSyncTestContext) {
        let laptop = MachineSyncTestContext(now: Self.now)
        var desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        desk.hostName = "desk"
        laptop.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: 2),
            MachineSyncTestContext.bucket(
                MachineSyncTestContext.utc(2026, 9, 10, 9),
                provider: .codex,
                model: "gpt-5",
                cost: 1),
        ]
        desk.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 10), cost: 0.5),
            MachineSyncTestContext.bucket(
                MachineSyncTestContext.utc(2026, 9, 24, 11),
                provider: .codex,
                model: "gpt-5",
                cost: nil),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 7, 1, 9), cost: 9),
        ]
        let created = try await laptop.create()
        _ = try await laptop.push()
        try await desk.pair(created.link.link)
        _ = try await desk.push()
        return (laptop, desk)
    }

    @Test
    func `either Machine sees every Machine's Spend`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }

        for context in [laptop, desk] {
            let status = try await context.status()
            #expect(status.machines.map(\.displayName).sorted() == ["desk", "test-host"])
            #expect(status.machines.first?.isThisMachine == true)
            #expect(status.today == "2026-09-24")
            #expect(status.total.today.costUSD == 2.5)
            #expect(status.total.today.costIncomplete)
            #expect(status.total.last30Days.costUSD == 3.5)
            #expect(status.errors.isEmpty)
        }

        let status = try await laptop.status()
        let laptopRow = try #require(status.machines.first { $0.displayName == "test-host" })
        #expect(laptopRow.active)
        #expect(laptopRow.lastSeen == Self.now)
        #expect(laptopRow.platform == MachineSyncProfile.currentPlatform)
        #expect(laptopRow.today == MachineSyncStatus.Spend(costUSD: 2, totalTokens: 120, requests: 3))
        #expect(laptopRow.last30Days.costUSD == 3)
        #expect(laptopRow.models.map(\.model) == ["claude-sonnet-4-5", "gpt-5"])
        #expect(laptopRow.days.map(\.date) == ["2026-09-10", "2026-09-24"])
        #expect(laptopRow.coverage == MachineSyncStatus.Coverage(from: "2026-09-10", to: "2026-09-24"))

        let deskRow = try #require(status.machines.first { $0.displayName == "desk" })
        #expect(!deskRow.isThisMachine)
        #expect(deskRow.today.costUSD == 0.5)
        #expect(deskRow.today.costIncomplete)
        #expect(deskRow.last30Days.costUSD == 0.5)
        #expect(deskRow.models.map(\.provider) == ["claude", "codex"])
        // July is outside the 30-day window but still inside Coverage.
        #expect(deskRow.coverage == MachineSyncStatus.Coverage(from: "2026-07-01", to: "2026-09-24"))
    }

    @Test
    func `later reads fetch only new blobs from the cursor`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }

        let first = try await laptop.refresh()
        #expect(first.fetchedBlobs == 6)
        let cursor = try #require(first.cache.cursor)

        let second = try await laptop.refresh()
        #expect(second.fetchedBlobs == 0)
        #expect(laptop.server.changesCursors.suffix(1) == [cursor])

        desk.spend.buckets.append(MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 12), cost: 4))
        _ = try await desk.push()
        let third = try await laptop.refresh()
        #expect(third.fetchedBlobs == 1)

        let status = try await laptop.status()
        #expect(status.machines.first { $0.displayName == "desk" }?.today.costUSD == 4.5)
    }

    @Test
    func `a blob that fails to decrypt is skipped and reported, never partly shown`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        _ = try await laptop.status()
        let deskID = try #require(try desk.store.loadSettings()?.machineID)
        let laptopID = try #require(try laptop.store.loadSettings()?.machineID)
        // A valid envelope moved to another Machine's address, and a corrupted copy of today.
        let moved = try #require(laptop.server.blob(machineID: laptopID, name: "day-2026-09-10"))
        laptop.server.store(machineID: deskID, name: "day-2026-09-10", body: moved)
        var corrupted = try #require(laptop.server.blob(machineID: deskID, name: "day-2026-09-24"))
        corrupted[corrupted.count - 1] ^= 0x01
        laptop.server.store(machineID: deskID, name: "day-2026-09-24", body: corrupted)

        let status = try await laptop.status()

        let deskRow = try #require(status.machines.first { $0.machineId == deskID })
        #expect(deskRow.today.isEmpty)
        #expect(deskRow.days.isEmpty)
        #expect(status.errors.map(\.name) == ["day-2026-09-10", "day-2026-09-24"])
        #expect(status.errors.allSatisfy { $0.machineID == deskID && $0.reason == "couldn't decrypt" })
        #expect(status.machines.first { $0.machineId == laptopID }?.today.costUSD == 2)

        // A good copy replaces the bad one and clears the error.
        var repush = desk
        repush.now = Self.now.addingTimeInterval(30)
        desk.spend.buckets.append(MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 12), cost: 1))
        _ = try await repush.push()
        let repaired = try await laptop.status()
        #expect(repaired.errors.map(\.name) == ["day-2026-09-10"])
        #expect(repaired.machines.first { $0.machineId == deskID }?.today.costUSD == 1.5)
    }

    @Test
    func `a Machine is active only while Last Seen is under 5 minutes old`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }

        var later = laptop
        later.now = Self.now.addingTimeInterval(299)
        #expect(try await later.status().machines.allSatisfy(\.active))
        later.now = Self.now.addingTimeInterval(300)
        #expect(try await later.status().machines.allSatisfy { !$0.active })
    }

    @Test
    func `forgotten Machines and days past retention drop out of the cache`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        _ = try await laptop.status()
        let deskID = try #require(try desk.store.loadSettings()?.machineID)
        laptop.server.deleteMachine(deskID)
        laptop.server.retentionDays = 10
        laptop.server.deleteDays(before: "2026-09-14")

        let status = try await laptop.status()

        #expect(status.machines.map(\.displayName) == ["test-host"])
        let row = try #require(status.machines.first)
        #expect(row.days.map(\.date) == ["2026-09-24"])
        #expect(row.coverage == MachineSyncStatus.Coverage(from: "2026-09-14", to: "2026-09-24"))
    }

    @Test
    func `retired Machines count toward totals but are not active until they push again`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let deskID = try #require(try desk.store.loadSettings()?.machineID)
        let link = try MachineSyncPairingLink(parsing: #require(try laptop.store.loadSettings()?.pairingLink))
        let retired = Data(#"{"v":1,"machines":{"\#(deskID)":{"retiredAt":"2026-09-24T12:31:00Z"}}}"#.utf8)
        try laptop.server.store(machineID: "group", name: "retired", body: MachineSyncEnvelope.seal(
            retired,
            encKey: link.keys.encKey,
            address: MachineSyncBlobAddress(groupID: link.keys.groupIDBase64URL, machineID: "group", name: "retired")))

        let status = try await laptop.status()
        let deskRow = try #require(status.machines.first { $0.machineId == deskID })
        #expect(deskRow.retired)
        #expect(!deskRow.active)
        #expect(status.total.today.costUSD == 2.5)

        var back = desk
        back.now = Self.now.addingTimeInterval(180)
        back.server.now = back.now
        _ = try await back.push()
        var later = laptop
        later.now = back.now
        let revived = try #require(try await later.status().machines.first { $0.machineId == deskID })
        #expect(!revived.retired)
        #expect(revived.active)
    }

    @Test
    func `a server that never advances its cursor can't trap the reader`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        _ = try await laptop.refresh()
        laptop.server.stuckCursor = true
        let requests = laptop.server.changesCursors.count

        let result = try await laptop.refresh()

        #expect(laptop.server.changesCursors.count == requests + 1)
        #expect(laptop.server.changesCursors.last == .some(result.cache.cursor))
    }

    @Test
    func `status without a Sync Group makes no network calls`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        await #expect(throws: MachineSyncError.notPaired) { try await context.refresh() }
        #expect(context.server.requests.isEmpty)
    }
}

struct MachineSyncReportingDayTests {
    private static func cache(_ buckets: [(date: String, hour: Int, cost: Double)]) -> MachineSyncCache {
        var cache = MachineSyncCache(groupID: "g")
        var machine = MachineSyncCache.Machine(lastSeen: MachineSyncTestContext.utc(2026, 9, 24, 20))
        for bucket in buckets {
            machine.days[bucket.date, default: MachineSyncDayBlob(buckets: [])].buckets.append(.init(
                hour: bucket.hour,
                provider: "claude",
                model: "claude-sonnet-4-5",
                costUSD: bucket.cost,
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: nil,
                requests: nil))
        }
        cache.machines["oKGio6SlpqeoqaqrrK2urw"] = machine
        return cache
    }

    private static func dayTotals(_ reportingDay: MachineSyncReportingDay) throws -> [String: Double] {
        let cache = self.cache([("2026-09-24", 2, 1), ("2026-09-24", 14, 10), ("2026-09-23", 23, 100)])
        let status = MachineSyncStatus(
            cache: cache,
            thisMachineID: nil,
            reportingDay: reportingDay,
            now: MachineSyncTestContext.utc(2026, 9, 24, 20))
        let machine = try #require(status.machines.first)
        return Dictionary(uniqueKeysWithValues: machine.days.map { ($0.date, $0.spend.costUSD) })
    }

    @Test
    func `same buckets group into different days by timezone and day boundary`() throws {
        #expect(try Self.dayTotals(.init(timeZone: "UTC")) == ["2026-09-23": 100, "2026-09-24": 11])
        // UTC-7 in September: 23:00 and 02:00 UTC land on the 23rd, 14:00 UTC is 07:00 on the 24th.
        #expect(try Self.dayTotals(.init(timeZone: "America/Los_Angeles")) == ["2026-09-23": 101, "2026-09-24": 10])
        // With days starting at 08:00, 07:00 still belongs to the 23rd.
        #expect(try Self.dayTotals(.init(timeZone: "America/Los_Angeles", startHour: 8)) == ["2026-09-23": 111])
        // UTC+9: 23:00 UTC on the 23rd is 08:00 on the 24th; 14:00 UTC on the 24th is 23:00 on the 24th.
        #expect(try Self.dayTotals(.init(timeZone: "Asia/Tokyo")) == ["2026-09-24": 111])
    }

    @Test
    func `today follows the Reporting Day, not UTC`() {
        let now = MachineSyncTestContext.utc(2026, 9, 24, 20)
        let tokyo = MachineSyncStatus(
            cache: Self.cache([]),
            thisMachineID: nil,
            reportingDay: .init(timeZone: "Asia/Tokyo"),
            now: now)
        let late = MachineSyncStatus(
            cache: Self.cache([]),
            thisMachineID: nil,
            reportingDay: .init(timeZone: "UTC", startHour: 21),
            now: now)
        #expect(tokyo.today == "2026-09-25")
        #expect(late.today == "2026-09-23")
        #expect(tokyo.reportingDay == .init(timeZone: "Asia/Tokyo", startHour: 0))
    }

    @Test
    func `the 30-day window spans 30 Reporting Days across a DST change`() {
        let reportingDay = MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4)
        let days = reportingDay.days(endingAt: MachineSyncTestContext.utc(2026, 11, 10, 2), count: 30)
        #expect(days.count == 30)
        #expect(days.first == "2026-10-11")
        #expect(days.last == "2026-11-09")
    }

    @Test
    func `reporting day settings are validated`() throws {
        #expect(MachineSyncReportingDay(timeZone: "Mars/Olympus").isValid == false)
        #expect(MachineSyncReportingDay(startHour: 24).isValid == false)
        #expect(MachineSyncReportingDay(timeZone: "UTC", startHour: 23).isValid)
        let decoded = try JSONDecoder().decode(MachineSyncReportingDay.self, from: Data(#"{"timeZone":"UTC"}"#.utf8))
        #expect(decoded == MachineSyncReportingDay(timeZone: "UTC", startHour: 0))
    }
}
