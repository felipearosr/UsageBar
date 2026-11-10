import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// serve's `GET /usage?accounts=all` contract. A stub stands in for the provider fetch, so no test reads a real
/// credential or reaches a provider; the token-account store lives in a temporary config file.
struct CLIServeProviderAccountsTests {
    private static let personalID = UUID(uuidString: "6F0C2A9E-1B4D-4C8A-9E2F-0A1B2C3D4E5F")!
    private static let workID = UUID(uuidString: "0D9E8F7A-6B5C-4D3E-8F1A-2B3C4D5E6F70")!
    private static let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let fetchedAt = Date(timeIntervalSince1970: 1_790_000_600)

    private static func account(_ id: UUID, _ label: String) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: label, token: "fake-\(label)", addedAt: 0, lastUsed: nil)
    }

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

    /// What upstream's fetch appends for one account: a usage row, or that account's error row.
    private static func payload(_ account: ProviderTokenAccount?, usedPercent: Double?) -> ProviderPayload {
        let usage = usedPercent.map {
            UsageSnapshot(
                primary: RateWindow(usedPercent: $0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Self.updatedAt)
        }
        return ProviderPayload(
            provider: .openrouter,
            account: account?.label,
            cacheAccountKey: account.map { "token:\($0.id.uuidString.lowercased())" },
            version: nil,
            source: "api",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: usedPercent == nil
                ? ProviderErrorPayload(code: 1, message: "OpenRouter rejected the key", kind: .provider)
                : nil)
    }

    /// Answers like upstream's fetch for whichever account the context selects; `failing` labels error out.
    private static func stubFetch(
        failing: Set<String> = [],
        calls: CallLog = CallLog()) -> CodexBarCLI.ProviderAccountUsageFetch
    {
        { provider, tokenContext in
            let accounts = (try? tokenContext.resolvedAccounts(for: provider)) ?? []
            await calls.record(tokenContext.selection.usesOverride ? accounts.map(\.label) : ["default"])
            var output = UsageCommandOutput()
            for account in accounts.isEmpty ? [nil] : accounts.map(Optional.some) {
                let fails = account.map { failing.contains($0.label) } ?? false
                output.payload.append(Self.payload(account, usedPercent: fails ? nil : 40))
            }
            return output
        }
    }

    actor CallLog {
        private(set) var calls: [[String]] = []
        func record(_ labels: [String]) {
            self.calls.append(labels)
        }
    }

    private static func serve(
        _ config: CodexBarConfig,
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
                providerDeadline: nil,
                providerOperations: runtime.providerOperations),
            fetch: fetch,
            now: { Self.fetchedAt })
    }

    @Test
    func `two token accounts get one row each with id, label, active and updatedAt`() async throws {
        let config = Self.config(
            [Self.account(Self.personalID, "Personal"), Self.account(Self.workID, "Work")],
            activeIndex: 1)
        let calls = CallLog()
        let response = try await Self.serve(config, fetch: Self.stubFetch(calls: calls))
        #expect(response.status == .ok)
        let rows = try Self.rows(response)
        #expect(rows.count == 2)
        #expect(rows.map { $0["accountId"] as? String } == [
            "token:\(Self.personalID.uuidString.lowercased())",
            "token:\(Self.workID.uuidString.lowercased())",
        ])
        #expect(rows.map { $0["accountSource"] as? String } == ["token", "token"])
        #expect(rows.map { $0["accountLabel"] as? String } == ["Personal", "Work"])
        #expect(rows.map { $0["account"] as? String } == ["Personal", "Work"])
        #expect(rows.map { $0["active"] as? Bool } == [false, true])
        #expect(rows.allSatisfy { $0["updatedAt"] as? String == "2026-09-21T14:13:20Z" })
        #expect(rows.allSatisfy { $0["provider"] as? String == "openrouter" && $0["usage"] != nil })
        // One fetch per account, each selecting only that account's token.
        #expect(await calls.calls == [["Personal"], ["Work"]])
        #expect(response.usageCacheKeys == rows.map { $0["accountId"] as? String })
    }

    @Test
    func `a failing account carries only its own error`() async throws {
        let config = Self.config([Self.account(Self.personalID, "Personal"), Self.account(Self.workID, "Work")])
        let rows = try await Self.rows(Self.serve(config, fetch: Self.stubFetch(failing: ["Personal"])))
        #expect(rows.count == 2)
        let failing = try #require(rows.first { $0["accountLabel"] as? String == "Personal" })
        let healthy = try #require(rows.first { $0["accountLabel"] as? String == "Work" })
        #expect((failing["error"] as? [String: Any])?["message"] as? String == "OpenRouter rejected the key")
        #expect(failing["usage"] == nil)
        // An error row has no snapshot time; it reports when its fetch failed.
        #expect(failing["updatedAt"] as? String == "2026-09-21T14:23:20Z")
        #expect(healthy["error"] == nil)
        let primary = (healthy["usage"] as? [String: Any])?["primary"] as? [String: Any]
        #expect(primary?["usedPercent"] as? Double == 40)
        #expect(failing["active"] as? Bool == true)
        #expect(healthy["active"] as? Bool == false)
    }

    @Test
    func `a provider with one account gets the same row as before`() async throws {
        let only = Self.account(Self.personalID, "Personal")
        let calls = CallLog()
        let response = try await Self.serve(Self.config([only]), fetch: Self.stubFetch(calls: calls))
        // Upstream's default selection, and upstream's bytes for the row it returns.
        #expect(await calls.calls == [["default"]])
        let expected = try #require(CodexBarCLI.encodeJSON([Self.payload(only, usedPercent: 40)], pretty: false))
        #expect(Self.sameJSON(response.body, Data(expected.utf8)))
        #expect(try Self.rows(response).first?["accountId"] == nil)
    }

    @Test
    func `a provider without accounts answers byte for byte like plain usage`() async throws {
        // No key anywhere: both routes run the real fetch, which fails before any request.
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
        let row = Self.payload(Self.account(Self.workID, "Work"), usedPercent: 12)
        let wrapped = try #require(CodexBarCLI.encodeJSON(
            [ProviderAccountRowPayload(row: row, account: nil, updatedAt: Self.updatedAt)],
            pretty: false))
        let bare = try #require(CodexBarCLI.encodeJSON([row], pretty: false))
        #expect(Self.sameJSON(Data(wrapped.utf8), Data(bare.utf8)))
    }

    @Test
    func `blank labels read Account N and codex keeps upstream rows`() throws {
        let accounts = [Self.account(Self.personalID, "  "), Self.account(Self.workID, "Work")]
        let context = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: Self.config(accounts),
            verbose: false,
            baseEnvironment: [:])
        let fields = CodexBarCLI.providerAccounts(for: .openrouter, context: context)
        #expect(fields.map(\.label) == ["Account 1", "Work"])
        #expect(fields.map(\.active) == [true, false])

        let codex = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [ProviderConfig(
                id: UsageProvider.codex.instanceID,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0))]),
            verbose: false,
            baseEnvironment: [:])
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
