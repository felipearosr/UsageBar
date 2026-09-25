import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct MachineSyncPushTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    private func openBlob(
        _ context: MachineSyncTestContext,
        name: String) throws -> [String: Any]
    {
        let settings = try #require(try context.store.loadSettings())
        let link = try MachineSyncPairingLink(parsing: #require(settings.pairingLink))
        let envelope = try #require(context.server.blob(machineID: settings.machineID, name: name))
        let plaintext = try MachineSyncEnvelope.open(
            envelope,
            encKey: link.keys.encKey,
            address: MachineSyncBlobAddress(
                groupID: link.keys.groupIDBase64URL,
                machineID: settings.machineID,
                name: name))
        return try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    }

    @Test
    func `push without a Sync Group makes no network calls`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]

        await #expect(throws: MachineSyncError.notPaired) {
            try await MachineSyncPusher.push(environment: context.environment)
        }
        #expect(context.server.requests.isEmpty)
        #expect(try context.store.loadSettings() == nil)
    }

    @Test
    func `first push after create backfills every day, then profile`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 22, 23)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 23, 14)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), provider: .codex, model: "gpt-5"),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: nil),
        ]
        try await context.create()

        let outcome = try await MachineSyncPusher.push(environment: context.environment)

        #expect(outcome == .pushed(
            uploaded: ["day-2026-09-22", "day-2026-09-23", "day-2026-09-24", "profile"],
            unchanged: 0))
        let today = try self.openBlob(context, name: "day-2026-09-24")
        let buckets = try #require(today["buckets"] as? [[String: Any]])
        #expect(buckets.count == 2)
        #expect(buckets.map { $0["provider"] as? String } == ["claude", "codex"])
        #expect(buckets[0]["hour"] as? Int == 9)
        #expect(buckets[0]["costUSD"] == nil)
        #expect(buckets[0]["cacheReadTokens"] == nil)
        #expect(buckets[1]["costUSD"] as? Double == 1.5)

        let profile = try self.openBlob(context, name: "profile")
        #expect(profile["displayName"] as? String == "test-host")
        #expect(profile["clientVersion"] as? String == "0.24.0")
        #expect(profile["coverageStart"] as? String == "2026-09-22")
        #expect(profile["pushedAt"] as? String == "2026-09-24T12:30:00Z")
    }

    @Test
    func `an immediate second push with no new Spend makes no PUTs`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        _ = try await MachineSyncPusher.push(environment: context.environment)
        let putsAfterFirst = context.server.putNames.count

        context.now = Self.now.addingTimeInterval(60)
        let outcome = try await MachineSyncPusher.push(environment: context.environment)

        #expect(outcome == .pushed(uploaded: [], unchanged: 2))
        #expect(context.server.putNames.count == putsAfterFirst)
    }

    @Test
    func `an idle Machine re-uploads profile every two minutes so Last Seen stays fresh`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        _ = try await context.push()

        context.now = Self.now.addingTimeInterval(150)
        context.server.now = context.now
        let outcome = try await context.push()

        #expect(outcome == .pushed(uploaded: ["profile"], unchanged: 1))
        #expect(try self.openBlob(context, name: "profile")["pushedAt"] as? String == "2026-09-24T12:32:30Z")
        let machineID = try #require(try context.store.loadSettings()?.machineID)
        #expect(context.server.lastSeen(machineID: machineID) == context.now)
    }

    @Test
    func `after the backfill, pushes only look at today and yesterday`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        _ = try await context.push()

        context.spend.buckets.append(MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 20, 9)))
        let outcome = try await context.push()

        #expect(outcome == .pushed(uploaded: [], unchanged: 2))
        #expect(try context.server.blob(
            machineID: #require(try context.store.loadSettings()?.machineID),
            name: "day-2026-09-20") == nil)
    }

    @Test
    func `backfill stops at the server's retention window`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.retentionDays = 5
        context.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 10, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 18, 23)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 19, 0)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
        ]
        try await context.create()

        let outcome = try await context.push()

        #expect(outcome == .pushed(uploaded: ["day-2026-09-19", "day-2026-09-24", "profile"], unchanged: 0))
        #expect(try self.openBlob(context, name: "profile")["coverageStart"] as? String == "2026-09-19")
    }

    @Test
    func `coverageStart is clamped to the oldest day still inside retention`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.retentionDays = 10
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        _ = try await context.push()
        var state = try #require(try context.store.loadState())
        state.coverageStart = "2026-01-01"
        try context.store.saveState(state)

        context.now = Self.now.addingTimeInterval(150)
        _ = try await context.push()

        #expect(try self.openBlob(context, name: "profile")["coverageStart"] as? String == "2026-09-14")
        #expect(try context.store.loadState()?.coverageStart == "2026-09-14")
    }

    @Test
    func `a Machine paired before backfill existed backfills on its next push`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 8, 1, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 1, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
        ]
        try await context.create()
        context.server.retentionDays = 30
        // A #7-era state file: no retention, no backfill marker, no heartbeat time.
        let groupID = try #require(try context.store.loadState()?.groupID)
        try Data(#"{"groupID":"\#(groupID)","uploadedHashes":{},"consecutiveFailures":0}"#.utf8)
            .write(to: context.store.stateURL)

        let outcome = try await context.push()

        // Retention is learned from `GET /info` first, so August (past 30 days) stays local.
        #expect(outcome == .pushed(uploaded: ["day-2026-09-01", "day-2026-09-24", "profile"], unchanged: 0))
        #expect(try context.store.loadState()?.backfilledAt == Self.now)
        #expect(try context.store.loadState()?.retentionDays == 30)
        #expect(try self.openBlob(context, name: "profile")["coverageStart"] as? String == "2026-09-01")
    }

    @Test
    func `new Spend uploads only the changed day`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 23, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
        ]
        try await context.create()
        _ = try await MachineSyncPusher.push(environment: context.environment)

        context.spend.buckets.append(MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 11)))
        let outcome = try await MachineSyncPusher.push(environment: context.environment)

        #expect(outcome == .pushed(uploaded: ["day-2026-09-24"], unchanged: 2))
    }

    @Test
    func `two concurrent pushes on one Machine: exactly one uploads`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        context.spend.holdNextScan()

        let environment = context.environment
        let first = Task { try await MachineSyncPusher.push(environment: environment) }
        await context.spend.waitUntilScanning()
        let second = try await MachineSyncPusher.push(environment: environment)
        context.spend.release()
        let firstOutcome = try await first.value

        #expect(second == .skippedLocked)
        #expect(firstOutcome == .pushed(uploaded: ["day-2026-09-24", "profile"], unchanged: 0))
        #expect(context.server.putNames == ["day-2026-09-24", "profile"])
    }

    @Test
    func `rate limits and network errors back off exponentially up to 15 minutes`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()

        context.server.failNext(.init(status: 429, code: "rate_limited"))
        await #expect(throws: MachineSyncError.self) {
            try await MachineSyncPusher.push(environment: context.environment)
        }
        #expect(try context.store.loadState()?.nextAttemptAt == Self.now.addingTimeInterval(60))

        let requestsBefore = context.server.requests.count
        context.now = Self.now.addingTimeInterval(30)
        let waiting = try await MachineSyncPusher.push(environment: context.environment)
        #expect(waiting == .backingOff(until: Self.now.addingTimeInterval(60)))
        #expect(context.server.requests.count == requestsBefore)

        context.now = Self.now.addingTimeInterval(61)
        context.server.failNextWithNetworkError()
        await #expect(throws: MachineSyncError.self) {
            try await MachineSyncPusher.push(environment: context.environment)
        }
        #expect(try context.store.loadState()?.nextAttemptAt == context.now.addingTimeInterval(120))

        context.now = context.now.addingTimeInterval(121)
        let outcome = try await MachineSyncPusher.push(environment: context.environment)
        #expect(outcome == .pushed(uploaded: ["day-2026-09-24", "profile"], unchanged: 0))
        #expect(try context.store.loadState()?.consecutiveFailures == 0)
        #expect(try context.store.loadState()?.nextAttemptAt == nil)

        #expect(MachineSyncPusher.backoffDelay(failures: 4, retryAfter: nil) == 480)
        #expect(MachineSyncPusher.backoffDelay(failures: 5, retryAfter: nil) == 900)
        #expect(MachineSyncPusher.backoffDelay(failures: 40, retryAfter: nil) == 900)
        #expect(MachineSyncPusher.backoffDelay(failures: 1, retryAfter: 300) == 300)
    }

    @Test
    func `a failed day upload is retried on the next push`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 23, 9)),
            MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9)),
        ]
        try await context.create()
        context.server.failPut(named: "day-2026-09-24", with: .init(status: 403, code: "machine_limit"))

        await #expect(throws: MachineSyncError.server(
            status: 403,
            code: "machine_limit",
            message: "server says no",
            retryAfter: nil))
        {
            try await MachineSyncPusher.push(environment: context.environment)
        }
        #expect(try context.store.loadState()?.nextAttemptAt == nil)

        let outcome = try await MachineSyncPusher.push(environment: context.environment)
        #expect(outcome == .pushed(uploaded: ["day-2026-09-24", "profile"], unchanged: 1))
    }
}
