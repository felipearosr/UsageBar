import Foundation

/// One Machine's local-log Spend for one provider and model within one UTC hour.
///
/// Numeric fields are `nil` when the log source doesn't report them, never `0`.
/// `costUSD` is `nil` when any contributing event has unknown pricing.
public struct CostUsageSpendBucket: Sendable, Equatable {
    /// Start of the UTC hour this bucket covers.
    public let hourStart: Date
    public let provider: UsageProvider
    public let model: String
    public var costUSD: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var totalTokens: Int?
    public var requests: Int?

    public init(
        hourStart: Date,
        provider: UsageProvider,
        model: String,
        costUSD: Double?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheCreationTokens: Int?,
        totalTokens: Int?,
        requests: Int?)
    {
        self.hourStart = hourStart
        self.provider = provider
        self.model = model
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.requests = requests
    }
}

extension CostUsageSpendBucket {
    struct Key: Hashable, Comparable {
        let hourStart: Date
        let model: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.hourStart, lhs.model) < (rhs.hourStart, rhs.model)
        }
    }

    var key: Key {
        Key(hourStart: self.hourStart, model: self.model)
    }

    /// Whole UTC hours since the Unix epoch; the compact hour key the scanner caches store.
    static func epochHour(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    /// Start of the UTC hour identified by `epochHour`.
    static func hourStart(epochHour: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochHour) * 3600)
    }

    /// Truncates `date` to the start of its UTC hour.
    static func hourStart(of date: Date) -> Date {
        self.hourStart(epochHour: self.epochHour(of: date))
    }

    /// Adds `other` into `self`. Counts add where either side reports them; cost stays known only
    /// while both sides are fully priced.
    mutating func absorb(_ other: CostUsageSpendBucket) {
        func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
            switch (lhs, rhs) {
            case let (lhs?, rhs?): lhs + rhs
            case let (lhs?, nil): lhs
            case let (nil, rhs?): rhs
            case (nil, nil): nil
            }
        }
        self.inputTokens = add(self.inputTokens, other.inputTokens)
        self.outputTokens = add(self.outputTokens, other.outputTokens)
        self.cacheReadTokens = add(self.cacheReadTokens, other.cacheReadTokens)
        self.cacheCreationTokens = add(self.cacheCreationTokens, other.cacheCreationTokens)
        self.totalTokens = add(self.totalTokens, other.totalTokens)
        self.requests = add(self.requests, other.requests)
        self.costUSD = if let lhs = self.costUSD, let rhs = other.costUSD { lhs + rhs } else { nil }
    }

    /// Combines bucket lists from several log sources for one provider, merging equal hour × model keys.
    /// The result is sorted by hour, then model.
    static func merged(_ lists: [CostUsageSpendBucket]...) -> [CostUsageSpendBucket] {
        var byKey: [Key: CostUsageSpendBucket] = [:]
        for bucket in lists.joined() {
            if var existing = byKey[bucket.key] {
                existing.absorb(bucket)
                byKey[bucket.key] = existing
            } else {
                byKey[bucket.key] = bucket
            }
        }
        return byKey.keys.sorted().compactMap { byKey[$0] }
    }
}

extension CostUsageScanner {
    /// Scans local session logs into UTC-hour Spend Buckets whose hour starts in `since..<until`.
    /// Only local-log providers (Codex, Claude) produce buckets; everything else returns `[]`.
    static func loadSpendBuckets(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck?) throws -> [CostUsageSpendBucket]
    {
        switch provider {
        case .codex:
            try self.loadCodexSpendBuckets(
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        case .claude:
            try self.loadClaudeSpendBuckets(
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        default:
            []
        }
    }
}

extension CostUsageSpendBucket {
    /// All local-log Spend Buckets for `provider`: the provider's own session logs plus Pi sessions that ran
    /// against it, merged per hour × model. Account Billing sources never feed this path.
    static func loadLocalLogBuckets(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        scannerOptions: CostUsageScanner.Options = CostUsageScanner.Options(),
        piOptions: PiSessionCostScanner.Options = PiSessionCostScanner.Options(),
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> [CostUsageSpendBucket]
    {
        var piOptions = piOptions
        if piOptions.cacheRoot == nil {
            piOptions.cacheRoot = scannerOptions.cacheRoot
        }
        let native = try CostUsageScanner.loadSpendBuckets(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: scannerOptions,
            checkCancellation: checkCancellation)
        let pi = try PiSessionCostScanner.loadSpendBuckets(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: piOptions,
            checkCancellation: checkCancellation)
        return Self.merged(native, pi)
    }
}
