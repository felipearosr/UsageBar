import Foundation

// MARK: - Daily breakdown

extension MachineSyncStatus {
    /// Spend summed over Spend Buckets: cost of the priced ones, the token split, and requests.
    public struct DailySpend: Sendable, Equatable {
        /// `nil` when none of the buckets was priced.
        public var totalCost: Double?
        /// Some buckets had no price, so `totalCost` is a lower bound (or absent).
        public var costIncomplete = false
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheCreationTokens = 0
        public var totalTokens = 0
        public var requests = 0

        public init() {}

        mutating func add(_ bucket: MachineSyncDayBlob.Bucket) {
            if let cost = bucket.costUSD {
                self.totalCost = (self.totalCost ?? 0) + cost
            } else {
                self.costIncomplete = true
            }
            self.inputTokens += bucket.inputTokens ?? 0
            self.outputTokens += bucket.outputTokens ?? 0
            self.cacheReadTokens += bucket.cacheReadTokens ?? 0
            self.cacheCreationTokens += bucket.cacheCreationTokens ?? 0
            self.totalTokens += bucket.totalTokens ?? 0
            self.requests += bucket.requests ?? 0
        }
    }

    /// One model's Spend on one Reporting Day.
    public struct DailyModel: Encodable, Sendable, Equatable {
        public let modelName: String
        /// `nil` when none of this model's buckets that day was priced.
        public let cost: Double?
        public let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case modelName
            case cost
            case totalTokens
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.modelName, forKey: .modelName)
            // Always present: `null` means unpriced.
            try container.encode(self.cost, forKey: .cost)
            try container.encode(self.totalTokens, forKey: .totalTokens)
        }
    }

    /// One provider's Spend on one Reporting Day, most expensive model first.
    public struct DailyProvider: Encodable, Sendable, Equatable {
        public let provider: String
        public let spend: DailySpend
        public let modelBreakdowns: [DailyModel]

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: DailyCodingKeys.self)
            try container.encode(self.provider, forKey: .provider)
            try container.encodeSpend(self.spend)
            try container.encode(self.modelBreakdowns, forKey: .modelBreakdowns)
        }
    }

    /// One Reporting Day of a Machine's Spend, shaped like a local cost report's `daily` entry.
    public struct DailyEntry: Encodable, Sendable, Equatable {
        /// Reporting Day, `YYYY-MM-DD`.
        public let date: String
        public let spend: DailySpend
        /// Ordered by provider ID.
        public let providers: [DailyProvider]

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: DailyCodingKeys.self)
            try container.encode(self.date, forKey: .date)
            try container.encodeSpend(self.spend)
            try container.encode(self.providers, forKey: .providers)
        }
    }

    enum DailyCodingKeys: String, CodingKey {
        case date
        case provider
        case totalCost
        case costIncomplete
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case totalTokens
        case requests
        case providers
        case modelBreakdowns
    }

    /// Sums buckets per Reporting Day, provider, and model for `daily`.
    struct DailyAccumulator {
        private struct Provider {
            var spend = DailySpend()
            var models: [String: DailySpend] = [:]
        }

        private struct Day {
            var spend = DailySpend()
            var providers: [String: Provider] = [:]
        }

        private var days: [String: Day] = [:]

        mutating func add(_ bucket: MachineSyncDayBlob.Bucket, day: String) {
            var entry = self.days[day] ?? Day()
            entry.spend.add(bucket)
            var provider = entry.providers[bucket.provider] ?? Provider()
            provider.spend.add(bucket)
            provider.models[bucket.model, default: DailySpend()].add(bucket)
            entry.providers[bucket.provider] = provider
            self.days[day] = entry
        }

        /// Entries for the days in `window` that have Spend, in `window` order.
        func entries(in window: [String]) -> [DailyEntry] {
            window.compactMap { date in
                guard let day = self.days[date] else { return nil }
                let providers = day.providers
                    .sorted { $0.key < $1.key }
                    .map { provider, entry in
                        DailyProvider(
                            provider: provider,
                            spend: entry.spend,
                            modelBreakdowns: entry.models
                                .map { DailyModel(
                                    modelName: $0.key,
                                    cost: $0.value.totalCost,
                                    totalTokens: $0.value.totalTokens) }
                                .sorted { ($0.cost ?? -1, $1.modelName) > ($1.cost ?? -1, $0.modelName) })
                    }
                return DailyEntry(date: date, spend: day.spend, providers: providers)
            }
        }
    }
}

extension KeyedEncodingContainer where K == MachineSyncStatus.DailyCodingKeys {
    fileprivate mutating func encodeSpend(_ spend: MachineSyncStatus.DailySpend) throws {
        // Always present: `null` means nothing was priced.
        try self.encode(spend.totalCost, forKey: .totalCost)
        try self.encode(spend.costIncomplete, forKey: .costIncomplete)
        try self.encode(spend.inputTokens, forKey: .inputTokens)
        try self.encode(spend.outputTokens, forKey: .outputTokens)
        try self.encode(spend.cacheReadTokens, forKey: .cacheReadTokens)
        try self.encode(spend.cacheCreationTokens, forKey: .cacheCreationTokens)
        try self.encode(spend.totalTokens, forKey: .totalTokens)
        try self.encode(spend.requests, forKey: .requests)
    }
}
