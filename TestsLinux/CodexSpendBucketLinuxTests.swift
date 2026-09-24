@testable import CodexBarCore
import Foundation
import Testing

@Suite
struct CodexSpendBucketLinuxTests {
    private static let model = "gpt-5.4"

    private static func sessionMeta(at date: Date) -> [String: Any] {
        [
            "type": "session_meta",
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "payload": ["id": "session-\(Int(date.timeIntervalSince1970))"],
        ]
    }

    private static func turnContext(at date: Date, model: String = Self.model) -> [String: Any] {
        [
            "type": "turn_context",
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "payload": ["model": model],
        ]
    }

    /// A `token_count` event carrying cumulative session totals.
    private static func tokenCount(at date: Date, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }

    @discardableResult
    private static func writeSession(
        _ env: SpendBucketTestEnvironment,
        startedAt: Date,
        lines: [[String: Any]]) throws -> URL
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: startedAt)
        let dir = String(format: "%04d/%02d/%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        return try env.write(root: env.codexSessionsRoot, relativePath: "\(dir)/session.jsonl", lines: lines)
    }

    private static func options(_ env: SpendBucketTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func load(
        _ env: SpendBucketTestEnvironment,
        since: Date,
        until: Date) throws -> [CostUsageSpendBucket]
    {
        try CostUsageScanner.loadSpendBuckets(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: Self.options(env),
            checkCancellation: nil)
    }

    @Test
    func `session crossing UTC midnight splits into hours on both days`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 23, 30)
        try Self.writeSession(env, startedAt: start, lines: [
            Self.turnContext(at: start),
            Self.tokenCount(at: start, input: 100, cached: 20, output: 10),
            Self.tokenCount(at: start.addingTimeInterval(20 * 60), input: 160, cached: 40, output: 16),
            Self.tokenCount(at: start.addingTimeInterval(40 * 60), input: 200, cached: 50, output: 20),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 22, 0))

        #expect(buckets.map(\.hourStart) == [
            try SpendBucketTestEnvironment.utc(2025, 12, 20, 23),
            try SpendBucketTestEnvironment.utc(2025, 12, 21, 0),
        ])
        let late = try #require(buckets.first)
        #expect(late.provider == .codex)
        #expect(late.model == Self.model)
        #expect(late.requests == 2)
        #expect(late.inputTokens == 120)
        #expect(late.cacheReadTokens == 40)
        #expect(late.cacheCreationTokens == nil)
        #expect(late.outputTokens == 16)
        #expect(late.totalTokens == 176)
        let expectedCost = try #require(CostUsagePricing.codexCostUSD(
            model: Self.model,
            inputTokens: 160,
            cachedInputTokens: 40,
            outputTokens: 16))
        #expect(abs((late.costUSD ?? 0) - expectedCost) < 0.000001)

        let early = buckets[1]
        #expect(early.requests == 1)
        #expect(early.inputTokens == 30)
        #expect(early.cacheReadTokens == 10)
        #expect(early.totalTokens == 44)
    }

    @Test
    func `unknown pricing omits cost`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 9, 0)
        try Self.writeSession(env, startedAt: start, lines: [
            Self.turnContext(at: start, model: "fictional-model-x"),
            Self.tokenCount(at: start, input: 100, cached: 20, output: 10),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 21, 0))

        #expect(buckets.count == 1)
        #expect(buckets.first?.costUSD == nil)
        #expect(buckets.first?.totalTokens == 110)
    }

    @Test
    func `appended events keep buckets in step with the daily report`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 10, 0)
        let since = try SpendBucketTestEnvironment.utc(2025, 12, 19, 0)
        let until = try SpendBucketTestEnvironment.utc(2025, 12, 22, 0)
        let url = try Self.writeSession(env, startedAt: start, lines: [
            Self.sessionMeta(at: start),
            Self.turnContext(at: start),
            Self.tokenCount(at: start, input: 100, cached: 20, output: 10),
        ])
        #expect(try Self.load(env, since: since, until: until).first?.requests == 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let line = try JSONSerialization.data(withJSONObject: Self.tokenCount(
            at: start.addingTimeInterval(2 * 3600),
            input: 400,
            cached: 100,
            output: 40))
        try handle.write(contentsOf: line + Data("\n".utf8))
        try handle.close()

        let buckets = try Self.load(env, since: since, until: until)
        #expect(buckets.map(\.requests) == [1, 1])
        #expect(buckets.map(\.hourStart) == [start, start.addingTimeInterval(2 * 3600)])

        let daily = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: Self.options(env))
        #expect(buckets.compactMap(\.totalTokens).reduce(0, +) == daily.summary?.totalTokens)
        let bucketCost = buckets.compactMap(\.costUSD).reduce(0, +)
        #expect(abs(bucketCost - (daily.summary?.totalCostUSD ?? -1)) < 0.000001)
    }

    @Test
    func `a session archived alongside its live copy counts once`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 10, 0)
        let lines = [
            Self.sessionMeta(at: start),
            Self.turnContext(at: start),
            Self.tokenCount(at: start, input: 100, cached: 20, output: 10),
        ]
        try Self.writeSession(env, startedAt: start, lines: lines)
        let archivedRoot = env.codexSessionsRoot.deletingLastPathComponent()
            .appendingPathComponent("archived_sessions", isDirectory: true)
        try env.write(root: archivedRoot, relativePath: "rollout-archived.jsonl", lines: lines)

        let since = try SpendBucketTestEnvironment.utc(2025, 12, 19, 0)
        let until = try SpendBucketTestEnvironment.utc(2025, 12, 22, 0)
        let buckets = try Self.load(env, since: since, until: until)
        let daily = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: Self.options(env))

        #expect(daily.summary?.totalTokens == 110)
        #expect(buckets.map(\.requests) == [1])
        #expect(buckets.first?.totalTokens == 110)
    }

    @Test
    func `each call is priced on its own so a busy hour stays below long-context rates`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        // Three calls of 150k input each: every call is under the long-context threshold, the hour's sum is not.
        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 10, 0)
        try Self.writeSession(env, startedAt: start, lines: [
            Self.sessionMeta(at: start),
            Self.turnContext(at: start),
            Self.tokenCount(at: start, input: 150_000, cached: 0, output: 1000),
            Self.tokenCount(at: start.addingTimeInterval(600), input: 300_000, cached: 0, output: 2000),
            Self.tokenCount(at: start.addingTimeInterval(1200), input: 450_000, cached: 0, output: 3000),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 21, 0))

        let perCall = try #require(CostUsagePricing.codexCostUSD(
            model: Self.model,
            inputTokens: 150_000,
            cachedInputTokens: 0,
            outputTokens: 1000))
        #expect(buckets.first?.requests == 3)
        #expect(abs((buckets.first?.costUSD ?? 0) - 3 * perCall) < 0.000001)
    }
}

