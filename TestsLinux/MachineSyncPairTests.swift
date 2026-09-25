import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct MachineSyncPairTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    @Test
    func `a second Machine pairs with the link and backfills oldest first`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        var desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        desk.hostName = "desk"
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let created = try await laptop.create()
        desk.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 7, 2, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 1, 9)),
        ]

        let paired = try await desk.pair(created.link.link)
        let putsBefore = desk.server.putNames.count
        let outcome = try await desk.push()

        #expect(paired.link == created.link)
        #expect(paired.retentionDays == 400)
        #expect(paired.settings.displayName == "desk")
        #expect(paired.settings.machineID != created.settings.machineID)
        #expect(try desk.store.loadSettings()?.pairingLink == created.link.link)
        #expect(outcome == .pushed(
            uploaded: ["day-2026-07-02", "day-2026-09-01", "day-2026-09-24", "profile"],
            unchanged: 0))
        #expect(Array(desk.server.putNames.dropFirst(putsBefore))
            == ["day-2026-07-02", "day-2026-09-01", "day-2026-09-24", "profile"])
        #expect(try desk.store.loadState()?.coverageStart == "2026-07-02")
        #expect(try desk.store.loadState()?.backfilledAt == Self.now)
    }

    @Test
    func `pairing checks the key before saving anything`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        let desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        try await laptop.create()
        let wrongKey = try MachineSyncPairingLink(serverURL: "https://sync.example.com/base", rootKey: .generate())

        await #expect(throws: MachineSyncError.server(
            status: 404,
            code: "group_not_found",
            message: "server says no",
            retryAfter: nil))
        {
            try await desk.pair(wrongKey.link)
        }
        #expect(try desk.store.loadSettings() == nil)
        #expect(try desk.store.loadState() == nil)
    }

    @Test
    func `plain http to a host that isn't loopback needs confirmation`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        let desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let created = try await MachineSyncGroupCreator.create(
            serverURL: "http://10.0.0.5:8787",
            enrollmentToken: nil,
            displayName: nil,
            environment: laptop.environment)
        let requests = laptop.server.requests.count

        await #expect(throws: MachineSyncError.cleartextNotConfirmed(host: "10.0.0.5")) {
            try await desk.pair(created.link.link)
        }
        #expect(laptop.server.requests.count == requests)
        #expect(try desk.store.loadSettings() == nil)

        let paired = try await desk.pair(created.link.link, allowCleartext: true)
        #expect(paired.link.cleartextWarning)
    }

    @Test
    func `plain http to loopback pairs without confirmation`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        let desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let created = try await MachineSyncGroupCreator.create(
            serverURL: "http://127.0.0.1:8787",
            enrollmentToken: nil,
            displayName: nil,
            environment: laptop.environment)

        try await desk.pair(created.link.link)

        #expect(try desk.store.loadSettings()?.pairingLink == created.link.link)
    }

    @Test
    func `a paired Machine can't pair again`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        let created = try await context.create()
        let requests = context.server.requests.count

        await #expect(throws: MachineSyncError.alreadyPaired) { try await context.pair(created.link.link) }
        #expect(context.server.requests.count == requests)
    }

    @Test
    func `a malformed link fails without network calls`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        await #expect(throws: MachineSyncPairingLinkError.missingRootKey) {
            try await context.pair("codexbar-sync://sync.example.com")
        }
        #expect(context.server.requests.isEmpty)
    }

    @Test
    func `a Machine that left keeps its ID when it pairs again`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        let desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let created = try await laptop.create()
        try desk.store.saveSettings(MachineSyncSettings(
            machineID: "oKGio6SlpqeoqaqrrK2urw",
            displayName: "old desk",
            reportingDay: MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4)))

        let paired = try await desk.pair(created.link.link)

        #expect(paired.settings.machineID == "oKGio6SlpqeoqaqrrK2urw")
        #expect(paired.settings.displayName == "old desk")
        #expect(paired.settings.reportingDay == MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4))
    }

    @Test
    func `a backfill interrupted by an error finishes on the next push`() async throws {
        let laptop = MachineSyncTestContext(now: Self.now)
        let desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let created = try await laptop.create()
        desk.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 8, 1, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 8, 2, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
        ]
        try await desk.pair(created.link.link)
        desk.server.failPut(named: "day-2026-08-02", with: .init(status: 503, code: "internal_error"))

        await #expect(throws: MachineSyncError.self) { try await desk.push() }
        #expect(try desk.store.loadState()?.backfilledAt == nil)

        var later = desk
        later.now = Self.now.addingTimeInterval(120)
        let outcome = try await later.push()
        #expect(outcome == .pushed(uploaded: ["day-2026-08-02", "day-2026-09-24", "profile"], unchanged: 1))
        #expect(try desk.store.loadState()?.backfilledAt == later.now)
    }
}
