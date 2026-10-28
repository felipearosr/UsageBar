import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct ClaudeStatusLineFeedLinuxTests {
    private static let payload = Data("""
    {"session_id":"secret","cwd":"/repo","model":{"display_name":"Opus"},
     "rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1900000000},
                    "seven_day":{"used_percentage":63,"resets_at":1900500000}}}
    """.utf8)

    // MARK: Parser

    @Test
    func `parser keeps only the two windows and stamps the signed-in account`() throws {
        let profile = try Profile(accountUuid: "AAAA-1")
        let limits = try #require(ClaudeStatusLinePayloadParser.parseOfficialPayload(
            Self.payload, capturedAt: Date(timeIntervalSince1970: 1_800_000_000), environment: profile.env))
        #expect(limits.fiveHour == ClaudeStatusLineWindow(
            usedPercent: 42.5, resetsAt: Date(timeIntervalSince1970: 1_900_000_000)))
        #expect(limits.sevenDay?.usedPercent == 63)
        #expect(limits.accountID == ClaudeStatusLineProfile.accountID(environment: profile.env))
        #expect(try limits.accountID != ClaudeStatusLineProfile.accountID(environment: Profile(accountUuid: "B").env))
    }

    @Test
    func `parser refuses a payload when no account is signed in`() throws {
        let signedOut = try Profile(accountUuid: nil)
        #expect(ClaudeStatusLinePayloadParser.parseOfficialPayload(Self.payload, environment: signedOut.env) == nil)
    }

    @Test
    func `parser drops drifted windows without inventing zero usage`() throws {
        let profile = try Profile(accountUuid: "A")
        let drifted = Data(#"{"rate_limits":{"five_hour":{"used_percentage":"42"},"seven_day":{"used_percentage":7}}}"#
            .utf8)
        let limits = try #require(ClaudeStatusLinePayloadParser.parseOfficialPayload(drifted, environment: profile.env))
        #expect(limits.fiveHour == nil)
        #expect(limits.sevenDay == ClaudeStatusLineWindow(usedPercent: 7, resetsAt: nil))
        let empty = Data(#"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#.utf8)
        #expect(ClaudeStatusLinePayloadParser.parseOfficialPayload(empty, environment: profile.env) == nil)
        #expect(ClaudeStatusLinePayloadParser.parseOfficialPayload(Data("{".utf8), environment: profile.env) == nil)
    }

    // MARK: Store

    @Test
    func `store loads only the matching account within the requested age`() throws {
        let profile = try Profile(accountUuid: "A")
        let captured = Date(timeIntervalSince1970: 1_800_000_000)
        let limits = try #require(ClaudeStatusLinePayloadParser.parseOfficialPayload(
            Self.payload, capturedAt: captured, environment: profile.env))
        try ClaudeStatusLineDropStore.write(limits, applicationSupport: profile.support)

        func load(
            account: String?,
            age: TimeInterval,
            after: TimeInterval,
            allowsReset: Bool = true) -> ClaudeStatusLineRateLimits?
        {
            ClaudeStatusLineDropStore.load(
                applicationSupport: profile.support,
                expectedProfileID: limits.profileID,
                expectedAccountID: account ?? limits.accountID,
                maximumAge: age,
                allowsResetWindows: allowsReset,
                now: captured.addingTimeInterval(after))
        }
        #expect(load(account: nil, age: ClaudeStatusLineDropStore.freshnessWindow, after: 60) == limits)
        #expect(load(account: "other", age: ClaudeStatusLineDropStore.freshnessWindow, after: 60) == nil)
        #expect(load(account: nil, age: ClaudeStatusLineDropStore.freshnessWindow, after: 16 * 60) == nil)
        #expect(load(account: nil, age: ClaudeStatusLineDropStore.staleWindow, after: 16 * 60) == limits)
        #expect(load(account: nil, age: ClaudeStatusLineDropStore.staleWindow, after: 7 * 3600) == nil)
        #expect(load(account: nil, age: ClaudeStatusLineDropStore.freshnessWindow, after: -10 * 60) == nil)
        // The payload's five-hour window resets at 1_900_000_000: a stale read drops it, a fresh read refuses the
        // capture.
        let pastReset = 1_900_000_000 - captured.timeIntervalSince1970 + 1
        #expect(load(account: nil, age: .infinity, after: pastReset)?.fiveHour == nil)
        #expect(load(account: nil, age: .infinity, after: pastReset)?.sevenDay != nil)
        #expect(load(account: nil, age: .infinity, after: pastReset, allowsReset: false) == nil)

        let mode = try FileManager.default.attributesOfItem(atPath: ClaudeStatusLineDropStore.observationURL(
            applicationSupport: profile.support, profileID: limits.profileID).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test
    func `windows whose reset has passed are dropped from a loaded observation`() throws {
        let limits = ClaudeStatusLineRateLimits(
            profileID: "p",
            accountID: "a",
            capturedAt: Date(timeIntervalSince1970: 1000),
            fiveHour: .init(usedPercent: 90, resetsAt: Date(timeIntervalSince1970: 2000)),
            sevenDay: .init(usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 9000)))
        let afterFiveHourReset = try #require(ClaudeStatusLineDropStore.droppingResetWindows(
            limits, now: Date(timeIntervalSince1970: 2000)))
        #expect(afterFiveHourReset.fiveHour == nil)
        #expect(afterFiveHourReset.sevenDay?.usedPercent == 40)
        #expect(ClaudeStatusLineDropStore.droppingResetWindows(limits, now: Date(timeIntervalSince1970: 9000)) == nil)
    }

    // MARK: Routing

    @Test
    func `routing is opt-in and skips explicit token accounts and other sources`() {
        #expect(!ClaudeStatusLineFeedRouting.applies(to: Self.context(feed: false, sourceMode: .oauth)))
        #expect(ClaudeStatusLineFeedRouting.applies(to: Self.context(feed: true, sourceMode: .oauth)))
        #expect(ClaudeStatusLineFeedRouting.applies(to: Self.context(feed: true, sourceMode: .auto)))
        #expect(!ClaudeStatusLineFeedRouting.applies(to: Self.context(feed: true, sourceMode: .cli)))
        #expect(!ClaudeStatusLineFeedRouting.applies(to: Self.context(feed: true, sourceMode: .web)))
        #expect(!ClaudeStatusLineFeedRouting.applies(
            to: Self.context(feed: true, sourceMode: .oauth, selectedAccount: UUID())))
    }

    @Test
    func `routing puts the fresh feed first and wraps only the OAuth step`() {
        let strategies: [any ProviderFetchStrategy] = [
            StubStrategy(id: "claude.oauth", outcome: .success),
            StubStrategy(id: "claude.cli", outcome: .success),
        ]
        let routed = ClaudeStatusLineFeedRouting.route(strategies, context: Self.context(feed: true, sourceMode: .auto))
        #expect(routed.map(\.id) == ["claude.statusline", "claude.oauth", "claude.cli"])
        #expect(routed[1] is ClaudeStatusLineRateLimitFallbackStrategy)
        #expect(!(routed[2] is ClaudeStatusLineRateLimitFallbackStrategy))
        let off = ClaudeStatusLineFeedRouting.route(strategies, context: Self.context(feed: false, sourceMode: .auto))
        #expect(off.map(\.id) == ["claude.oauth", "claude.cli"])
    }

    @Test
    func `config opt-in reaches the Claude settings the CLI builds`() throws {
        let data = Data(#"{"id":"claude","source":"oauth","statusLineFeed":true}"#.utf8)
        let config = try JSONDecoder().decode(ProviderConfig.self, from: data)
        let section = ProviderDescriptorRegistry.descriptor(for: .claude).settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil))
        let claude = try #require(section?.section as? ClaudeProviderSettings)
        #expect(claude.statusLineFeedEnabled == true)
        let reencoded = try JSONEncoder().encode(config)
        #expect(try #require(String(bytes: reencoded, encoding: .utf8)).contains("statusLineFeed"))
    }

    // MARK: Pipeline behavior

    @Test
    func `a fresh observation answers without touching OAuth`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .rateLimited)
        let outcome = await Self.run([oauth], fresh: true, stale: true)
        #expect(Self.sourceLabel(outcome) == ClaudeStatusLineFeed.sourceLabel)
        #expect(oauth.calls.value == 0)
    }

    @Test
    func `a rate-limited OAuth falls back to the stale observation`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .rateLimited)
        let outcome = await Self.run([oauth], fresh: false, stale: true)
        #expect(Self.sourceLabel(outcome) == ClaudeStatusLineFeed.staleSourceLabel)
        #expect(oauth.calls.value == 1)
    }

    @Test
    func `without any observation the OAuth rate limit is still what surfaces`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .rateLimited)
        let outcome = await Self.run([oauth], fresh: false, stale: false)
        guard case let .failure(error) = outcome.result else {
            Issue.record("expected failure")
            return
        }
        #expect(ClaudeUsageError.isClaudeOAuthUsageRateLimit(error))
    }

    @Test
    func `a rate-limited OAuth without a stale capture keeps today's fallback decision`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .rateLimited)
        let cli = StubStrategy(id: "claude.cli", outcome: .success)
        _ = await Self.run([oauth, cli], fresh: false, stale: false)
        #expect(cli.calls.value == 0)
    }

    @Test
    func `the stale capture never answers for a failure other than a rate limit`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .unauthorized, fallsBack: true)
        let cli = StubStrategy(id: "claude.cli", outcome: .success)
        let outcome = await Self.run([oauth, cli], fresh: false, stale: true)
        #expect(Self.sourceLabel(outcome) == "claude.cli")
        #expect(cli.calls.value == 1)
    }

    @Test
    func `a non rate-limit OAuth failure on explicit OAuth does not fall back`() async {
        let oauth = StubStrategy(id: "claude.oauth", outcome: .unauthorized)
        let outcome = await Self.run([oauth], fresh: false, stale: true)
        guard case .failure = outcome.result else {
            Issue.record("expected failure, got \(Self.sourceLabel(outcome) ?? "nil")")
            return
        }
    }

    // MARK: CLI

    @Test
    func `capture writes an observation and prints nothing`() throws {
        let profile = try Profile(accountUuid: "A")
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Self.payload)
        try pipe.fileHandleForWriting.close()
        CodexBarCLI.runClaudeStatusLineCapture(
            input: pipe.fileHandleForReading,
            environment: profile.env,
            applicationSupport: profile.support,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let url = ClaudeStatusLineDropStore.observationURL(
            applicationSupport: profile.support,
            profileID: ClaudeStatusLineProfile.identifier(environment: profile.env))
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(stored.contains("accountID"))
        #expect(!stored.contains("secret"))
        #expect(!stored.contains("/repo"))
    }

    // MARK: Helpers

    private struct Profile {
        let root: URL
        let support: URL
        let env: [String: String]

        init(accountUuid: String?) throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("statusline-\(UUID().uuidString)", isDirectory: true)
            self.support = self.root.appendingPathComponent("support", isDirectory: true)
            let configDir = self.root.appendingPathComponent("claude", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let account = accountUuid.map { #"{"oauthAccount":{"accountUuid":"\#($0)"}}"# } ?? "{}"
            try Data(account.utf8).write(to: configDir.appendingPathComponent(".claude.json"))
            self.env = ["CLAUDE_CONFIG_DIR": configDir.path, "HOME": self.root.path]
        }
    }

    private static func context(
        feed: Bool,
        sourceMode: ProviderSourceMode,
        selectedAccount: UUID? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 5,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: .make(claude: .init(
                usageDataSource: .oauth,
                webExtrasEnabled: false,
                cookieSource: .off,
                manualCookieHeader: nil,
                statusLineFeedEnabled: feed)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: [:]),
            browserDetection: browserDetection,
            selectedTokenAccountID: selectedAccount)
    }

    private static func run(_ strategies: [any ProviderFetchStrategy], fresh: Bool, stale: Bool) async
        -> ProviderFetchOutcome
    {
        let observation = ClaudeStatusLineRateLimits(
            profileID: "p",
            accountID: "a",
            capturedAt: Date(),
            fiveHour: .init(usedPercent: 12, resetsAt: nil),
            sevenDay: nil)
        let context = Self.context(feed: true, sourceMode: .oauth)
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { context in ClaudeStatusLineFeedRouting.route(strategies, context: context) },
            retrySleeper: { _ in })
        let loader: ClaudeStatusLineFetchStrategy.ObservationLoader = { _, mode in
            (mode == .fresh ? fresh : stale) ? observation : nil
        }
        return await ClaudeStatusLineFetchStrategy.$observationLoaderOverrideForTesting.withValue(loader) {
            await pipeline.fetch(context: context, provider: .claude)
        }
    }

    private static func sourceLabel(_ outcome: ProviderFetchOutcome) -> String? {
        guard case let .success(result) = outcome.result else { return nil }
        return result.sourceLabel
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

private struct StubStrategy: ProviderFetchStrategy {
    enum Outcome { case success, rateLimited, unauthorized }

    let id: String
    let outcome: Outcome
    var fallsBack = false
    let kind: ProviderFetchKind = .oauth
    let calls = Counter()

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        self.calls.increment()
        switch self.outcome {
        case .success:
            return self.makeResult(
                usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
                sourceLabel: self.id)
        case .rateLimited:
            throw ClaudeUsageError.oauthFailed(ClaudeOAuthFetchError.rateLimited(retryAfter: nil).localizedDescription)
        case .unauthorized:
            throw ClaudeOAuthFetchError.unauthorized
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        self.fallsBack
    }
}
