@testable import CodexBarCore
import Foundation
import Testing

@Suite
struct PiSpendBucketLinuxTests {
    private static func assistant(
        at date: Date,
        provider: String = "anthropic",
        model: String = "claude-sonnet-4-6",
        usage: [String: Any] = ["input": 80, "output": 20, "cacheRead": 4, "cacheWrite": 6, "totalTokens": 110])
        -> [String: Any]
    {
        [
            "type": "message",
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

    private static func options(_ env: SpendBucketTestEnvironment) -> PiSessionCostScanner.Options {
        PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
    }

    private static func load(
        _ env: SpendBucketTestEnvironment,
        provider: UsageProvider,
        since: Date,
        until: Date) throws -> [CostUsageSpendBucket]
    {
        try PiSessionCostScanner.loadSpendBuckets(
            provider: provider,
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

        let late = try SpendBucketTestEnvironment.utc(2026, 4, 2, 23, 40)
        let early = try SpendBucketTestEnvironment.utc(2026, 4, 3, 0, 5)
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T23-00-00-000Z_s.jsonl", lines: [
            Self.assistant(at: late),
            Self.assistant(at: late.addingTimeInterval(60)),
            Self.assistant(at: early),
        ])

        let buckets = try Self.load(
            env,
            provider: .claude,
            since: SpendBucketTestEnvironment.utc(2026, 4, 2, 0),
            until: SpendBucketTestEnvironment.utc(2026, 4, 4, 0))

        #expect(buckets.map(\.hourStart) == [
            try SpendBucketTestEnvironment.utc(2026, 4, 2, 23),
            try SpendBucketTestEnvironment.utc(2026, 4, 3, 0),
        ])
        let first = try #require(buckets.first)
        #expect(first.provider == .claude)
        #expect(first.model == "claude-sonnet-4-6")
        #expect(first.requests == 2)
        #expect(first.inputTokens == 160)
        #expect(first.outputTokens == 40)
        #expect(first.cacheReadTokens == 8)
        #expect(first.cacheCreationTokens == 12)
        #expect(first.totalTokens == 220)
        let expectedCost = try #require(CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 80,
            cacheReadInputTokens: 4,
            cacheCreationInputTokens: 6,
            outputTokens: 20))
        #expect(abs((first.costUSD ?? 0) - 2 * expectedCost) < 0.000001)
        #expect(buckets[1].requests == 1)
    }

    @Test
    func `fields the log omits stay absent`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 10, 0)
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-00-00-000Z_s.jsonl", lines: [
            Self.assistant(at: at, usage: ["input": 50, "output": 5]),
        ])

        let buckets = try Self.load(
            env,
            provider: .claude,
            since: SpendBucketTestEnvironment.utc(2026, 4, 2, 0),
            until: SpendBucketTestEnvironment.utc(2026, 4, 3, 0))

        let bucket = try #require(buckets.first)
        #expect(bucket.inputTokens == 50)
        #expect(bucket.outputTokens == 5)
        #expect(bucket.cacheReadTokens == nil)
        #expect(bucket.cacheCreationTokens == nil)
        #expect(bucket.totalTokens == 55)
    }

    @Test
    func `unknown pricing omits cost`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 10, 0)
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-00-00-000Z_s.jsonl", lines: [
            Self.assistant(at: at, model: "claude-fictional-model-x"),
        ])

        let buckets = try Self.load(
            env,
            provider: .claude,
            since: SpendBucketTestEnvironment.utc(2026, 4, 2, 0),
            until: SpendBucketTestEnvironment.utc(2026, 4, 3, 0))

        #expect(buckets.count == 1)
        #expect(buckets.first?.costUSD == nil)
        #expect(buckets.first?.totalTokens == 110)
    }

    @Test
    func `appended lines are picked up incrementally`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 10, 0)
        let since = try SpendBucketTestEnvironment.utc(2026, 4, 2, 0)
        let until = try SpendBucketTestEnvironment.utc(2026, 4, 3, 0)
        let url = try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-00-00-000Z_s.jsonl", lines: [
            Self.assistant(at: at),
        ])
        #expect(try Self.load(env, provider: .claude, since: since, until: until).first?.requests == 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let line = try JSONSerialization.data(withJSONObject: Self.assistant(at: at.addingTimeInterval(120)))
        try handle.write(contentsOf: line + Data("\n".utf8))
        try handle.close()

        #expect(try Self.load(env, provider: .claude, since: since, until: until).first?.requests == 2)
    }

    @Test
    func `buckets match the daily report totals`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 12, 0)
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T12-00-00-000Z_s.jsonl", lines: [
            Self.assistant(at: at),
            Self.assistant(at: at.addingTimeInterval(3600)),
            Self.assistant(
                at: at,
                provider: "openai-codex",
                model: "openai/gpt-5.4",
                usage: ["input": 120, "output": 30, "cacheRead": 10, "totalTokens": 160]),
        ])

        let since = try SpendBucketTestEnvironment.utc(2026, 4, 1, 0)
        let until = try SpendBucketTestEnvironment.utc(2026, 4, 4, 0)
        for provider in [UsageProvider.claude, .codex] {
            let buckets = try Self.load(env, provider: provider, since: since, until: until)
            let daily = PiSessionCostScanner.loadDailyReport(
                provider: provider,
                since: since,
                until: until,
                now: until,
                options: Self.options(env))
            #expect(buckets.allSatisfy { $0.provider == provider })
            #expect(buckets.compactMap(\.totalTokens).reduce(0, +) == daily.summary?.totalTokens)
            let bucketCost = buckets.compactMap(\.costUSD).reduce(0, +)
            #expect(abs(bucketCost - (daily.summary?.totalCostUSD ?? -1)) < 0.000001)
        }
    }
}
