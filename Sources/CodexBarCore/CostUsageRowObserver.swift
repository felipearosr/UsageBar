import Foundation

/// One usage row as a cost scanner priced it.
///
/// Token counts are `nil` when the log doesn't report the field, never `0`. `costUSD` is `nil` when the
/// scanner couldn't price the row.
struct CostUsageObservedRow: Equatable {
    let provider: UsageProvider
    let model: String
    let timestamp: Date
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?
    var totalTokens: Int?
    var costUSD: Double?
    var requests: Int?
    /// The log entry's own identifier, for sources that repeat entries across files (Pi forked sessions).
    var entryID: String?
}

/// Receives every usage row a cost scanner prices.
///
/// The Codex, Claude and Pi scanners take an optional `rowObserver` and call it from their pricing loops;
/// everything built from the rows (Spend Buckets) lives outside the scanners. The `observe…` adapters
/// below turn each scanner's own row type into a `CostUsageObservedRow`, so the scanner call sites stay
/// one line each.
final class CostUsageRowObserver {
    private let onRow: (CostUsageObservedRow) -> Void

    init(_ onRow: @escaping (CostUsageObservedRow) -> Void) {
        self.onRow = onRow
    }

    func observe(_ row: CostUsageObservedRow) {
        self.onRow(row)
    }
}

// MARK: - Scanner adapters

extension CostUsageRowObserver {
    /// A Codex row priced by `addCodexHourly`. `costUSD` is `nil` when any of the row's tokens are unpriced.
    func observeCodex(_ row: CostUsageScanner.CodexUsageRow, timestamp: Date, costUSD: Double?) {
        let cached = min(row.cached, row.input)
        // Codex `input` includes cached tokens; observed rows count them separately. Codex logs have no
        // cache-creation count.
        // Provider-specific by design: this adapter only ever reads Codex scanner rows.
        self.observe(CostUsageObservedRow(
            provider: .codex,
            model: row.model,
            timestamp: timestamp,
            inputTokens: row.input - cached,
            outputTokens: row.output,
            cacheReadTokens: cached,
            cacheCreationTokens: nil,
            totalTokens: row.input + row.output,
            costUSD: costUSD,
            requests: 1))
    }

    /// A Claude cache row repriced by `claudeTemporalPricing`. Rows cached without a timestamp are skipped.
    func observeClaude(_ row: CostUsageScanner.ClaudeUsageRow, costUSD: Double?) {
        guard let timestampUnixMs = row.timestampUnixMs else { return }
        let timestamp = Date(timeIntervalSince1970: Double(timestampUnixMs) / 1000)
        // An incomplete streaming estimate has no trustworthy counts or cost; it still counts as a request.
        guard row.isIncomplete != true else {
            // Provider-specific by design: this adapter only ever reads Claude transcript cache rows.
            self.observe(CostUsageObservedRow(
                provider: .claude,
                model: row.model,
                timestamp: timestamp,
                requests: 1))
            return
        }
        let omitted = row.omittedFields ?? []
        func reported(_ value: Int, _ field: CostUsageScanner.ClaudeUsageFields) -> Int? {
            omitted.contains(field) ? nil : value
        }
        // Provider-specific by design: this adapter only ever reads Claude transcript cache rows.
        self.observe(CostUsageObservedRow(
            provider: .claude,
            model: row.model,
            timestamp: timestamp,
            inputTokens: reported(row.input, .input),
            outputTokens: reported(row.output, .output),
            cacheReadTokens: reported(row.cacheRead, .cacheRead),
            cacheCreationTokens: reported(row.cacheCreate, .cacheCreation),
            totalTokens: row.input + row.cacheRead + row.cacheCreate + row.output,
            costUSD: costUSD,
            requests: 1))
    }

    /// One Pi assistant message as `parsePiSessionFile` priced it.
    func observePi(provider: UsageProvider, model: String, timestamp: Date, usage: PiPackedUsage, entryID: String?) {
        guard !usage.isZero else { return }
        /// Pi stores a field the log omitted as 0, so 0 is reported as absent.
        func reported(_ value: Int) -> Int? {
            value > 0 ? value : nil
        }
        let requests = usage.usageSampleCount ?? 0
        // Each message is priced when parsed; an unpriced one carries no cost sample.
        let isPriced = requests > 0 && usage.costSampleCount == requests
        self.observe(CostUsageObservedRow(
            provider: provider,
            model: model,
            timestamp: timestamp,
            inputTokens: reported(usage.inputTokens),
            outputTokens: reported(usage.outputTokens),
            cacheReadTokens: reported(usage.cacheReadTokens),
            cacheCreationTokens: reported(usage.cacheWriteTokens),
            totalTokens: reported(usage.totalTokens),
            costUSD: isPriced ? Double(usage.costNanos) / PiSessionCostScanner.costScale : nil,
            requests: usage.usageSampleCount,
            entryID: entryID))
    }
}

// MARK: - Claude omitted usage fields

extension CostUsageScanner {
    /// Usage fields a Claude log line left out. Encoded as its raw bitmask so identical rows always persist
    /// identical bytes.
    struct ClaudeUsageFields: OptionSet, Codable, Hashable {
        let rawValue: UInt8

        static let input = Self(rawValue: 1 << 0)
        static let output = Self(rawValue: 1 << 1)
        static let cacheRead = Self(rawValue: 1 << 2)
        static let cacheCreation = Self(rawValue: 1 << 3)
    }

    /// Usage fields missing (or `null`) in a log line's `usage` object; `nil` when every field is present.
    static func claudeOmittedUsageFields(_ usage: ClaudeJSONObject) -> ClaudeUsageFields? {
        let usageKeys: [(String, ClaudeUsageFields)] = [
            ("input_tokens", .input),
            ("output_tokens", .output),
            ("cache_read_input_tokens", .cacheRead),
            ("cache_creation_input_tokens", .cacheCreation),
        ]
        let omitted = ClaudeUsageFields(usageKeys.filter { key, _ in usage[key] == nil || usage[key] is NSNull }
            .map(\.1))
        return omitted.isEmpty ? nil : omitted
    }
}
