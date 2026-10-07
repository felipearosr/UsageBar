import Foundation

extension PiSessionCostScanner {
    /// Cache key for the UTC hour containing `date`.
    static func utcHourKey(_ date: Date) -> String {
        String(CostUsageSpendBucket.epochHour(of: date))
    }

    /// Scans Pi session logs into UTC-hour Spend Buckets for `provider` whose hour starts in `since..<until`.
    static func loadSpendBuckets(
        provider: UsageProvider,
        since: Date,
        until: Date,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> [CostUsageSpendBucket]
    {
        // Provider-specific by design: Pi sessions fold only into the Codex and Claude local-log buckets.
        guard provider == .codex || provider == .claude else { return [] }
        // The daily report refreshes and saves the cache; the buckets then read the same entries.
        _ = try self.loadDailyReportResultCancellable(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
        let cache = PiSessionCostCacheIO.load(cacheRoot: options.cacheRoot)
        return self.buildSpendBuckets(provider: provider, cache: cache, since: since, until: until)
    }

    /// Mirrors `rebuildDailyUsage` on UTC hours: a keyed entry counts once per session, even when forked
    /// session files repeat it.
    static func buildSpendBuckets(
        provider: UsageProvider,
        cache: PiSessionCostCache,
        since: Date,
        until: Date) -> [CostUsageSpendBucket]
    {
        let providerKey = provider.rawValue
        var hours: [String: [String: [String: PiPackedUsage]]] = [:]
        var seenEntriesBySessionID: [String: Set<String>] = [:]
        for path in cache.files.keys.sorted() {
            guard let usage = cache.files[path] else { continue }
            guard let sessionID = usage.sessionID else {
                _ = self.applyContributions(daysByProvider: &hours, contributions: usage.hourContributions)
                continue
            }
            _ = self.applyContributions(daysByProvider: &hours, contributions: usage.unkeyedHourContributions)
            var seenEntries = seenEntriesBySessionID[sessionID] ?? []
            for entryID in usage.entryUsages.keys.sorted() where seenEntries.insert(entryID).inserted {
                guard let entry = usage.entryUsages[entryID], entry.providerRawValue == providerKey,
                      let hourKey = entry.hourKey
                else { continue }
                _ = self.applyContributions(
                    daysByProvider: &hours,
                    contributions: [providerKey: [hourKey: [entry.modelName: entry.usage]]])
            }
            seenEntriesBySessionID[sessionID] = seenEntries
        }

        // Pi stores a field the log omitted as 0, so 0 is reported as absent.
        let reported: (Int) -> Int? = { $0 > 0 ? $0 : nil }
        var buckets: [CostUsageSpendBucket] = []
        for (hourKey, models) in hours[providerKey] ?? [:] {
            guard let epochHour = Int64(hourKey) else { continue }
            let hourStart = CostUsageSpendBucket.hourStart(epochHour: epochHour)
            guard hourStart >= since, hourStart < until else { continue }
            for (modelName, packed) in models {
                let requests = packed.usageSampleCount ?? 0
                // Each message was priced when parsed; one unpriced message leaves the hour's cost unknown.
                let isFullyPriced = requests > 0 && packed.costSampleCount == requests
                buckets.append(CostUsageSpendBucket(
                    hourStart: hourStart,
                    provider: provider,
                    model: modelName,
                    costUSD: isFullyPriced ? Double(packed.costNanos) / Self.costScale : nil,
                    inputTokens: reported(packed.inputTokens),
                    outputTokens: reported(packed.outputTokens),
                    cacheReadTokens: reported(packed.cacheReadTokens),
                    cacheCreationTokens: reported(packed.cacheWriteTokens),
                    totalTokens: reported(max(
                        packed.totalTokens,
                        packed.inputTokens + packed.cacheReadTokens + packed.cacheWriteTokens + packed.outputTokens)),
                    requests: packed.usageSampleCount))
            }
        }
        return CostUsageSpendBucket.merged(buckets)
    }
}
