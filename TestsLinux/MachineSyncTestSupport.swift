import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

/// In-memory Sync Server speaking just enough of §6 for create, pair, push, status, and Machine management.
final class FakeSyncServer: ProviderHTTPTransport, @unchecked Sendable {
    struct Failure {
        var status: Int
        var code: String
        var headers: [String: String] = [:]
    }

    private struct Stored {
        var seq: Int
        var machineID: String
        var name: String
        var body: Data
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _blobs: [String: Stored] = [:]
    private var _lastSeen: [String: Date] = [:]
    private var _groups: Set<String> = []
    private var _seq = 0
    private var _failures: [Failure] = []
    private var _networkFailures = 0
    private var _putFailures: [String: Failure] = [:]
    private var _postFailure: Failure?
    private var _beforePut: [String: () -> Void] = [:]
    private var _afterPut: [String: () -> Void] = [:]
    var enrollment = "none"
    var protocols = [1]
    var retentionDays: Int? = 400
    /// Misbehave: answer every `changes` with `hasMore: true` and the cursor that was sent.
    var stuckCursor = false
    /// Server clock: Last Seen is the receive time of a Machine's latest PUT (§6.4).
    var now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    var requests: [URLRequest] {
        self.lock.withLock { self._requests }
    }

    var putNames: [String] {
        self.requests.filter { $0.httpMethod == "PUT" }.compactMap { $0.url?.lastPathComponent }
    }

    /// `since` of every `changes` request, in order (`nil` when absent).
    var changesCursors: [String?] {
        self.requests.filter { $0.url?.path.hasSuffix("/changes") == true }.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "since" }?.value
        }
    }

    func blob(machineID: String, name: String) -> Data? {
        self.lock.withLock { self._blobs["\(machineID)/\(name)"]?.body }
    }

    func lastSeen(machineID: String) -> Date? {
        self.lock.withLock { self._lastSeen[machineID] }
    }

    /// Stores `body` as if a Machine had PUT it.
    func store(machineID: String, name: String, body: Data) {
        self.lock.withLock { self.write(machineID: machineID, name: name, body: body) }
    }

    /// "Forget this Machine" (§6.7).
    func deleteMachine(_ machineID: String) {
        self.lock.withLock {
            self._lastSeen[machineID] = nil
            self._blobs = self._blobs.filter { $0.value.machineID != machineID }
        }
    }

    /// Retention (§7): drops `day-*` blobs dated before `date`.
    func deleteDays(before date: String) {
        self.lock.withLock {
            self._blobs = self._blobs.filter {
                !$0.value.name.hasPrefix("day-") || String($0.value.name.dropFirst(4)) >= date
            }
        }
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

    /// Runs `action` just before the next PUT of blob `name` is applied, as if another Machine wrote first.
    func beforeNextPut(named name: String, _ action: @escaping () -> Void) {
        self.lock.withLock { self._beforePut[name] = action }
    }

    /// Runs `action` just after the next PUT of blob `name` succeeds, as if another Machine wrote right after.
    func afterNextPut(named name: String, _ action: @escaping () -> Void) {
        self.lock.withLock { self._afterPut[name] = action }
    }

    /// ETag of the stored blob, as the server would send it.
    func etag(machineID: String, name: String) -> String? {
        self.lock.withLock { self._blobs["\(machineID)/\(name)"].map { Self.etag($0.seq) } }
    }

    private static func etag(_ seq: Int) -> String {
        "\"e\(seq)\""
    }

    func failNextWithNetworkError() {
        self.lock.withLock { self._networkFailures += 1 }
    }

    private func write(machineID: String, name: String, body: Data) {
        self._seq += 1
        self._blobs["\(machineID)/\(name)"] = Stored(seq: self._seq, machineID: machineID, name: name, body: body)
        if machineID != MachineSyncMachineID.group {
            self._lastSeen[machineID] = self.now
        }
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
            return Self.error(request, status: failure.status, code: failure.code, headers: failure.headers)
        }

        let fullPath = request.url?.path ?? ""
        let path = fullPath.range(of: "/v1/").map { String(fullPath[$0.lowerBound...]) } ?? fullPath
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[1] == "groups", !self.lock.withLock({ self._groups.contains(parts[2]) }) {
            return Self.error(request, status: 404, code: "group_not_found")
        }
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/v1/info"):
            var info: [String: Any] = [
                "protocols": self.protocols,
                "enrollment": self.enrollment,
                "maxBlobBytes": 65536,
            ]
            info["retentionDays"] = self.retentionDays
            return try Self.json(request, status: 200, info)
        case ("POST", "/v1/groups"):
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            self.lock.withLock { _ = self._groups.insert(body?["groupId"] ?? "") }
            return try Self.json(request, status: 201, ["limits": self.limits])
        case let ("PUT", putPath) where putPath.contains("/blobs/"):
            let hook = self.lock.withLock { self._beforePut.removeValue(forKey: parts[6]) }
            hook?()
            let etag = self.lock.withLock { () -> String? in
                let stored = self._blobs["\(parts[4])/\(parts[6])"]
                if let ifMatch = request.value(forHTTPHeaderField: "If-Match") {
                    guard let stored, ifMatch == "*" || ifMatch == Self.etag(stored.seq) else { return nil }
                }
                self.write(machineID: parts[4], name: parts[6], body: request.httpBody ?? Data())
                return Self.etag(self._seq)
            }
            guard let etag else { return Self.error(request, status: 412, code: "precondition_failed") }
            let after = self.lock.withLock { self._afterPut.removeValue(forKey: parts[6]) }
            after?()
            return try Self.json(request, status: 200, ["etag": etag, "updatedAt": "2026-09-24T12:00:00Z"])
        case let ("GET", getPath) where getPath.contains("/blobs/"):
            let stored = self.lock.withLock { self._blobs["\(parts[4])/\(parts[6])"] }
            guard let stored else { return Self.error(request, status: 404, code: "blob_not_found") }
            return Self.response(request, status: 200, body: stored.body, headers: ["ETag": Self.etag(stored.seq)])
        case ("DELETE", _) where parts.count == 5 && parts[3] == "machines":
            self.deleteMachine(parts[4])
            return Self.response(request, status: 204, body: Data())
        case let ("GET", changesPath) where changesPath.hasSuffix("/changes"):
            return try self.changes(request)
        default:
            return Self.error(request, status: 404, code: "not_found")
        }
    }

    private var limits: [String: Any] {
        ["maxMachines": 10, "retentionDays": self.retentionDays as Any, "expiresAt": NSNull()]
    }

    private func changes(_ request: URLRequest) throws -> (Data, URLResponse) {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let since = query.first { $0.name == "since" }?.value.flatMap(Int.init) ?? 0
        let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 100
        let formatter = ISO8601DateFormatter()
        return try self.lock.withLock {
            let pending = self._blobs.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
            let page = pending.prefix(limit)
            let machines = self._lastSeen.map { ["machineId": $0.key, "lastSeen": formatter.string(from: $0.value)] }
            let blobs = page.map {
                [
                    "machineId": $0.machineID,
                    "name": $0.name,
                    "etag": Self.etag($0.seq),
                    "updatedAt": "2026-09-24T12:00:00Z",
                    "body": $0.body.base64EncodedString(),
                ]
            }
            return try Self.json(request, status: 200, [
                "limits": self.limits,
                "machines": machines,
                "blobs": blobs,
                "cursor": self.stuckCursor ? String(since) : String(page.last?.seq ?? since),
                "hasMore": self.stuckCursor || pending.count > page.count,
            ])
        }
    }

    private static func json(_ request: URLRequest, status: Int, _ object: Any) throws -> (Data, URLResponse) {
        try self.response(request, status: status, body: JSONSerialization.data(withJSONObject: object))
    }

    private static func error(
        _ request: URLRequest,
        status: Int,
        code: String,
        headers: [String: String] = [:]) -> (Data, URLResponse)
    {
        let body = #"{"error":{"code":"\#(code)","message":"server says no"}}"#
        return self.response(request, status: status, body: Data(body.utf8), headers: headers)
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
    let server: FakeSyncServer
    let spend = TestSpend()
    var now: Date
    var hostName = "test-host"

    /// Pass another context's `server` to act as a second Machine in the same Sync Group.
    init(now: Date, server: FakeSyncServer = FakeSyncServer()) {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-sync-\(UUID().uuidString)", isDirectory: true)
        self.now = now
        self.server = server
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
            hostName: self.hostName,
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

    @discardableResult
    func pair(_ link: String, allowCleartext: Bool = false) async throws -> MachineSyncPairResult {
        try await MachineSyncPairer.pair(
            pairingLink: link,
            displayName: nil,
            allowCleartext: allowCleartext,
            environment: self.environment)
    }

    func push() async throws -> MachineSyncPushOutcome {
        try await MachineSyncPusher.push(environment: self.environment)
    }

    func refresh() async throws -> MachineSyncRefreshResult {
        try await MachineSyncReader.refresh(environment: self.environment)
    }

    func status(_ reportingDay: MachineSyncReportingDay = MachineSyncReportingDay(timeZone: "UTC")) async throws
        -> MachineSyncStatus
    {
        let cache = try await self.refresh().cache
        return try MachineSyncStatus(
            cache: cache,
            thisMachineID: self.store.loadSettings()?.machineID,
            reportingDay: reportingDay,
            now: self.now)
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
