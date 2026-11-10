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
/// Codex gets rows only once it has a managed account shown on its own; without one (and with a single account) it
/// keeps upstream's untagged rows exactly. The everyday login is the active account.
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
    /// own home: through the Codex CLI when that is the configured source, else through OAuth.
    static func codexProviderAccountSourceMode(
        _ account: CodexVisibleAccount,
        configured: ProviderSourceMode) -> ProviderSourceMode?
    {
        guard account.selectionSource != .liveSystem else { return nil }
        return configured == .cli ? .cli : .oauth
    }

    /// Upstream's per-account Codex fetch (the one plain `/usage` runs for each reconciled account), with the source
    /// mode `codexProviderAccountSourceMode` picks.
    static func fetchCodexProviderAccount(
        _ account: CodexVisibleAccount,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext) async -> UsageCommandOutput
    {
        var command = command
        // Provider-specific by design: Codex's source mode decides whether its PAT strategy (which ignores managed
        // homes) can run, and the fetch is upstream's per-account Codex fetch.
        let configured = command.sourceModeOverride ?? tokenContext.preferredSourceMode(for: .codex)
        if let forced = Self.codexProviderAccountSourceMode(account, configured: configured) {
            command.sourceModeOverride = forced
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

extension CodexVisibleAccount {
    fileprivate var providerAccountSource: ProviderAccountSource {
        switch self.selectionSource {
        case .liveSystem: .codexSystem
        case .managedAccount: .codexManaged
        case .profileHome: .codexProfile
        }
    }
}
