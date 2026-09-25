import Foundation

/// `profile` (§5.2): one per Machine, rewritten whenever it changes.
public struct MachineSyncProfile: Codable, Sendable, Equatable {
    public var v: Int = 1
    public var displayName: String
    public var platform: String
    public var clientVersion: String
    /// UTC date (`YYYY-MM-DD`) of the oldest day blob this Machine has uploaded.
    public var coverageStart: String?
    public var pushedAt: String?

    public init(
        displayName: String,
        platform: String,
        clientVersion: String,
        coverageStart: String?,
        pushedAt: String?)
    {
        self.displayName = displayName
        self.platform = platform
        self.clientVersion = clientVersion
        self.coverageStart = coverageStart
        self.pushedAt = pushedAt
    }

    public static var currentPlatform: String {
        #if os(macOS)
        "macos"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }
}

/// `day-YYYY-MM-DD` (§5.2): one Machine's complete Spend for one UTC day.
public struct MachineSyncDayBlob: Codable, Sendable, Equatable {
    public struct Bucket: Codable, Sendable, Equatable {
        public var hour: Int
        public var provider: String
        public var model: String
        public var costUSD: Double?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var cacheCreationTokens: Int?
        public var totalTokens: Int?
        public var requests: Int?
    }

    public var v: Int = 1
    public var buckets: [Bucket]

    /// Groups Spend Buckets into day blobs keyed by blob name (`day-YYYY-MM-DD`, UTC), buckets ordered by
    /// hour, provider, then model.
    public static func days(from spendBuckets: [CostUsageSpendBucket]) -> [String: MachineSyncDayBlob] {
        var byDay: [String: [Bucket]] = [:]
        for spend in spendBuckets {
            let components = MachineSyncDay.utcCalendar.dateComponents([.hour], from: spend.hourStart)
            byDay[MachineSyncDay.blobName(for: spend.hourStart), default: []].append(Bucket(
                hour: components.hour ?? 0,
                provider: spend.provider.rawValue,
                model: spend.model,
                costUSD: spend.costUSD,
                inputTokens: spend.inputTokens,
                outputTokens: spend.outputTokens,
                cacheReadTokens: spend.cacheReadTokens,
                cacheCreationTokens: spend.cacheCreationTokens,
                totalTokens: spend.totalTokens,
                requests: spend.requests))
        }
        return byDay.mapValues { buckets in
            MachineSyncDayBlob(buckets: buckets.sorted {
                ($0.hour, $0.provider, $0.model) < ($1.hour, $1.provider, $1.model)
            })
        }
    }
}

/// UTC day helpers shared by blob naming and the push window.
public enum MachineSyncDay {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static func startOfDay(_ date: Date) -> Date {
        self.utcCalendar.startOfDay(for: date)
    }

    public static func dateString(for date: Date) -> String {
        self.dateString(self.utcCalendar.dateComponents([.year, .month, .day], from: date))
    }

    /// `YYYY-MM-DD` for calendar date components, in whatever calendar produced them.
    static func dateString(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func blobName(for date: Date) -> String {
        "day-\(self.dateString(for: date))"
    }
}

enum MachineSyncJSON {
    /// Deterministic encoding, so equal content always hashes the same.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
