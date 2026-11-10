import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// serve's `GET /usage?accounts=all` contract. A stub stands in for the provider fetch, so no test reads a real
/// credential or reaches a provider; the token-account store lives in a temporary config file.
struct CLIServeProviderAccountsTests {
    private static let personalID = UUID(uuidString: "6F0C2A9E-1B4D-4C8A-9E2F-0A1B2C3D4E5F")!
    private static let workID = UUID(uuidString: "0D9E8F7A-6B5C-4D3E-8F1A-2B3C4D5E6F70")!
    private static let personalAccountID = "token:6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f"
    private static let workAccountID = "token:0d9e8f7a-6b5c-4d3e-8f1a-2b3c4d5e6f70"
    private static let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private static func account(_ id: UUID, _ label: String) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: label, token: "fake-\(label)", addedAt: 0, lastUsed: nil)
    }

    private static let twoAccounts = [account(personalID, "Personal"), account(workID, "Work")]

    private static func config(_ accounts: [ProviderTokenAccount], activeIndex: Int = 0) -> CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.openrouter.instanceID,
            enabled: true,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: activeIndex))])
    }

    private static func runtime(
        config: CodexBarConfig? = nil,
        bindHost: String = "127.0.0.1",
        token: String? = nil) throws -> ServeRuntime
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeProviderAccountsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        if let config { try store.save(config) }
        return ServeRuntime(
            configStore: store,
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: nil,
            dashboardAuth: CLIServeDashboardAuth(bearer: token),
            bindHost: bindHost)
    }

    private static func request(_ target: String, method: String = "GET") throws -> CLILocalHTTPRequest {
        let raw = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    private static func rows(_ response: CLILocalHTTPResponse) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }

    /// Same JSON value. Byte order can't be compared: upstream's unsorted JSONEncoder doesn't fix key order on
    /// Linux, so two encodes of one payload may differ in bytes.
    private static func sameJSON(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let lhs = try? JSONSerialization.jsonObject(with: lhs) as? NSArray,
              let rhs = try? JSONSerialization.jsonObject(with: rhs) as? NSArray
        else { return false }
        return lhs.isEqual(rhs)
    }

    /// A row like upstream's fetch returns: usage, or an error when `usedPercent` is nil.
    private static func payload(
        label: String?,
        cacheAccountKey: String?,
        usedPercent: Double?,
        error: String = "OpenRouter rejected the key") -> ProviderPayload
    {
        let usage = usedPercent.map {
            UsageSnapshot(
                primary: RateWindow(usedPercent: $0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Self.updatedAt)
        }
        return ProviderPayload(
            provider: .openrouter,
            account: label,
            cacheAccountKey: cacheAccountKey,
            version: nil,
            source: "api",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: usedPercent == nil ? ProviderErrorPayload(code: 1, message: error, kind: .provider) : nil)
    }

    /// Answers for whichever account the selector names, with a cache key unrelated to any account id (serve must
    /// tag rows itself). `failing` labels error out; `hang` makes every account fetch outlast the budget.
    private static func stubFetch(
        _ accounts: [ProviderTokenAccount],
        failing: Set<String> = [],
        hang: Bool = false,
        calls: CallLog = CallLog()) -> CodexBarCLI.ProviderAccountUsageFetch
    {
        { _, selector in
            var output = UsageCommandOutput()
            switch selector {
            case nil:
                await calls.record("default")
                let only = accounts.first
                output.payload.append(Self.payload(
                    label: only?.label,
                    cacheAccountKey: only.map { "upstream-\($0.label)" },
                    usedPercent: 40))
            case let .tokenIndex(index):
                let account = accounts[index]
                await calls.record(account.label)
                if hang { try? await Task.sleep(for: .seconds(3)) }
                output.payload.append(Self.payload(
                    label: account.label,
                    cacheAccountKey: "upstream-\(index)",
                    usedPercent: failing.contains(account.label) ? nil : 40))
            case .codexAccount:
                Issue.record("a token-account provider was fetched as a Codex account")
            }
            return output
        }
    }

    actor CallLog {
        private(set) var calls: [String] = []
        func record(_ label: String) {
            self.calls.append(label)
        }
    }

    private static func serve(
        _ config: CodexBarConfig,
        deadline: ContinuousClock.Instant? = nil,
        operations: CLIServeOperationCoordinator<UsageCommandOutput> = CLIServeOperationCoordinator(),
        fetch: @escaping CodexBarCLI.ProviderAccountUsageFetch) async throws -> CLILocalHTTPResponse
    {
        let runtime = try Self.runtime(config: config)
        let snapshot = try CodexBarCLI.loadServeConfigSnapshot(configStore: runtime.configStore)
        return await CodexBarCLI.serveProviderAccountUsage(
            provider: "openrouter",
            context: ServeUsageContext(
                config: snapshot.config,
                configFingerprint: snapshot.cacheToken,
                refreshInterval: 60,
                providerTimeout: nil,
                providerDeadline: deadline,
                providerOperations: operations),
            fetch: fetch)
    }

    @Test
    func `two token accounts get one row each with id, label, active and updatedAt`() async throws {
        let calls = CallLog()
        let response = try await Self.serve(
            Self.config(Self.twoAccounts, activeIndex: 1),
            fetch: Self.stubFetch(Self.twoAccounts, calls: calls))
        #expect(response.status == .ok)
        let rows = try Self.rows(response)
        #expect(rows.map { $0["accountId"] as? String } == [Self.personalAccountID, Self.workAccountID])
        #expect(rows.map { $0["accountSource"] as? String } == ["token", "token"])
        #expect(rows.map { $0["accountLabel"] as? String } == ["Personal", "Work"])
        #expect(rows.map { $0["account"] as? String } == ["Personal", "Work"])
        #expect(rows.map { $0["active"] as? Bool } == [false, true])
        #expect(rows.allSatisfy { $0["updatedAt"] as? String == "2026-09-21T14:13:20Z" })
        #expect(rows.allSatisfy { $0["provider"] as? String == "openrouter" && $0["usage"] != nil })
        // One fetch per account, each selecting only that account.
        #expect(await calls.calls == ["Personal", "Work"])
        // Serve's own tag is the cache key, whatever key the fetch gave the row.
        #expect(response.usageCacheKeys == [Self.personalAccountID, Self.workAccountID])
    }

    @Test
    func `a failing account carries only its own error and no updatedAt`() async throws {
        let rows = try await Self.rows(Self.serve(
            Self.config(Self.twoAccounts),
            fetch: Self.stubFetch(Self.twoAccounts, failing: ["Personal"])))
        #expect(rows.count == 2)
        let failing = try #require(rows.first { $0["accountLabel"] as? String == "Personal" })
        let healthy = try #require(rows.first { $0["accountLabel"] as? String == "Work" })
        #expect((failing["error"] as? [String: Any])?["message"] as? String == "OpenRouter rejected the key")
        #expect(failing["usage"] == nil)
        // updatedAt is the time of the Quota shown; an error row shows none.
        #expect(failing["updatedAt"] == nil)
        #expect(healthy["updatedAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(healthy["error"] == nil)
        let primary = (healthy["usage"] as? [String: Any])?["primary"] as? [String: Any]
        #expect(primary?["usedPercent"] as? Double == 40)
        #expect(failing["active"] as? Bool == true)
        #expect(healthy["active"] as? Bool == false)
    }

    @Test
    func `a timed out provider gets an error row per account that the last good merge restores`() async throws {
        let config = Self.config(Self.twoAccounts, activeIndex: 1)
        let cache = CLIServeResponseCache()
        let key = "usage:openrouter:accounts"
        let policy = CLIServeResponseCache.CachePolicy(ttl: 60, staleTTL: 600)
        let good = try await Self.serve(config, fetch: Self.stubFetch(Self.twoAccounts))
        _ = await cache.completeFetch(good, for: key, policy: policy, now: Date(), shouldCache: true)

        let timedOut = try await Self.serve(
            config,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(200)),
            fetch: Self.stubFetch(Self.twoAccounts, hang: true))
        let rows = try Self.rows(timedOut)
        // The coordinator's one untagged timeout row became one row per account, tagged and still multi-account.
        #expect(rows.map { $0["accountId"] as? String } == [Self.personalAccountID, Self.workAccountID])
        #expect(rows.map { $0["accountLabel"] as? String } == ["Personal", "Work"])
        #expect(rows.map { $0["active"] as? Bool } == [false, true])
        #expect(rows.allSatisfy { $0["error"] != nil && $0["updatedAt"] == nil })
        #expect(timedOut.usageCacheKeys == [Self.personalAccountID, Self.workAccountID])
        #expect(!CodexBarCLI.shouldCacheServeResponse(timedOut))

        let delivered = await cache.completeFetch(
            timedOut,
            for: key,
            policy: policy,
            now: Date(),
            shouldCache: false)
        let restored = try Self.rows(delivered)
        #expect(restored.map { $0["accountId"] as? String } == [Self.personalAccountID, Self.workAccountID])
        #expect(restored.allSatisfy { $0["error"] == nil && $0["usage"] != nil })
        #expect(restored.allSatisfy { $0["updatedAt"] as? String == "2026-09-21T14:13:20Z" })
    }

    @Test
    func `tagging is all or nothing for a provider with accounts`() {
        let accounts = [
            ProviderAccount(
                fields: ProviderAccountRowFields(source: .token, id: "a", label: "A", active: true),
                selector: .tokenIndex(0)),
            ProviderAccount(
                fields: ProviderAccountRowFields(source: .token, id: "b", label: "B", active: false),
                selector: .tokenIndex(1)),
        ]
        let rows = CodexBarCLI.providerAccountRows(
            [
                Self.payload(label: "A", cacheAccountKey: "token:a", usedPercent: 10),
                Self.payload(label: nil, cacheAccountKey: nil, usedPercent: nil, error: "timed out"),
                Self.payload(label: nil, cacheAccountKey: nil, usedPercent: 99),
            ],
            accountsByProvider: [.openrouter: accounts])
        #expect(rows.map(\.account?.accountID) == ["token:a", "token:b"])
        #expect(rows.map(\.row.cacheAccountKey) == ["token:a", "token:b"])
        #expect(rows[1].row.error?.message == "timed out")
        #expect(rows[1].row.account == "B")

        // A provider without accounts keeps its rows untouched and untagged.
        let plain = CodexBarCLI.providerAccountRows(
            [Self.payload(label: nil, cacheAccountKey: nil, usedPercent: nil)],
            accountsByProvider: [.openrouter: []])
        #expect(plain.map(\.account) == [nil])
    }

    @Test
    func `a provider with one account gets the same row as before`() async throws {
        let only = Self.account(Self.personalID, "Personal")
        let calls = CallLog()
        let response = try await Self.serve(Self.config([only]), fetch: Self.stubFetch([only], calls: calls))
        // Upstream's default selection, and upstream's row for it unchanged.
        #expect(await calls.calls == ["default"])
        let expected = try #require(CodexBarCLI.encodeJSON(
            [Self.payload(label: "Personal", cacheAccountKey: "upstream-Personal", usedPercent: 40)],
            pretty: false))
        #expect(Self.sameJSON(response.body, Data(expected.utf8)))
        #expect(try Self.rows(response).first?["accountId"] == nil)
        #expect(response.usageCacheKeys == ["upstream-Personal"])
    }

    @Test
    func `a provider without accounts answers like plain usage`() async throws {
        // No key anywhere: both routes run the real fetch, which fails before any request. This stays offline only
        // because Scripts/test_environment.sh unsets OPENROUTER_API_KEY (and every other provider key).
        let runtime = try Self.runtime(config: CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.openrouter.instanceID,
            enabled: true)]))
        let plain = try await CodexBarCLI.handleServeRequest(
            Self.request("/usage?provider=openrouter"),
            runtime: runtime)
        let accounts = try await CodexBarCLI.handleServeRequest(
            Self.request("/usage?provider=openrouter&accounts=all"),
            runtime: runtime)
        #expect(plain.status == .ok)
        #expect(accounts.status == plain.status)
        #expect(Self.sameJSON(accounts.body, plain.body))
        #expect(try Self.rows(plain).first?["error"] != nil)
        #expect(accounts.extraHeaders.map(\.0) == plain.extraHeaders.map(\.0))
    }

    @Test
    func `encoding without an account is the bare upstream row`() throws {
        let row = Self.payload(label: "Work", cacheAccountKey: nil, usedPercent: 12)
        let wrapped = try #require(CodexBarCLI.encodeJSON(
            [ProviderAccountRowPayload(row: row, account: nil)],
            pretty: false))
        let bare = try #require(CodexBarCLI.encodeJSON([row], pretty: false))
        #expect(Self.sameJSON(Data(wrapped.utf8), Data(bare.utf8)))
    }

    @Test
    func `blank labels read Account N and codex ignores token accounts`() throws {
        let accounts = [Self.account(Self.personalID, "  "), Self.account(Self.workID, "Work")]
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: Self.config(accounts),
            verbose: false,
            baseEnvironment: [:])
        let found = CodexBarCLI.providerAccounts(for: .openrouter, context: context)
        #expect(found.map(\.fields.label) == ["Account 1", "Work"])
        #expect(found.map(\.fields.active) == [true, false])
        #expect(found.map(\.selector) == [.tokenIndex(0), .tokenIndex(1)])

        // Codex's accounts are its managed homes (#168), never its token accounts; with none it keeps upstream's rows.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeProviderAccountsTests-\(UUID().uuidString)", isDirectory: true)
        let codex = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [ProviderConfig(
                id: UsageProvider.codex.instanceID,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0))]),
            verbose: false,
            baseEnvironment: ["HOME": empty.path, "CODEX_HOME": empty.appendingPathComponent(".codex").path],
            managedCodexAccountStoreURL: empty.appendingPathComponent("managed-codex-accounts.json"))
        #expect(CodexBarCLI.providerAccounts(for: .codex, context: codex).isEmpty)
    }

    @Test
    func `only accounts all reaches the fork and plain usage passes through`() async throws {
        let runtime = try Self.runtime(bindHost: "0.0.0.0", token: "secret")
        for target in ["/usage", "/usage?provider=openrouter", "/usage?accounts=one", "/usage?fresh=1"] {
            #expect(try await CodexBarCLI.forkServeResponse(Self.request(target), runtime: runtime) == nil)
        }
        #expect(try await CodexBarCLI.forkServeResponse(
            Self.request("/usage?accounts=all", method: "POST"),
            runtime: runtime) == nil)
        // Same bearer rule as upstream's /usage on a non-loopback bind, checked before any fetch.
        let response = try await CodexBarCLI.forkServeResponse(Self.request("/usage?accounts=all"), runtime: runtime)
        #expect(response?.status == .unauthorized)
        #expect(response?.extraHeaders.contains { $0 == ("Cache-Control", "no-store") } == true)
    }

    @Test
    func `health advertises provider account rows`() async throws {
        let response = try await CodexBarCLI.handleServeRequest(Self.request("/health"), runtime: Self.runtime())
        let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect((object["capabilities"] as? [String])?.contains("providerAccountRows") == true)
    }
}
