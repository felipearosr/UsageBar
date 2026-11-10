#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Managed Codex accounts as Provider Account rows on serve's `GET /usage?accounts=all` (#168). The account list is
/// upstream's real reconciliation over a synthetic managed-account store and synthetic Codex homes; a stub stands in
/// for the usage fetch. Every token is a fake string, and every credential read is confined to the fixture's root.
@Suite(.serialized)
struct CLIServeCodexAccountsTests {
    private static let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Rows

    @Test
    func `a managed account and a different everyday login get one row each, the everyday login active`() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")
        let managed = try fixture.addAccount(email: "other@example.com", accountID: "acct-other")

        let calls = CallLog()
        let response = try await Self.serve(fixture, fetch: Self.stubFetch(calls: calls))
        #expect(response.status == .ok)
        let rows = try Self.rows(response)
        #expect(rows.count == 2)
        #expect(rows.map { $0["provider"] as? String } == ["codex", "codex"])
        #expect(rows.map { $0["accountSource"] as? String } == ["codex-managed", "codex-system"])
        #expect(rows.map { $0["accountLabel"] as? String } == ["other@example.com", "system@example.com"])
        #expect(rows.map { $0["active"] as? Bool } == [false, true])
        #expect(rows.allSatisfy { $0["updatedAt"] as? String == "2026-09-21T14:13:20Z" })
        #expect(rows.allSatisfy { $0["accountLabelIsDefault"] == nil })

        let ids = rows.compactMap { $0["accountId"] as? String }
        #expect(ids.first == "codex-managed:\(managed.id.uuidString.lowercased())")
        let systemID = try #require(ids.last)
        #expect(systemID.hasPrefix("codex-system:"))
        // Opaque: no email, path or upstream key in the id.
        #expect(!systemID.contains("@") && !systemID.contains("/") && !systemID.contains("acct-"))
        #expect(response.usageCacheKeys == ids)
        // One fetch per account, each in its own Codex home.
        #expect(await calls.calls == ["other@example.com", "system@example.com"])
    }

    @Test
    func `a managed account that is the everyday login is returned once`() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")
        let same = try fixture.addAccount(email: "system@example.com", accountID: "acct-system")

        // Alone, it is the everyday login's single row, exactly as upstream sends it.
        let calls = CallLog()
        let rows = try await Self.rows(Self.serve(fixture, fetch: Self.stubFetch(calls: calls)))
        #expect(rows.count == 1)
        #expect(rows.first?["accountId"] == nil)
        #expect(await calls.calls == ["default"])

        // Next to another managed account it is still one row: the everyday login's, not a managed duplicate.
        let other = try fixture.addAccount(email: "other@example.com", accountID: "acct-other")
        let both = try await Self.rows(Self.serve(fixture, fetch: Self.stubFetch()))
        #expect(both.count == 2)
        #expect(both.map { $0["accountSource"] as? String } == ["codex-managed", "codex-system"])
        #expect(both.map { $0["accountLabel"] as? String } == ["other@example.com", "system@example.com"])
        #expect(both.map { $0["active"] as? Bool } == [false, true])
        let ids = both.compactMap { $0["accountId"] as? String }
        #expect(ids.first == "codex-managed:\(other.id.uuidString.lowercased())")
        #expect(!ids.contains { $0.contains(same.id.uuidString.lowercased()) })
    }

    @Test
    func `a failing managed account shows its error on its own row only`() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")
        try fixture.addAccount(email: "other@example.com", accountID: "acct-other")
        try fixture.addAccount(email: "third@example.com", accountID: "acct-third")

        let rows = try await Self.rows(Self.serve(fixture, fetch: Self.stubFetch(failing: ["other@example.com"])))
        #expect(rows.map { $0["accountLabel"] as? String }
            == ["other@example.com", "system@example.com", "third@example.com"])
        let failing = try #require(rows.first)
        #expect((failing["error"] as? [String: Any])?["message"] as? String == "Codex token expired")
        #expect(failing["usage"] == nil)
        #expect(failing["updatedAt"] == nil)
        for healthy in rows.dropFirst() {
            #expect(healthy["error"] == nil)
            #expect(healthy["usage"] != nil)
            #expect(healthy["updatedAt"] as? String == "2026-09-21T14:13:20Z")
        }
    }

    @Test
    func `without managed accounts codex answers exactly as before`() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")

        let calls = CallLog()
        let response = try await Self.serve(fixture, fetch: Self.stubFetch(calls: calls))
        // Upstream's own selection (every reconciled account, here the everyday login) and its row unchanged.
        #expect(await calls.calls == ["default"])
        let expected = try #require(CodexBarCLI.encodeJSON([Self.upstreamRow], pretty: false))
        #expect(Self.sameJSON(response.body, Data(expected.utf8)))
        #expect(response.usageCacheKeys == ["codex:upstream"])

        // No login at all: the same.
        let empty = try CodexFixture()
        defer { empty.tearDown() }
        let none = try await Self.serve(empty, fetch: Self.stubFetch())
        #expect(Self.sameJSON(none.body, Data(expected.utf8)))
    }

    @Test
    func `an account without a name reads Account N and says so`() throws {
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [
                Self.visible(email: "system@example.com", source: .liveSystem),
                Self.visible(email: " ", source: .managedAccount(id: UUID())),
            ],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let accounts = CodexBarCLI.codexProviderAccounts(projection)
        #expect(accounts.map(\.fields.label) == ["system@example.com", "Account 2"])
        #expect(accounts.map(\.fields.labelIsDefault) == [false, true])

        let rows = CodexBarCLI.providerAccountRows(
            accounts.map { Self.payload(label: nil, key: $0.fields.accountID, usedPercent: 10) },
            accountsByProvider: [.codex: accounts])
        let json = try #require(CodexBarCLI.encodeJSON(rows, pretty: false))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(decoded.map { $0["accountLabelIsDefault"] as? Bool } == [nil, true])

        // Profile homes alone (no managed account) keep upstream's rows.
        let profiles = CodexVisibleAccountProjection(
            visibleAccounts: [
                Self.visible(email: "system@example.com", source: .liveSystem),
                Self.visible(email: "profile@example.com", source: .profileHome(path: "/synthetic/profile")),
            ],
            activeVisibleAccountID: nil,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        #expect(CodexBarCLI.codexProviderAccounts(profiles).isEmpty)
    }

    // MARK: - PAT isolation

    @Test
    func `a managed row never reads the everyday login's PAT`() async throws {
        let fixture = try CodexFixture()
        defer { fixture.tearDown() }
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system", pat: "synthetic-system-pat")
        let account = try fixture.addAccount(email: "other@example.com", accountID: "acct-other")
        let context = try fixture.tokenContext()
        let projection = try fixture.scoped { context.visibleCodexAccounts() }
        let managed = try #require(projection.visibleAccounts.first {
            $0.selectionSource == .managedAccount(id: account.id)
        })
        let system = try #require(projection.visibleAccounts.first { $0.selectionSource == .liveSystem })

        // Every configured source that could reach the PAT strategy is forced to OAuth for a managed row; the
        // Codex CLI already runs in the managed home. The everyday login keeps its configured source.
        for configured: ProviderSourceMode in [.auto, .api, .oauth, .web] {
            #expect(CodexBarCLI.codexProviderAccountSourceMode(managed, configured: configured) == .oauth)
        }
        #expect(CodexBarCLI.codexProviderAccountSourceMode(managed, configured: .cli) == .cli)
        for configured: ProviderSourceMode in [.auto, .api, .oauth, .web, .cli] {
            #expect(CodexBarCLI.codexProviderAccountSourceMode(system, configured: configured) == nil)
        }

        let env = context.environment(
            base: fixture.baseEnvironment,
            provider: .codex,
            account: nil,
            codexActiveSourceOverride: managed.selectionSource)
        #expect(env["CODEX_HOME"] == account.managedHomePath)
        let pipeline = ProviderDescriptorRegistry.descriptor(for: .codex).fetchPlan.pipeline
        try await CodexCredentialFileAccess.withFixtureScope(fixture.scope) {
            // The risk being closed: under .auto the PAT strategy swaps the managed home for $HOME/.codex and
            // finds the everyday login's token there.
            let auto = Self.fetchContext(env: env, sourceMode: .auto)
            #expect(CodexPATFetchStrategy.credentialEnvironment(env)["CODEX_HOME"] == fixture.liveHome.path)
            #expect(await CodexPATFetchStrategy().isAvailable(auto))
            #expect(await pipeline.resolveStrategies(auto).map(\.id).contains("codex.pat"))

            // The forced source never runs it.
            let forced = try #require(CodexBarCLI.codexProviderAccountSourceMode(managed, configured: .auto))
            let strategies = await pipeline.resolveStrategies(Self.fetchContext(env: env, sourceMode: forced))
            #expect(!strategies.isEmpty)
            #expect(!strategies.map(\.id).contains("codex.pat"))
        }
    }

    // MARK: - Helpers

    private static func serve(
        _ fixture: CodexFixture,
        fetch: @escaping CodexBarCLI.ProviderAccountUsageFetch) async throws -> CLILocalHTTPResponse
    {
        let context = try fixture.tokenContext()
        return await CodexCredentialFileAccess.withFixtureScope(fixture.scope) {
            await CodexBarCLI.serveProviderAccountUsage(
                provider: "codex",
                context: ServeUsageContext(
                    config: context.config,
                    configFingerprint: "codex-accounts-test",
                    refreshInterval: 60,
                    providerTimeout: nil,
                    providerDeadline: nil,
                    providerOperations: CLIServeOperationCoordinator()),
                fetch: fetch,
                accountContext: context)
        }
    }

    private static func rows(_ response: CLILocalHTTPResponse) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }

    private static func sameJSON(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let lhs = try? JSONSerialization.jsonObject(with: lhs) as? NSArray,
              let rhs = try? JSONSerialization.jsonObject(with: rhs) as? NSArray
        else { return false }
        return lhs.isEqual(rhs)
    }

    private static func payload(label: String?, key: String?, usedPercent: Double?) -> ProviderPayload {
        let usage = usedPercent.map {
            UsageSnapshot(
                primary: RateWindow(usedPercent: $0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Self.updatedAt)
        }
        return ProviderPayload(
            provider: .codex,
            account: label,
            cacheAccountKey: key,
            version: nil,
            source: "oauth",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: usedPercent == nil
                ? ProviderErrorPayload(code: 1, message: "Codex token expired", kind: .provider)
                : nil)
    }

    /// What upstream's own Codex selection returns in the stub.
    private static let upstreamRow = Self.payload(label: "system@example.com", key: "codex:upstream", usedPercent: 40)

    /// Answers for the Codex account the selector names, with a cache key serve must replace with its own tag.
    private static func stubFetch(
        failing: Set<String> = [],
        calls: CallLog = CallLog()) -> CodexBarCLI.ProviderAccountUsageFetch
    {
        { _, selector in
            var output = UsageCommandOutput()
            switch selector {
            case nil:
                await calls.record("default")
                output.payload.append(Self.upstreamRow)
            case let .codexAccount(account):
                await calls.record(account.email)
                output.payload.append(Self.payload(
                    label: account.menuDisplayName,
                    key: "codex:upstream-\(account.email)",
                    usedPercent: failing.contains(account.email) ? nil : 40))
            case .tokenIndex:
                Issue.record("Codex was fetched by token-account index")
            }
            return output
        }
    }

    private static func visible(email: String, source: CodexActiveSource) -> CodexVisibleAccount {
        var stored: UUID?
        if case let .managedAccount(id) = source { stored = id }
        return CodexVisibleAccount(
            id: email,
            email: email,
            storedAccountID: stored,
            selectionSource: source,
            isActive: false,
            isLive: source == .liveSystem,
            canReauthenticate: false,
            canRemove: false)
    }

    private static func fetchContext(env: [String: String], sourceMode: ProviderSourceMode) -> ProviderFetchContext {
        let browser = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
            browserDetection: browser)
    }

    actor CallLog {
        private(set) var calls: [String] = []
        func record(_ label: String) {
            self.calls.append(label)
        }
    }
}

/// `root/.codex` is the everyday login (`HOME` and `CODEX_HOME`), `root/managed-codex-homes/<uuid>` the managed
/// homes, `root/managed-codex-accounts.json` the store.
private final class CodexFixture {
    let root: URL
    let storeURL: URL
    let liveHome: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeCodexAccountsTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        self.storeURL = self.root.appendingPathComponent("managed-codex-accounts.json")
        self.liveHome = self.root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: self.liveHome, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
    }

    var baseEnvironment: [String: String] {
        ["HOME": self.root.path, "CODEX_HOME": self.liveHome.path]
    }

    var scope: CodexCredentialFileAccess.FixtureScope {
        CodexCredentialFileAccess.FixtureScope(roots: [self.root])
    }

    func scoped<T>(_ operation: () throws -> T) throws -> T {
        try CodexCredentialFileAccess.withFixtureScope(self.scope, operation: operation)
    }

    func tokenContext() throws -> TokenAccountCLIContext {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: CodexBarConfig(providers: [ProviderConfig(id: UsageProvider.codex.instanceID, enabled: true)]),
            verbose: false,
            baseEnvironment: self.baseEnvironment,
            managedCodexAccountStoreURL: self.storeURL)
    }

    @discardableResult
    func addAccount(email: String, accountID: String) throws -> ManagedCodexAccount {
        let id = UUID()
        let home = self.root.appendingPathComponent("managed-codex-homes/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Self.authData(email: email, accountID: accountID).write(to: home.appendingPathComponent("auth.json"))
        let account = ManagedCodexAccount(
            id: id,
            email: email,
            providerAccountID: accountID,
            workspaceLabel: nil,
            workspaceAccountID: nil,
            managedHomePath: home.path,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)
        let store = FileManagedCodexAccountStore(fileURL: self.storeURL)
        let existing = try self.scoped { try store.loadAccountMetadata().accounts }
        try self.scoped {
            try store.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: existing + [account]))
        }
        return account
    }

    func writeLiveAuth(email: String, accountID: String, pat: String? = nil) throws {
        try Self.authData(email: email, accountID: accountID, pat: pat)
            .write(to: self.liveHome.appendingPathComponent("auth.json"))
    }

    static func authData(email: String, accountID: String, pat: String? = nil) -> Data {
        let claims: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "plus"],
        ]
        var auth: [String: Any] = [
            "tokens": [
                "access_token": "synthetic-access",
                "refresh_token": "synthetic-refresh",
                "id_token": Self.jwt(claims),
                "account_id": accountID,
            ],
            "last_refresh": "2026-01-01T00:00:00Z",
        ]
        if let pat { auth["personal_access_token"] = pat }
        return (try? JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])) ?? Data()
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        func encode(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "none", "typ": "JWT"])).\(encode(claims)).synthetic-signature"
    }
}
#endif
