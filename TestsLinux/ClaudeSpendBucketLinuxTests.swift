import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ClaudeSpendBucketLinuxTests {
    private static let pricedModel = "claude-sonnet-4-20250514"

    private static func assistant(
        at date: Date,
        model: String = Self.pricedModel,
        messageId: String,
        input: Int = 100,
        cacheCreate: Int = 50,
        cacheRead: Int = 25,
        output: Int = 10) -> [String: Any]
    {
        [
            "type": "assistant",
            "timestamp": SpendBucketTestEnvironment.iso(date),
            "requestId": "req_\(messageId)",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": cacheCreate,
                    "cache_read_input_tokens": cacheRead,
                    "output_tokens": output,
                ],
            ],
        ]
    }

    private static func load(
        _ env: SpendBucketTestEnvironment,
        since: Date,
        until: Date) throws -> [CostUsageSpendBucket]
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        return try CostUsageScanner.loadSpendBuckets(
            provider: .claude,
            since: since,
            until: until,
            now: until,
            options: options,
            checkCancellation: nil)
    }

    @Test
    func `session crossing UTC midnight splits into hours on both days`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let beforeMidnight = try SpendBucketTestEnvironment.utc(2025, 12, 20, 23, 30)
        let alsoBeforeMidnight = try SpendBucketTestEnvironment.utc(2025, 12, 20, 23, 50)
        let afterMidnight = try SpendBucketTestEnvironment.utc(2025, 12, 21, 0, 15)
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [
            Self.assistant(at: beforeMidnight, messageId: "msg_1"),
            Self.assistant(at: alsoBeforeMidnight, messageId: "msg_2", input: 1, output: 2),
            Self.assistant(at: afterMidnight, messageId: "msg_3"),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 22, 0))

        #expect(try buckets.map(\.hourStart) == [
            SpendBucketTestEnvironment.utc(2025, 12, 20, 23),
            SpendBucketTestEnvironment.utc(2025, 12, 21, 0),
        ])
        let late = try #require(buckets.first)
        #expect(late.provider == .claude)
        #expect(late.model == Self.pricedModel)
        #expect(late.requests == 2)
        #expect(late.inputTokens == 101)
        #expect(late.outputTokens == 12)
        #expect(late.cacheReadTokens == 50)
        #expect(late.cacheCreationTokens == 100)
        #expect(late.totalTokens == 263)
        #expect((late.costUSD ?? 0) > 0)
        #expect(buckets[1].requests == 1)
    }

    @Test
    func `streaming chunks of one message count once`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 14, 0)
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [
            Self.assistant(at: start, messageId: "msg_1"),
            Self.assistant(at: start.addingTimeInterval(1), messageId: "msg_1"),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 21, 0))

        #expect(buckets.count == 1)
        #expect(buckets.first?.requests == 1)
        #expect(buckets.first?.totalTokens == 185)
    }

    @Test
    func `unknown pricing omits cost but keeps tokens`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let start = try SpendBucketTestEnvironment.utc(2025, 12, 20, 9, 0)
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [
            Self.assistant(at: start, model: "claude-fictional-model-x", messageId: "msg_1"),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 21, 0))

        #expect(buckets.count == 1)
        #expect(buckets.first?.costUSD == nil)
        #expect(buckets.first?.totalTokens == 185)
    }

    @Test
    func `buckets outside the requested window are dropped`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [
            Self.assistant(at: SpendBucketTestEnvironment.utc(2025, 12, 20, 9, 30), messageId: "msg_1"),
            Self.assistant(at: SpendBucketTestEnvironment.utc(2025, 12, 20, 10, 30), messageId: "msg_2"),
        ])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 10),
            until: SpendBucketTestEnvironment.utc(2025, 12, 20, 11))

        #expect(try buckets.map(\.hourStart) == [SpendBucketTestEnvironment.utc(2025, 12, 20, 10)])
    }

    @Test
    func `fields the log omits stay absent`() throws {
        let env = try SpendBucketTestEnvironment()
        defer { env.cleanup() }

        let at = try SpendBucketTestEnvironment.utc(2025, 12, 20, 9, 0)
        try env.write(root: env.claudeProjectsRoot, relativePath: "project-a/session.jsonl", lines: [[
            "type": "assistant",
            "timestamp": SpendBucketTestEnvironment.iso(at),
            "requestId": "req_1",
            "message": [
                "id": "msg_1",
                "model": Self.pricedModel,
                "usage": ["input_tokens": 40, "output_tokens": 8, "cache_read_input_tokens": NSNull()],
            ],
        ]])

        let buckets = try Self.load(
            env,
            since: SpendBucketTestEnvironment.utc(2025, 12, 20, 0),
            until: SpendBucketTestEnvironment.utc(2025, 12, 21, 0))

        let bucket = try #require(buckets.first)
        #expect(bucket.inputTokens == 40)
        #expect(bucket.outputTokens == 8)
        #expect(bucket.cacheReadTokens == nil)
        #expect(bucket.cacheCreationTokens == nil)
        #expect(bucket.totalTokens == 48)
    }
}
