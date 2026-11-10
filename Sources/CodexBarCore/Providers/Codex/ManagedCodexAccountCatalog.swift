import Foundation

// UsageBar (fork-owned, #167): the platform-neutral read side of managed Codex accounts. Listing an account and
// fetching its usage from its own Codex home work on Linux; adding, re-authenticating and promoting accounts stay
// with the macOS app and `codexbar codex-accounts promote`.

/// One managed Codex account as other processes (`codexbar serve`, `codex-accounts list`) may show it.
///
/// Identity labels only: never tokens, auth fingerprints or the private managed home path.
public struct ManagedCodexAccountSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let email: String
    public let workspaceLabel: String?
    /// Whether this account's saved login matches the system Codex login (`CODEX_HOME`, else `~/.codex`).
    public let isSystemAccount: Bool

    public init(id: UUID, email: String, workspaceLabel: String?, isSystemAccount: Bool) {
        self.id = id
        self.email = email
        self.workspaceLabel = workspaceLabel
        self.isSystemAccount = isSystemAccount
    }
}

public enum ManagedCodexAccountCatalogError: Error, Equatable, LocalizedError {
    /// No managed account has this ID (it may have been removed since it was listed).
    case unknownAccount(UUID)
    /// The stored home path is not an absolute directory, or it is the system Codex home itself.
    case unusableHome(UUID)

    public var errorDescription: String? {
        switch self {
        case .unknownAccount:
            "No matching managed Codex account."
        case .unusableHome:
            "The managed Codex account's home is not a separate absolute directory."
        }
    }
}

/// Fetch inputs for one managed account, scoped to that account's own Codex home.
///
/// `environment` carries the private home path in `CODEX_HOME`; callers must never serialize it.
public struct ManagedCodexAccountUsageScope: Sendable {
    public let accountID: UUID
    @ProcessEnvironment public private(set) var environment: [String: String]
    public let settings: ProviderSettingsSnapshot.CodexProviderSettings

    /// A `UsageFetcher` that reads auth, sessions and the app-server from the managed home only.
    public func makeUsageFetcher() -> UsageFetcher {
        UsageFetcher(environment: self.environment)
    }

    /// The provider fetch context for this account.
    ///
    /// `.oauth` is the default source because it reads only the managed home's `auth.json`. `.auto` tries a
    /// Codex personal access token first, and upstream resolves that token from the system `~/.codex` even for
    /// managed homes, so `.auto` can report the system workspace instead of this account.
    public func makeFetchContext(
        sourceMode: ProviderSourceMode = .oauth,
        runtime: ProviderRuntime = .cli,
        includeCredits: Bool = true,
        webTimeout: TimeInterval = 60,
        browserDetection: BrowserDetection = BrowserDetection(),
        persistsCLISessions: Bool = false) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: includeCredits,
            requiresOptionalUsageCompleteness: true,
            webTimeout: webTimeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: self.environment,
            settings: .make(codex: self.settings),
            fetcher: self.makeUsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection, environment: self.environment),
            browserDetection: browserDetection,
            persistsCLISessions: persistsCLISessions)
    }

    /// Runs the Codex fetch pipeline for this account.
    public func fetchUsage(context: ProviderFetchContext) async -> ProviderFetchOutcome {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        guard descriptor.fetchPlan.sourceModes.contains(context.sourceMode) else {
            return ProviderFetchOutcome(
                result: .failure(ManagedCodexAccountUsageScopeError.unsupportedSource(context.sourceMode)),
                attempts: [])
        }
        return await descriptor.fetchOutcome(context: context)
    }

    public func fetchUsage(sourceMode: ProviderSourceMode = .oauth) async -> ProviderFetchOutcome {
        await self.fetchUsage(context: self.makeFetchContext(sourceMode: sourceMode))
    }
}

public enum ManagedCodexAccountUsageScopeError: Error, Equatable, LocalizedError {
    case unsupportedSource(ProviderSourceMode)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSource(mode):
            "Source '\(mode.rawValue)' is not supported for managed Codex accounts."
        }
    }
}

/// Lists managed Codex accounts and scopes usage fetches to each account's own Codex home.
///
/// Reads the app-owned account store (`managed-codex-accounts.json`) and each account's `auth.json`; it never
/// writes either, never reads a Keychain, and never touches the system login except to mark which account
/// matches it.
public struct ManagedCodexAccountCatalog: Sendable {
    public let storeURL: URL
    @ProcessEnvironment public private(set) var baseEnvironment: [String: String]
    let authReader: any CodexAuthMaterialReading

    public init(
        storeURL: URL = FileManagedCodexAccountStore.defaultURL(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.init(storeURL: storeURL, baseEnvironment: baseEnvironment, authReader: DefaultCodexAuthMaterialReader())
    }

    init(
        storeURL: URL,
        baseEnvironment: [String: String],
        authReader: any CodexAuthMaterialReading)
    {
        self.storeURL = storeURL
        self.baseEnvironment = baseEnvironment
        self.authReader = authReader
    }

    /// The stored accounts, in store order. Includes the private home paths: keep these in-process.
    public func accounts() throws -> [ManagedCodexAccount] {
        try FileManagedCodexAccountStore(fileURL: self.storeURL).loadAccounts().accounts
    }

    /// The stored accounts as safe-to-emit summaries. An unreadable or malformed `auth.json` only clears that
    /// account's system marker; it never drops the account. Main-actor isolated because it shares the
    /// `auth.json` identity parser with promotion (`PreparedPromotionContextBuilder`).
    @MainActor
    public func list() throws -> [ManagedCodexAccountSummary] {
        let accounts = try self.accounts()
        let live = self.runtimeAccount(home: CodexHomeScope.ambientHomeURL(env: self.baseEnvironment))
        return accounts.map { account in
            let isSystemAccount = live.flatMap { live in
                self.runtimeAccount(home: URL(fileURLWithPath: account.managedHomePath, isDirectory: true))
                    .map { Self.matches(account: account, runtime: $0, live: live) }
            } ?? false
            return ManagedCodexAccountSummary(
                id: account.id,
                email: account.email,
                workspaceLabel: account.workspaceLabel,
                isSystemAccount: isSystemAccount)
        }
    }

    /// Fetch inputs for one account, scoped to its managed home and its selected workspace.
    public func usageScope(accountID: UUID) throws -> ManagedCodexAccountUsageScope {
        let accounts = try self.accounts()
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw ManagedCodexAccountCatalogError.unknownAccount(accountID)
        }
        let systemHome = CodexHomeScope.ambientHomeURL(env: self.baseEnvironment)
        guard let home = CodexHomeScope.normalizedHomePath(account.managedHomePath),
              home != CodexHomeScope.normalizedHomePath(systemHome.path)
        else {
            throw ManagedCodexAccountCatalogError.unusableHome(accountID)
        }

        let source = CodexActiveSource.managedAccount(id: account.id)
        let accountSet = ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts)
        let snapshot = DefaultCodexAccountReconciler(
            storeLoader: { accountSet },
            activeSource: source,
            baseEnvironment: self.baseEnvironment).loadSnapshot()
        // The app collapses a managed account that matches the system login onto the system source; a per-account
        // row must keep reading the account's own home, so the resolved source stays this account.
        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .off,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexResolvedActiveSource(persistedSource: source, resolvedSource: source)))
        return ManagedCodexAccountUsageScope(
            accountID: account.id,
            environment: CodexHomeScope.scopedEnvironment(base: self.baseEnvironment, codexHome: home),
            settings: settings)
    }

    @MainActor
    private func runtimeAccount(home: URL) -> CodexAuthBackedAccount? {
        guard let data = try? self.authReader.readAuthData(homeURL: home) else { return nil }
        return try? PreparedPromotionContextBuilder.runtimeAccount(from: data)
    }

    /// Same identity rule as `codexbar codex-accounts list` (`CodexBarCLI.codexAccountRows`): the app-selected
    /// workspace wins over the auth file's default workspace.
    static func matches(
        account: ManagedCodexAccount,
        runtime: CodexAuthBackedAccount,
        live: CodexAuthBackedAccount) -> Bool
    {
        let identity = account.effectiveWorkspaceAccountID.map { CodexIdentity.providerAccount(id: $0) }
            ?? runtime.identity
        return CodexIdentityMatcher.matches(identity, lhsEmail: runtime.email, live.identity, rhsEmail: live.email)
    }
}
