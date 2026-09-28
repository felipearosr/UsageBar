import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct SpendBucketMergeLinuxTests {
    private static func bucket(
        hour: Int,
        model: String = "m",
        cost: Double?,
        input: Int?,
        cacheCreation: Int?,
        requests: Int?) throws -> CostUsageSpendBucket
    {
        try CostUsageSpendBucket(
            hourStart: SpendBucketTestEnvironment.utc(2026, 4, 2, hour),
            provider: .codex,
            model: model,
            costUSD: cost,
            inputTokens: input,
            outputTokens: nil,
            cacheReadTokens: nil,
            cacheCreationTokens: cacheCreation,
            totalTokens: input,
            requests: requests)
    }

    @Test
    func `equal hour and model merge while reported fields add up`() throws {
        let merged = try CostUsageSpendBucket.merged(
            [Self.bucket(hour: 10, cost: 1.5, input: 100, cacheCreation: nil, requests: 2)],
            [Self.bucket(hour: 10, cost: 0.5, input: 50, cacheCreation: 7, requests: 1)])

        #expect(merged.count == 1)
        #expect(merged.first?.costUSD == 2.0)
        #expect(merged.first?.inputTokens == 150)
        #expect(merged.first?.cacheCreationTokens == 7)
        #expect(merged.first?.outputTokens == nil)
        #expect(merged.first?.requests == 3)
    }

    @Test
    func `unknown pricing on either side makes the merged cost unknown`() throws {
        let merged = try CostUsageSpendBucket.merged(
            [Self.bucket(hour: 10, cost: 1.5, input: 100, cacheCreation: nil, requests: 1)],
            [Self.bucket(hour: 10, cost: nil, input: 50, cacheCreation: nil, requests: 1)])

        #expect(merged.first?.costUSD == nil)
        #expect(merged.first?.inputTokens == 150)
    }

    @Test
    func `different hours or models stay separate and sort by hour then model`() throws {
        let merged = try CostUsageSpendBucket.merged(
            [Self.bucket(hour: 11, model: "a", cost: 1, input: 1, cacheCreation: nil, requests: 1)],
            [
                Self.bucket(hour: 10, model: "b", cost: 1, input: 1, cacheCreation: nil, requests: 1),
                Self.bucket(hour: 10, model: "a", cost: 1, input: 1, cacheCreation: nil, requests: 1),
            ])

        #expect(merged.map(\.model) == ["a", "b", "a"])
        #expect(try merged.map(\.hourStart) == [
            SpendBucketTestEnvironment.utc(2026, 4, 2, 10),
            SpendBucketTestEnvironment.utc(2026, 4, 2, 10),
            SpendBucketTestEnvironment.utc(2026, 4, 2, 11),
        ])
    }

    @Test
    func `local-log loader merges Pi sessions into the provider's own buckets`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2026, 4, 2, 10, 15)
        try env.write(root: env.claudeProjectsRoot, relativePath: "project/session.jsonl", lines: [[
            "type": "assistant",
            "timestamp": SpendBucketTestEnvironment.iso(at),
            "requestId": "req_1",
            "message": [
                "id": "msg_1",
                "model": "claude-sonnet-4-6",
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]])
        try env.write(root: env.piSessionsRoot, relativePath: "run/2026-04-02T10-00-00-000Z_s.jsonl", lines: [[
            "type": "message",
            "timestamp": SpendBucketTestEnvironment.iso(at),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "usage": ["input": 20, "output": 4, "totalTokens": 24],
            ],
        ]])

        var scannerOptions = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        scannerOptions.refreshMinIntervalSeconds = 0
        let buckets = try CostUsageSpendBucket.loadLocalLogBuckets(
            provider: .claude,
            since: SpendBucketTestEnvironment.utc(2026, 4, 2, 0),
            until: SpendBucketTestEnvironment.utc(2026, 4, 3, 0),
            now: SpendBucketTestEnvironment.utc(2026, 4, 3, 0),
            scannerOptions: scannerOptions,
            piOptions: PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, refreshMinIntervalSeconds: 0))

        #expect(buckets.count == 1)
        #expect(buckets.first?.requests == 2)
        #expect(buckets.first?.inputTokens == 30)
        #expect(buckets.first?.outputTokens == 9)
        #expect(buckets.first?.totalTokens == 39)
    }
}
