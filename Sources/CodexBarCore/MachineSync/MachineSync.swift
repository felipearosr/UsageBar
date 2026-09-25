import Crypto
import Foundation

/// Loads this Machine's Spend Buckets whose hour starts in `since..<until`.
public typealias MachineSyncSpendSource = @Sendable (_ since: Date, _ until: Date) async throws
    -> [CostUsageSpendBucket]

public enum MachineSyncSpend {
    /// Local-log providers only (§5.2): Codex and Claude session logs, with Pi sessions folded into each.
    /// Account Billing sources never feed Machine Sync.
    public static let providers: [UsageProvider] = [.codex, .claude]

    public static func localLogs(cacheRoot: URL? = nil) -> MachineSyncSpendSource {
        { since, until in
            await ModelsDevPricingPipeline.refreshIfNeeded(cacheRoot: cacheRoot)
            return try await CostUsageScanExecutor.run { checkCancellation in
                try Self.providers.flatMap { provider in
                    try CostUsageSpendBucket.loadLocalLogBuckets(
                        provider: provider,
                        since: since,
                        until: until,
                        scannerOptions: CostUsageScanner.Options(cacheRoot: cacheRoot),
                        checkCancellation: checkCancellation)
                }
            }
        }
    }
}

/// Everything Machine Sync needs from the outside world, injectable for tests.
public struct MachineSyncEnvironment: Sendable {
    public var store: MachineSyncStore
    public var transport: any ProviderHTTPTransport
    public var spendSource: MachineSyncSpendSource
    public var clientVersion: String
    public var hostName: String
    public var now: @Sendable () -> Date

    public init(
        store: MachineSyncStore = MachineSyncStore(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        spendSource: @escaping MachineSyncSpendSource = MachineSyncSpend.localLogs(),
        clientVersion: String,
        hostName: String = MachineSyncEnvironment.defaultHostName(),
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.store = store
        self.transport = transport
        self.spendSource = spendSource
        self.clientVersion = clientVersion
        self.hostName = hostName
        self.now = now
    }

    public static func defaultHostName() -> String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") {
            name.removeLast(".local".count)
        }
        return name.isEmpty ? "machine" : name
    }
}

// MARK: - Create

public struct MachineSyncCreateResult: Sendable {
    public let link: MachineSyncPairingLink
    public let limits: MachineSyncClient.Limits
    public let settings: MachineSyncSettings
}

public enum MachineSyncGroupCreator {
    /// Generates a Sync Group key on this Machine, registers the group on the server, and saves the Pairing
    /// Link. Nothing touches the network until the server address has been validated.
    public static func create(
        serverURL: String,
        enrollmentToken: String?,
        displayName: String?,
        environment: MachineSyncEnvironment) async throws -> MachineSyncCreateResult
    {
        let existing = try environment.store.loadSettings()
        guard existing?.pairingLink == nil else { throw MachineSyncError.alreadyPaired }

        let link = try MachineSyncPairingLink(serverURL: serverURL, rootKey: .generate())
        let keys = link.keys
        let client = MachineSyncClient(apiBaseURL: link.apiBaseURL, transport: environment.transport)
        let token = enrollmentToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let info = try await client.info()
        guard info.protocols.contains(1) else { throw MachineSyncError.unsupportedServer }
        if info.enrollment == "required", token == nil { throw MachineSyncError.enrollmentTokenRequired }
        let limits = try await client.createGroup(
            keys: keys,
            enrollmentToken: info.enrollment == "none" ? nil : token)

        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let settings = MachineSyncSettings(
            machineID: existing?.machineID ?? MachineSyncMachineID.generate(),
            displayName: name ?? existing?.displayName ?? environment.hostName,
            pairingLink: link.link)
        try environment.store.saveSettings(settings)
        try environment.store.saveState(MachineSyncPushState(
            groupID: keys.groupIDBase64URL,
            retentionDays: limits.retentionDays ?? info.retentionDays))
        return MachineSyncCreateResult(link: link, limits: limits, settings: settings)
    }
}

// MARK: - Pair

public struct MachineSyncPairResult: Sendable {
    public let link: MachineSyncPairingLink
    public let settings: MachineSyncSettings
    public let retentionDays: Int?
}

public enum MachineSyncPairer {
    /// Joins the Sync Group in `pairingLink`. The server and the key are checked before anything is saved, and
    /// the next push backfills this Machine's Spend (§8.2).
    ///
    /// - Parameter allowCleartext: the user confirmed plain `http://` to a host that isn't loopback (§2).
    public static func pair(
        pairingLink: String,
        displayName: String?,
        allowCleartext: Bool,
        environment: MachineSyncEnvironment) async throws -> MachineSyncPairResult
    {
        let existing = try environment.store.loadSettings()
        guard existing?.pairingLink == nil else { throw MachineSyncError.alreadyPaired }

        let link = try MachineSyncPairingLink(parsing: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines))
        if link.cleartextWarning, !allowCleartext { throw MachineSyncError.cleartextNotConfirmed(host: link.host) }
        let keys = link.keys
        let client = MachineSyncClient(apiBaseURL: link.apiBaseURL, transport: environment.transport)

        let info = try await client.info()
        guard info.protocols.contains(1) else { throw MachineSyncError.unsupportedServer }
        // Proves the group exists and the key is right (`404 group_not_found` otherwise).
        let page = try await client.changes(keys: keys, since: nil, limit: 1)
        let retentionDays = page.limits?.retentionDays ?? info.retentionDays

        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let settings = MachineSyncSettings(
            machineID: existing?.machineID ?? MachineSyncMachineID.generate(),
            displayName: name ?? existing?.displayName ?? environment.hostName,
            pairingLink: link.link,
            reportingDay: existing?.reportingDay)
        try environment.store.saveSettings(settings)
        try environment.store.saveState(MachineSyncPushState(
            groupID: keys.groupIDBase64URL,
            retentionDays: retentionDays))
        return MachineSyncPairResult(link: link, settings: settings, retentionDays: retentionDays)
    }
}

// MARK: - Push

public enum MachineSyncPushOutcome: Sendable, Equatable {
    /// `uploaded` lists the blob names PUT this run; `unchanged` counts blobs skipped because nothing changed.
    case pushed(uploaded: [String], unchanged: Int)
    /// Another process on this Machine holds the push lock.
    case skippedLocked
    /// A previous transient failure asked us to wait.
    case backingOff(until: Date)
}

public enum MachineSyncPusher {
    static let backoffBase: TimeInterval = 60
    static let backoffCap: TimeInterval = 15 * 60
    /// `profile` is re-uploaded at least this often so Last Seen stays under the 5-minute active threshold (§8.3)
    /// on a Machine that is online but has no new Spend.
    public static let heartbeatInterval: TimeInterval = 120
    /// How far back the backfill reaches when the server doesn't report `retentionDays`.
    public static let defaultBackfillDays = 400

    /// One push cycle (§8.1): take the lock, scan today and yesterday (UTC), and PUT each `day-*` blob and
    /// `profile` whose plaintext changed since the last successful upload. The first push after `create` or
    /// `pair` backfills every day inside the retention window instead (§8.2).
    public static func push(environment: MachineSyncEnvironment) async throws -> MachineSyncPushOutcome {
        guard let settings = try environment.store.loadSettings(), let rawLink = settings.pairingLink else {
            throw MachineSyncError.notPaired
        }
        let link = try MachineSyncPairingLink(parsing: rawLink)
        guard let lock = try MachineSyncPushLock.acquire(at: environment.store.lockURL) else {
            return .skippedLocked
        }
        defer { withExtendedLifetime(lock) {} }

        let keys = link.keys
        let now = environment.now()
        var state = try environment.store.loadState() ?? MachineSyncPushState()
        if state.groupID != keys.groupIDBase64URL {
            state = MachineSyncPushState(groupID: keys.groupIDBase64URL)
        }
        if let nextAttemptAt = state.nextAttemptAt, nextAttemptAt > now {
            return .backingOff(until: nextAttemptAt)
        }

        var cycle = PushCycle(
            client: MachineSyncClient(apiBaseURL: link.apiBaseURL, transport: environment.transport),
            keys: keys,
            machineID: settings.machineID)
        do {
            try await cycle.run(settings: settings, environment: environment, now: now, state: &state)
        } catch let error as MachineSyncError where error.isTransient {
            state.consecutiveFailures += 1
            state.nextAttemptAt = now.addingTimeInterval(Self.backoffDelay(
                failures: state.consecutiveFailures,
                retryAfter: error.retryAfter))
            try environment.store.saveState(state)
            throw error
        } catch {
            try environment.store.saveState(state)
            throw error
        }
        state.consecutiveFailures = 0
        state.nextAttemptAt = nil
        try environment.store.saveState(state)
        return .pushed(uploaded: cycle.uploaded, unchanged: cycle.unchanged)
    }

    /// 60 s, doubling per consecutive failure, capped at 15 minutes; a longer `Retry-After` wins below the cap.
    static func backoffDelay(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponential = Self.backoffBase * pow(2, Double(max(0, min(failures - 1, 10))))
        return min(Self.backoffCap, max(exponential, retryAfter ?? 0))
    }
}

private struct PushCycle {
    let client: MachineSyncClient
    let keys: MachineSyncKeys
    let machineID: String
    var uploaded: [String] = []
    var unchanged = 0

    mutating func run(
        settings: MachineSyncSettings,
        environment: MachineSyncEnvironment,
        now: Date,
        state: inout MachineSyncPushState) async throws
    {
        let today = MachineSyncDay.startOfDay(now)
        let backfilling = state.backfilledAt == nil
        // Machines paired before backfill existed never recorded retention; ask once before reaching back.
        if backfilling, state.retentionDays == nil {
            state.retentionDays = try await self.client.info().retentionDays
        }
        let retentionStart = today.addingTimeInterval(
            -86400 * Double(state.retentionDays ?? MachineSyncPusher.defaultBackfillDays))
        // Never upload a day the server would already have dropped (§7).
        let firstDay = max(backfilling ? retentionStart : today.addingTimeInterval(-86400), retentionStart)
        let window = stride(from: firstDay, through: today, by: 86400).map(MachineSyncDay.blobName(for:))
        let buckets = try await environment.spendSource(firstDay, today.addingTimeInterval(86400))
        let days = MachineSyncDayBlob.days(from: buckets)

        // Hashes of days that left the window are never needed again.
        state.uploadedHashes = state.uploadedHashes.filter { $0.key == "profile" || window.contains($0.key) }

        for name in window {
            guard let day = days[name], !day.buckets.isEmpty else { continue }
            let plaintext = try MachineSyncJSON.encode(day)
            try await self.putIfChanged(name: name, plaintext: plaintext, hashed: plaintext, state: &state)
            let date = String(name.dropFirst("day-".count))
            state.coverageStart = min(state.coverageStart ?? date, date)
        }
        if backfilling {
            state.backfilledAt = now
        }
        // The server deletes days older than retention, so Coverage can't start before the oldest kept day.
        if state.retentionDays != nil, let coverageStart = state.coverageStart {
            state.coverageStart = max(coverageStart, MachineSyncDay.dateString(for: retentionStart))
        }

        var profile = MachineSyncProfile(
            displayName: settings.displayName ?? environment.hostName,
            platform: MachineSyncProfile.currentPlatform,
            clientVersion: environment.clientVersion,
            coverageStart: state.coverageStart,
            pushedAt: nil)
        // `pushedAt` changes every run, so it stays out of the hash; otherwise profile would always upload.
        // The heartbeat re-uploads it anyway once Last Seen would start to look stale.
        let hashed = try MachineSyncJSON.encode(profile)
        profile.pushedAt = ISO8601DateFormatter().string(from: now)
        let heartbeatDue = state.profileUploadedAt
            .map { now.timeIntervalSince($0) >= MachineSyncPusher.heartbeatInterval } ?? true
        let uploadedBefore = self.uploaded.count
        try await self.putIfChanged(
            name: "profile",
            plaintext: MachineSyncJSON.encode(profile),
            hashed: hashed,
            force: heartbeatDue,
            state: &state)
        if self.uploaded.count > uploadedBefore {
            state.profileUploadedAt = now
        }
    }

    private mutating func putIfChanged(
        name: String,
        plaintext: Data,
        hashed: Data,
        force: Bool = false,
        state: inout MachineSyncPushState) async throws
    {
        let hash = SHA256.hash(data: hashed).map { String(format: "%02x", $0) }.joined()
        guard force || state.uploadedHashes[name] != hash else {
            self.unchanged += 1
            return
        }
        let address = MachineSyncBlobAddress(
            groupID: self.keys.groupIDBase64URL,
            machineID: self.machineID,
            name: name)
        let envelope = try MachineSyncEnvelope.seal(plaintext, encKey: self.keys.encKey, address: address)
        try await self.client.putBlob(envelope, at: address, keys: self.keys)
        state.uploadedHashes[name] = hash
        self.uploaded.append(name)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
