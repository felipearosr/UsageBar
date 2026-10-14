import Foundation
import Testing
@testable import CodexBarCore

/// The per-row observer at each cost scanner's pricing boundary sees exactly the rows its daily report sums.
@Suite
struct CostUsageRowObserverLinuxTests {
    private static func observedTotals(_ rows: [CostUsageObservedRow]) -> (tokens: Int, cost: Double) {
        (rows.compactMap(\.totalTokens).reduce(0, +), rows.compactMap(\.costUSD).reduce(0, +))
    }

    // MARK: - Codex

    private static func codexLines(at start: Date, model: String, sessionID: String) -> [[String: Any]] {
        func tokenCount(_ offset: TimeInterval, input: Int, cached: Int, output: Int) -> [String: Any] {
            [
                "type": "event_msg",
                "timestamp": SpendBucketTestEnvironment.iso(start.addingTimeInterval(offset)),
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ]],
                ],
            ]
        }
        return [
            [
                "type": "session_meta",
                "timestamp": SpendBucketTestEnvironment.iso(start),
                "payload": ["id": sessionID],
            ],
            [
                "type": "turn_context",
                "timestamp": SpendBucketTestEnvironment.iso(start),
                "payload": ["model": model],
            ],
            tokenCount(0, input: 1000, cached: 200, output: 50),
            tokenCount(1800, input: 2500, cached: 900, output: 120),
            tokenCount(5400, input: 4000, cached: 1500, output: 300),
        ]
    }

    @Test
    func `codex observer rows add up to the daily report it prices`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let first = try SpendBucketTestEnvironment.utc(2025, 12, 20, 22, 30)
        let second = try SpendBucketTestEnvironment.utc(2025, 12, 21, 9, 0)
        try env.write(
            root: env.codexSessionsRoot,
            relativePath: "2025/12/20/rollout-a.jsonl",
            lines: Self.codexLines(at: first, model: "gpt-5.4", sessionID: "session-a"))
        try env.write(
            root: env.codexSessionsRoot,
            relativePath: "2025/12/21/rollout-b.jsonl",
            lines: Self.codexLines(at: second, model: "gpt-5.4", sessionID: "session-b"))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let since = try SpendBucketTestEnvironment.utc(2025, 12, 19, 0)
        let until = try SpendBucketTestEnvironment.utc(2025, 12, 23, 0)
        // Fill the store, then price its rows again with an observer attached.
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: options.calendar)
        let view = CostUsageStore(cacheRoot: env.cacheRoot)
            .syncLoadCodexReadView(calendar: range.calendar, purpose: .report)
            .scoped(to: CostUsageScanner.codexSessionsRoots(options: options))
        var rows: [CostUsageObservedRow] = []
        let report = view.dailyReport(
            range: range,
            cacheRoot: env.cacheRoot,
            rowObserver: CostUsageRowObserver { rows.append($0) })

        let totals = Self.observedTotals(rows)
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.provider == .codex && $0.model == "gpt-5.4" && $0.costUSD != nil })
        #expect(report.summary?.totalTokens == scanned.summary?.totalTokens)
        #expect(totals.tokens == report.summary?.totalTokens)
        #expect(abs(totals.cost - (report.summary?.totalCostUSD ?? -1)) < 0.000001)
        for row in rows {
            #expect((row.inputTokens ?? 0) + (row.cacheReadTokens ?? 0) + (row.outputTokens ?? 0) == row.totalTokens)
        }
    }

    // MARK: - Claude

    private static func claudeAssistant(
        at date: Date,
        model: String,
        messageID: String,
        input: Int,
        output: Int) -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "requestId": "req_\(messageID)",
            "message": [
                "id": messageID,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": 40,
                    "cache_read_input_tokens": 30,
                    "output_tokens": output,
                ],
            ],
        ]
    }

    @Test
    func `claude observer rows add up to the daily report it prices`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 23, 10)
        let sonnet = "claude-sonnet-4-20250514"
        let opus = "claude-opus-4-1-20250805"
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [
            Self.claudeAssistant(at: start, model: sonnet, messageID: "msg_1", input: 100, output: 10),
            // A later streaming chunk of the same message replaces the first.
            Self.claudeAssistant(at: start + 2, model: sonnet, messageID: "msg_1", input: 100, output: 25),
            Self.claudeAssistant(at: start + 3600, model: opus, messageID: "msg_2", input: 7, output: 300),
        ])
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-b/session.jsonl", lines: [
            Self.claudeAssistant(at: start + 7200, model: sonnet, messageID: "msg_3", input: 55, output: 5),
        ])

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let since = try SpendBucketTestEnvironment.utc(2025, 12, 19, 0)
        let until = try SpendBucketTestEnvironment.utc(2025, 12, 23, 0)
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: options)
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: options.calendar)
        let cache = CostUsageClaudeCacheIO.load(
            provider: .claude,
            cacheRoot: env.cacheRoot,
            reportContext: .regular,
            calendar: range.calendar).usage
        var rows: [CostUsageObservedRow] = []
        let report = CostUsageScanner.buildClaudeReportFromCache(
            cache: cache,
            range: range,
            now: until,
            modelsDevCacheRoot: env.cacheRoot,
            rowObserver: CostUsageRowObserver { rows.append($0) })

        let totals = Self.observedTotals(rows)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.provider == .claude && $0.requests == 1 })
        #expect(report.summary?.totalTokens == scanned.summary?.totalTokens)
        #expect(totals.tokens == report.summary?.totalTokens)
        #expect(totals.tokens == (100 + 70 + 25) + (7 + 70 + 300) + (55 + 70 + 5))
        #expect(abs(totals.cost - (report.summary?.totalCostUSD ?? -1)) < 0.000001)
    }

    // MARK: - Pi

    private static func piAssistant(
        at date: Date,
        provider: String = "anthropic",
        model: String = "claude-sonnet-4-6",
        id: String,
        usage: [String: Any]) -> [String: Any]
    {
        [
            "type": "message",
            "id": id,
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "message": [
                "role": "assistant",
                "provider": provider,
                "model": model,
                "timestamp": Int(date.timeIntervalSince1970 * 1000),
                "usage": usage,
            ],
        ]
    }

    @Test
    func `pi observer rows add up to the daily report for each provider`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2026, 4, 2, 23, 20)
        let full: [String: Any] = ["input": 80, "output": 20, "cacheRead": 4, "cacheWrite": 6, "totalTokens": 110]
        let partial: [String: Any] = ["input": 30, "output": 9]
        let codex: [String: Any] = ["input": 120, "output": 30, "cacheRead": 10, "totalTokens": 160]
        let fileURL = try env.write(
            root: env.piSessionsRoot,
            relativePath: "run/2026-04-02T23-00-00-000Z_s.jsonl",
            lines: [
                ["type": "session", "id": "pi-session-1"],
                Self.piAssistant(at: start, id: "e1", usage: full),
                Self.piAssistant(at: start + 3600, id: "e2", usage: partial),
                Self.piAssistant(
                    at: start + 600,
                    provider: "openai-codex",
                    model: "openai/gpt-5.4",
                    id: "e3",
                    usage: codex),
            ])

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let since = try SpendBucketTestEnvironment.utc(2026, 4, 1, 0)
        let until = try SpendBucketTestEnvironment.utc(2026, 4, 5, 0)
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: options.calendar)
        var rows: [CostUsageObservedRow] = []
        let parsed = try PiSessionCostScanner.parsePiSessionFile(
            fileURL: fileURL,
            range: range,
            pricingContext: PiSessionCostScanner.pricingContext(now: until, cacheRoot: env.cacheRoot),
            rowObserver: CostUsageRowObserver { rows.append($0) })
        #expect(parsed.isComplete)
        #expect(rows.map(\.entryID) == ["e1", "e2", "e3"])

        for provider in [UsageProvider.claude, .codex] {
            let daily = PiSessionCostScanner.loadDailyReport(
                provider: provider,
                since: since,
                until: until,
                now: until,
                options: options)
            let totals = Self.observedTotals(rows.filter { $0.provider == provider })
            #expect(totals.tokens == daily.summary?.totalTokens)
            #expect(abs(totals.cost - (daily.summary?.totalCostUSD ?? -1)) < 0.000001)
        }
    }

    @Test
    func `pi spend hours reparse only changed files and count forked entries once`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 10, 15)
        let shared = Self.piAssistant(at: at, id: "shared", usage: ["input": 80, "output": 20, "totalTokens": 100])
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-00-00-000Z_a.jsonl", lines: [
            ["type": "session", "id": "pi-session-fork"],
            shared,
            Self.piAssistant(at: at + 60, id: "a-only", usage: ["input": 5, "output": 1]),
        ])
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-05-00-000Z_b.jsonl", lines: [
            ["type": "session", "id": "pi-session-fork"],
            shared,
        ])

        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let since = try SpendBucketTestEnvironment.utc(2026, 4, 2, 0)
        let until = try SpendBucketTestEnvironment.utc(2026, 4, 3, 0)
        func load() throws -> [CostUsageSpendBucket] {
            try PiSessionCostScanner.loadSpendBuckets(
                provider: .claude,
                since: since,
                until: until,
                now: until,
                options: options,
                checkCancellation: nil)
        }

        let parses = ParseCounter()
        let countParse: @Sendable () -> Void = { parses.increment() }
        let first = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(countParse) { try load() }
        #expect(first.count == 1)
        #expect(first.first?.requests == 2)
        #expect(first.first?.totalTokens == 106)
        let daily = PiSessionCostScanner.loadDailyReport(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: options)
        #expect(first.first?.totalTokens == daily.summary?.totalTokens)
        let firstParses = parses.value
        #expect(firstParses >= 2)

        let second = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(countParse) { try load() }
        #expect(second == first)
        #expect(parses.value == firstParses)
        let hourCacheURL = PiSpendHourCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: hourCacheURL.path))
    }
}

private final class ParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
