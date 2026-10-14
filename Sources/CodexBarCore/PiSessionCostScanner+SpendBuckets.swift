import Foundation

// Pi Spend Buckets need each message's UTC hour. Upstream's Pi cache keys usage by local day and is
// updated incrementally, so hours can't be derived from it afterwards. Instead of extra fields in that
// cache, the fork keeps its own per-file hour cache beside it: the session files come from upstream's
// freshly refreshed cache, and any file whose identity, mtime or size changed is reparsed in full through
// `parsePiSessionFile` with a row observer.

/// Fork-owned UTC-hour usage per Pi session file.
struct PiSpendHourCache: Codable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var timeZoneIdentifier: String?
    var pricingKey: String?
    /// The local-day scan window every cached file was parsed with.
    var scanSinceKey: String?
    var scanUntilKey: String?
    var files: [String: PiSpendHourFile] = [:]
}

/// One session file's usage keyed provider → UTC hour key (see `PiSessionCostScanner.utcHourKey`) → model,
/// mirroring the day-keyed fields of `PiSessionFileUsage`.
struct PiSpendHourFile: Codable {
    var fileIdentity: String?
    var mtimeUnixMs: Int64
    var size: Int64
    var contributions: [String: [String: [String: PiPackedUsage]]] = [:]
    var unkeyedContributions: [String: [String: [String: PiPackedUsage]]] = [:]
    var entryUsages: [String: PiSpendHourEntry] = [:]

    func matches(_ usage: PiSessionFileUsage) -> Bool {
        self.fileIdentity == usage.fileIdentity && self.mtimeUnixMs == usage.mtimeUnixMs && self.size == usage.size
    }
}

struct PiSpendHourEntry: Codable, Equatable {
    var providerRawValue: String
    var hourKey: String
    var modelName: String
    var usage: PiPackedUsage
}

enum PiSpendHourCacheIO {
    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        PiSessionCostCacheIO.cacheFileURL(cacheRoot: cacheRoot)
            .deletingLastPathComponent()
            .appendingPathComponent("pi-spend-hours-v\(PiSpendHourCache.currentVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> PiSpendHourCache {
        guard let data = try? Data(contentsOf: self.cacheFileURL(cacheRoot: cacheRoot)),
              let decoded = try? JSONDecoder().decode(PiSpendHourCache.self, from: data),
              decoded.version == PiSpendHourCache.currentVersion
        else { return PiSpendHourCache() }
        return decoded
    }

    static func save(_ cache: PiSpendHourCache, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // Write at the final path: FileManager replacement can lose the destination on Linux.
        try? data.write(to: url, options: [.atomic])
        // Earlier fork builds kept hour data inside upstream's Pi cache as artifact v10.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("pi-sessions-v10.json"))
    }
}

extension PiPackedUsage {
    /// Packs one observed Pi message back into Pi's own counters, so hour sums stay in integer nanos.
    init(observed row: CostUsageObservedRow) {
        let requests = row.requests ?? 0
        self.init(
            inputTokens: row.inputTokens ?? 0,
            cacheReadTokens: row.cacheReadTokens ?? 0,
            cacheWriteTokens: row.cacheCreationTokens ?? 0,
            outputTokens: row.outputTokens ?? 0,
            totalTokens: row.totalTokens ?? 0,
            costNanos: row.costUSD.map { Int64(($0 * PiSessionCostScanner.costScale).rounded()) } ?? 0,
            costSampleCount: row.costUSD == nil ? 0 : requests,
            usageSampleCount: row.requests)
    }
}

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
        // The daily report refreshes and saves upstream's cache; its file list then drives the hour cache.
        _ = try self.loadDailyReportResultCancellable(
            provider: provider,
            since: since,
            until: until,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
        let cache = PiSessionCostCacheIO.load(cacheRoot: options.cacheRoot)
        let hours = try self.refreshSpendHours(
            cache: cache,
            range: CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: options.calendar),
            now: now,
            cacheRoot: options.cacheRoot,
            checkCancellation: checkCancellation)
        return self.buildSpendBuckets(provider: provider, cache: cache, hours: hours, since: since, until: until)
    }

    /// Brings the hour cache in line with the session files in upstream's `cache`, reparsing changed files.
    static func refreshSpendHours(
        cache: PiSessionCostCache,
        range: CostUsageScanner.CostUsageDayRange,
        now: Date,
        cacheRoot: URL?,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> PiSpendHourCache
    {
        let pricingContext = self.pricingContext(now: now, cacheRoot: cacheRoot)
        var hours = PiSpendHourCacheIO.load(cacheRoot: cacheRoot)
        var changed = false
        let coversRange = hours.scanSinceKey.map { $0 <= range.scanSinceKey } == true
            && hours.scanUntilKey.map { $0 >= range.scanUntilKey } == true
        if hours.timeZoneIdentifier != range.calendar.timeZone.identifier
            || hours.pricingKey != pricingContext.pricingKey
            || !coversRange
        {
            hours = PiSpendHourCache(
                timeZoneIdentifier: range.calendar.timeZone.identifier,
                pricingKey: pricingContext.pricingKey,
                scanSinceKey: range.scanSinceKey,
                scanUntilKey: range.scanUntilKey)
            changed = true
        }
        // Parse with the cached window so every file covers the same days.
        let parseRange = range.retainingScanWindow(
            since: hours.scanSinceKey ?? range.scanSinceKey,
            until: hours.scanUntilKey ?? range.scanUntilKey)

        for path in cache.files.keys.sorted() {
            guard let usage = cache.files[path] else { continue }
            if let cached = hours.files[path], cached.matches(usage) { continue }
            try checkCancellation?()
            // A file that can't be parsed completely keeps its previous hours and is retried next time.
            guard let parsed = try self.parseSpendHours(
                fileURL: URL(fileURLWithPath: path),
                usage: usage,
                range: parseRange,
                pricingContext: pricingContext,
                checkCancellation: checkCancellation)
            else { continue }
            hours.files[path] = parsed
            changed = true
        }
        for path in hours.files.keys where cache.files[path] == nil {
            hours.files.removeValue(forKey: path)
            changed = true
        }
        if changed {
            PiSpendHourCacheIO.save(hours, cacheRoot: cacheRoot)
        }
        return hours
    }

    /// Parses one whole session file into UTC-hour usage, or `nil` when the parse is incomplete.
    private static func parseSpendHours(
        fileURL: URL,
        usage: PiSessionFileUsage,
        range: CostUsageScanner.CostUsageDayRange,
        pricingContext: ModelsDevPricingContext,
        checkCancellation: CostUsageScanner.CancellationCheck?) throws -> PiSpendHourFile?
    {
        var file = PiSpendHourFile(fileIdentity: usage.fileIdentity, mtimeUnixMs: usage.mtimeUnixMs, size: usage.size)
        var sumsFit = true
        // Mirrors how `parsePiSessionFile` folds a message into `contributions`, `unkeyedContributions` and
        // `entryUsages`, on UTC hours instead of local days.
        let observer = CostUsageRowObserver { row in
            let providerKey = row.provider.rawValue
            let hourKey = Self.utcHourKey(row.timestamp)
            let packed = PiPackedUsage(observed: row)
            let delta = [providerKey: [hourKey: [row.model: packed]]]
            guard Self.applyContributions(daysByProvider: &file.contributions, contributions: delta) else {
                sumsFit = false
                return
            }
            guard let entryID = row.entryID else {
                if !Self.applyContributions(daysByProvider: &file.unkeyedContributions, contributions: delta) {
                    sumsFit = false
                }
                return
            }
            file.entryUsages[entryID] = PiSpendHourEntry(
                providerRawValue: providerKey,
                hourKey: hourKey,
                modelName: row.model,
                usage: packed)
        }
        let parsed = try self.parsePiSessionFile(
            fileURL: fileURL,
            range: range,
            pricingContext: pricingContext,
            checkCancellation: checkCancellation,
            rowObserver: observer)
        guard parsed.isComplete, sumsFit else { return nil }
        return file
    }

    /// Mirrors `rebuildDailyUsage` on UTC hours: a keyed entry counts once per session, even when forked
    /// session files repeat it.
    static func buildSpendBuckets(
        provider: UsageProvider,
        cache: PiSessionCostCache,
        hours: PiSpendHourCache,
        since: Date,
        until: Date) -> [CostUsageSpendBucket]
    {
        let providerKey = provider.rawValue
        var byHour: [String: [String: [String: PiPackedUsage]]] = [:]
        var seenEntriesBySessionID: [String: Set<String>] = [:]
        for path in cache.files.keys.sorted() {
            guard let usage = cache.files[path], let file = hours.files[path] else { continue }
            guard let sessionID = usage.sessionID else {
                _ = self.applyContributions(daysByProvider: &byHour, contributions: file.contributions)
                continue
            }
            _ = self.applyContributions(daysByProvider: &byHour, contributions: file.unkeyedContributions)
            var seenEntries = seenEntriesBySessionID[sessionID] ?? []
            for entryID in file.entryUsages.keys.sorted() where seenEntries.insert(entryID).inserted {
                guard let entry = file.entryUsages[entryID], entry.providerRawValue == providerKey else { continue }
                _ = self.applyContributions(
                    daysByProvider: &byHour,
                    contributions: [providerKey: [entry.hourKey: [entry.modelName: entry.usage]]])
            }
            seenEntriesBySessionID[sessionID] = seenEntries
        }

        // Pi stores a field the log omitted as 0, so 0 is reported as absent.
        let reported: (Int) -> Int? = { $0 > 0 ? $0 : nil }
        var buckets: [CostUsageSpendBucket] = []
        for (hourKey, models) in byHour[providerKey] ?? [:] {
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
