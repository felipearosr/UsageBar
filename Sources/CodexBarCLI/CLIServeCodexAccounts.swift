import CodexBarCore
import Crypto
import Foundation

// MARK: - Managed Codex accounts as Provider Account rows

/// Codex's Provider Accounts on `GET /usage?accounts=all` (#168).
///
/// The accounts are upstream's reconciled Codex accounts (`TokenAccountCLIContext.visibleCodexAccounts()`), the same
/// list serve's plain `/usage` already fetches one by one in each account's own `CODEX_HOME`. Reconciliation already
/// folds a managed account that is the everyday login into the everyday login's entry, by upstream's identity rule
/// (the one `codex-accounts list` uses for its system marker), so such an account is listed once.
///
/// Codex gets rows only once it has a managed account shown on its own next to another account; otherwise it keeps
/// upstream's untagged rows (see `codexUntaggedFetches`). The everyday login is the active account. An everyday login
/// that is only a PAT or API key has no email, so reconciliation doesn't list it: it gets no row of its own and, with
/// two or more managed accounts, no row is marked active.
extension CodexBarCLI {
    static func codexProviderAccounts(_ projection: CodexVisibleAccountProjection) -> [ProviderAccount] {
        let accounts = projection.visibleAccounts
        guard accounts.count >= 2,
              accounts.contains(where: { $0.providerAccountSource == .codexManaged })
        else { return [] }
        return accounts.enumerated().map { index, account in
            let name = account.menuDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderAccount(
                fields: ProviderAccountRowFields(
                    source: account.providerAccountSource,
                    id: Self.codexProviderAccountID(account),
                    label: name.isEmpty ? "Account \(index + 1)" : name,
                    active: account.isLive,
                    labelIsDefault: name.isEmpty),
                selector: .codexAccount(account))
        }
    }

    /// The opaque half of `accountId`. Managed accounts keep their store UUID. The everyday login and profile homes
    /// get a short hash, so the id carries no email or path but changes when a different account logs in there.
    static func codexProviderAccountID(_ account: CodexVisibleAccount) -> String {
        switch account.selectionSource {
        case let .managedAccount(id):
            return id.uuidString.lowercased()
        case .liveSystem:
            // Provider-specific by design: upstream's Codex cache key names the everyday login's workspace identity.
            let identity = Self.usageCacheAccountKey(provider: .codex, account: nil, codexVisibleAccount: account)
            return Self.shortHash("system\u{0}\(identity ?? account.id)")
        case let .profileHome(path):
            return Self.shortHash("profile\u{0}\(CodexHomeScope.normalizedHomePath(path) ?? path)")
        }
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The source mode a Codex account's fetch is forced to, or nil to keep the configured one.
    ///
    /// Codex's PAT strategy reads its token from `$HOME/.codex` whenever `CODEX_HOME` is a managed home (and from
    /// there too for a profile home without a PAT of its own), so under `.auto` or `.api` a managed account's row
    /// would show the everyday login's workspace. Every account other than the everyday login therefore reads its
    /// own home through OAuth, except a profile home holding its own PAT, which the PAT strategy reads in place and
    /// so keeps the configured source, as upstream's loop does. The Codex CLI stays when it is the configured source
    /// and no managed workspace is selected: its app-server can't carry the workspace header, so with one it would
    /// report the auth file's workspace instead.
    static func codexProviderAccountSourceMode(
        _ account: CodexVisibleAccount,
        configured: ProviderSourceMode,
        workspaceSelected: Bool,
        homeHasOwnPAT: Bool = false) -> ProviderSourceMode?
    {
        switch account.selectionSource {
        case .liveSystem:
            nil
        case .profileHome where homeHasOwnPAT:
            nil
        case .managedAccount, .profileHome:
            configured == .cli && !workspaceSelected ? .cli : .oauth
        }
    }

    /// The usage command one Codex account is fetched with: serve's, with `codexProviderAccountSourceMode` applied.
    static func codexProviderAccountCommand(
        account: CodexVisibleAccount,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext,
        base: [String: String] = ProcessInfo.processInfo.environment) -> UsageCommandContext
    {
        var command = command
        // Provider-specific by design: Codex's source mode decides whether its PAT strategy (which ignores managed
        // homes) can run, and its managed workspace decides whether the Codex CLI can stand in for OAuth.
        let configured = command.sourceModeOverride ?? tokenContext.preferredSourceMode(for: .codex)
        let workspaceSelected = account.selectionSource != .liveSystem && tokenContext.settingsSnapshot(
            for: .codex,
            account: nil,
            codexActiveSourceOverride: account.selectionSource)?.codex?.managedWorkspaceAccountID != nil
        // A profile home's own PAT is what upstream's PAT strategy reads there (it never swaps a profile home that
        // has one for $HOME/.codex); `loadPAT` reads only the scoped home.
        var homeHasOwnPAT = false
        if case .profileHome = account.selectionSource {
            let env = tokenContext.environment(
                base: base,
                provider: .codex,
                account: nil,
                codexActiveSourceOverride: account.selectionSource)
            homeHasOwnPAT = Self.codexAccountHomeIsOwn(account, env: env, base: base)
                && (try? CodexOAuthCredentialsStore.loadPAT(env: env)) != nil
        }
        if let forced = Self.codexProviderAccountSourceMode(
            account,
            configured: configured,
            workspaceSelected: workspaceSelected,
            homeHasOwnPAT: homeHasOwnPAT)
        {
            command.sourceModeOverride = forced
        }
        return command
    }

    /// One Codex fetch serve runs: one account with its own command, or upstream's whole Codex selection (`account`
    /// nil) with serve's command unchanged.
    struct CodexAccountFetch {
        let account: CodexVisibleAccount?
        let command: UsageCommandContext
    }

    /// Codex's fetches when it has no Provider Account rows. Upstream's loop when no account is managed (the everyday
    /// login, profile homes, or none), so those rows are exactly today's. Otherwise, for example a managed account
    /// next to an everyday login that is only a PAT or API key (which reconciliation doesn't list), each account is
    /// fetched on its own with `codexProviderAccountCommand`, so no managed home ever reads the everyday login's PAT.
    /// Rows stay untagged and otherwise identical to upstream's: it is upstream's per-account fetch either way.
    static func codexUntaggedFetches(
        _ projection: CodexVisibleAccountProjection,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) -> [CodexAccountFetch]
    {
        let accounts = projection.visibleAccounts
        guard command.includeAllCodexAccounts,
              accounts.contains(where: { $0.providerAccountSource == .codexManaged })
        else { return [CodexAccountFetch(account: nil, command: command)] }
        return accounts.map { account in
            CodexAccountFetch(
                account: account,
                command: Self.codexProviderAccountCommand(
                    account: account,
                    tokenContext: tokenContext,
                    command: command))
        }
    }

    /// Serve's Codex fetch for `/usage?accounts=all` when Codex has no Provider Account rows.
    static func fetchCodexUntagged(
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        let fetches = Self.codexUntaggedFetches(
            tokenContext.visibleCodexAccounts(),
            tokenContext: tokenContext,
            command: command)
        var output = UsageCommandOutput()
        for fetch in fetches {
            if let account = fetch.account {
                await output.merge(Self.runCodexAccountFetch(
                    account,
                    tokenContext: tokenContext,
                    command: fetch.command))
            } else {
                // Provider-specific by design: upstream's reconciled Codex selection, unchanged.
                await output.merge(Self.fetchUsageOutputs(
                    provider: .codex,
                    status: nil,
                    tokenContext: tokenContext,
                    command: fetch.command))
            }
        }
        return output
    }

    /// One Codex Provider Account's fetch: upstream's per-account Codex fetch (the one plain `/usage` runs for each
    /// reconciled account) with `codexProviderAccountCommand`.
    static func fetchCodexProviderAccount(
        _ account: CodexVisibleAccount,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        await self.runCodexAccountFetch(
            account,
            tokenContext: tokenContext,
            command: self.codexProviderAccountCommand(account: account, tokenContext: tokenContext, command: command))
    }

    /// Whether `env` (what the fetch will run with) reads `account`'s own Codex home. A managed account removed or a
    /// profile home unconfigured since the list was read resolves to no scoped home, so the fetch would fall back to
    /// the everyday login's home and show its usage under this account's row.
    static func codexAccountHomeIsOwn(
        _ account: CodexVisibleAccount,
        env: [String: String],
        base: [String: String]) -> Bool
    {
        guard account.selectionSource != .liveSystem else { return true }
        guard let home = CodexHomeScope.normalizedHomePath(env["CODEX_HOME"]) else { return false }
        var ambient = [base["CODEX_HOME"]]
        // Provider-specific by design: without CODEX_HOME, Codex reads the everyday login from $HOME/.codex.
        if let userHome = base["HOME"] {
            ambient.append(URL(fileURLWithPath: userHome, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true).path)
        }
        return !ambient.compactMap { CodexHomeScope.normalizedHomePath($0) }.contains(home)
    }

    private static func runCodexAccountFetch(
        _ account: CodexVisibleAccount,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        // Provider-specific by design: Codex accounts are separate Codex homes; the fetch must run in this one.
        let base = ProcessInfo.processInfo.environment
        let env = tokenContext.environment(
            base: base,
            provider: .codex,
            account: nil,
            codexActiveSourceOverride: account.selectionSource)
        guard Self.codexAccountHomeIsOwn(account, env: env, base: base) else {
            var output = UsageCommandOutput()
            output.exitCode = .failure
            output.payload.append(Self.makeProviderErrorPayload(
                provider: .codex,
                account: account.menuDisplayName,
                cacheAccountKey: Self.usageCacheAccountKey(
                    provider: .codex,
                    account: nil,
                    codexVisibleAccount: account),
                source: command.sourceModeOverride?.rawValue ?? ProviderSourceMode.oauth.rawValue,
                status: nil,
                error: CodexProviderAccountError.homeUnavailable))
            return output
        }
        return await self.fetchUsageOutput(
            provider: .codex,
            account: nil,
            codexVisibleAccount: account,
            status: nil,
            tokenContext: tokenContext,
            command: command)
    }
}

enum CodexProviderAccountError: LocalizedError, Equatable {
    case homeUnavailable

    var errorDescription: String? {
        "This Codex account's home is no longer available. Add the account again with codexbar codex-accounts."
    }
}

extension CodexVisibleAccount {
    fileprivate var providerAccountSource: ProviderAccountSource {
        switch self.selectionSource {
        case .liveSystem: .codexSystem
        case .managedAccount: .codexManaged
        case .profileHome: .codexProfile
        }
    }
}
