import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

/// In-memory Sync Server speaking just enough of §6 for create and push.
final class FakeSyncServer: ProviderHTTPTransport, @unchecked Sendable {
    struct Failure {
        var status: Int
        var code: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _blobs: [String: Data] = [:]
    private var _failures: [Failure] = []
    private var _networkFailures = 0
    private var _putFailures: [String: Failure] = [:]
    private var _postFailure: Failure?
    var enrollment = "none"
    var protocols = [1]

    var requests: [URLRequest] {
        self.lock.withLock { self._requests }
    }

    var putNames: [String] {
        self.requests.filter { $0.httpMethod == "PUT" }.compactMap { $0.url?.lastPathComponent }
    }

    func blob(machineID: String, name: String) -> Data? {
        self.lock.withLock { self._blobs.first { $0.key.hasSuffix("/machines/\(machineID)/blobs/\(name)") }?.value }
    }

    /// The next requests fail with these errors, in order.
    func failNext(_ failures: Failure...) {
        self.lock.withLock { self._failures.append(contentsOf: failures) }
    }

    /// The next PUT of blob `name` fails once.
    func failPut(named name: String, with failure: Failure) {
        self.lock.withLock { self._putFailures[name] = failure }
    }

    /// The next `POST /v1/groups` fails once.
    func failPost(with failure: Failure) {
        self.lock.withLock { self._postFailure = failure }
    }

    func failNextWithNetworkError() {
        self.lock.withLock { self._networkFailures += 1 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (failure, networkFailure) = self.lock.withLock { () -> (Failure?, Bool) in
            self._requests.append(request)
            if self._networkFailures > 0 {
                self._networkFailures -= 1
                return (nil, true)
            }
            if request.httpMethod == "POST", let failure = self._postFailure {
                self._postFailure = nil
                return (failure, false)
            }
            if request.httpMethod == "PUT", let name = request.url?.lastPathComponent,
               let failure = self._putFailures.removeValue(forKey: name)
            {
                return (failure, false)
            }
            return (self._failures.isEmpty ? nil : self._failures.removeFirst(), false)
        }
        if networkFailure { throw URLError(.notConnectedToInternet) }
        if let failure {
            let body = #"{"error":{"code":"\#(failure.code)","message":"server says no"}}"#
            return Self.response(request, status: failure.status, body: Data(body.utf8), headers: failure.headers)
        }

        let fullPath = request.url?.path ?? ""
        let path = fullPath.range(of: "/v1/").map { String(fullPath[$0.lowerBound...]) } ?? fullPath
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/info"):
            let body = try JSONSerialization.data(withJSONObject: [
                "protocols": self.protocols,
                "enrollment": self.enrollment,
                "maxBlobBytes": 65536,
                "retentionDays": 400,
            ])
            return Self.response(request, status: 200, body: body)
        case ("POST", "/v1/groups"):
            let body = #"{"limits":{"maxMachines":10,"retentionDays":400,"expiresAt":null}}"#
            return Self.response(request, status: 201, body: Data(body.utf8))
        case let ("PUT", putPath) where putPath.contains("/blobs/"):
            self.lock.withLock { self._blobs[putPath] = request.httpBody ?? Data() }
            let body = #"{"etag":"\"e1\"","updatedAt":"2026-09-24T12:00:00Z"}"#
            return Self.response(request, status: 200, body: Data(body.utf8))
        default:
            return Self.response(request, status: 404, body: Data(#"{"error":{"code":"not_found"}}"#.utf8))
        }
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: Data,
        headers: [String: String] = [:]) -> (Data, URLResponse)
    {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// Spend a test can change between pushes, plus an optional gate that holds the scan open.
final class TestSpend: @unchecked Sendable {
    private let lock = NSLock()
    private var _buckets: [CostUsageSpendBucket] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gateArmed = false
    private var entered: CheckedContinuation<Void, Never>?

    var buckets: [CostUsageSpendBucket] {
        get { self.lock.withLock { self._buckets } }
        set { self.lock.withLock { self._buckets = newValue } }
    }

    /// The next scan blocks until `release()`.
    func holdNextScan() {
        self.lock.withLock { self.gateArmed = true }
    }

    func waitUntilScanning() async {
        await withCheckedContinuation { continuation in
            let resumeNow = self.lock.withLock { () -> Bool in
                if self.gate != nil { return true }
                self.entered = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let gate = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    var source: MachineSyncSpendSource {
        { [self] since, until in
            let armed = self.lock.withLock { () -> Bool in
                defer { self.gateArmed = false }
                return self.gateArmed
            }
            if armed {
                await withCheckedContinuation { continuation in
                    let entered = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        self.gate = continuation
                        defer { self.entered = nil }
                        return self.entered
                    }
                    entered?.resume()
                }
            }
            return self.buckets.filter { $0.hourStart >= since && $0.hourStart < until }
        }
    }
}

struct MachineSyncTestContext {
    let directory: URL
    let server = FakeSyncServer()
    let spend = TestSpend()
    var now: Date

    init(now: Date) {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-sync-\(UUID().uuidString)", isDirectory: true)
        self.now = now
    }

    var store: MachineSyncStore {
        MachineSyncStore(directory: self.directory)
    }

    var environment: MachineSyncEnvironment {
        let now = self.now
        return MachineSyncEnvironment(
            store: self.store,
            transport: self.server,
            spendSource: self.spend.source,
            clientVersion: "0.24.0",
            hostName: "test-host",
            now: { now })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.directory)
    }

    @discardableResult
    func create(token: String? = nil) async throws -> MachineSyncCreateResult {
        try await MachineSyncGroupCreator.create(
            serverURL: "https://sync.example.com/base",
            enrollmentToken: token,
            displayName: nil,
            environment: self.environment)
    }

    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        MachineSyncDay.utcCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func bucket(
        _ hourStart: Date,
        provider: UsageProvider = .claude,
        model: String = "claude-sonnet-4-5",
        cost: Double? = 1.5) -> CostUsageSpendBucket
    {
        CostUsageSpendBucket(
            hourStart: hourStart,
            provider: provider,
            model: model,
            costUSD: cost,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: nil,
            cacheCreationTokens: nil,
            totalTokens: 120,
            requests: 3)
    }
}

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
    func `first push uploads today, yesterday, and profile`() async throws {
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

        #expect(outcome == .pushed(uploaded: ["day-2026-09-23", "day-2026-09-24", "profile"], unchanged: 0))
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
        #expect(profile["coverageStart"] as? String == "2026-09-23")
        #expect(profile["pushedAt"] as? String == "2026-09-24T12:30:00Z")
    }

    @Test
    func `second push with no new Spend makes no PUTs`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9))]
        try await context.create()
        _ = try await MachineSyncPusher.push(environment: context.environment)
        let putsAfterFirst = context.server.putNames.count

        context.now = Self.now.addingTimeInterval(150)
        let outcome = try await MachineSyncPusher.push(environment: context.environment)

        #expect(outcome == .pushed(uploaded: [], unchanged: 2))
        #expect(context.server.putNames.count == putsAfterFirst)
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
