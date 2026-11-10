import CodexBarCore
import Foundation

// MARK: - Provider Account rows on serve's /usage

/// `GET /usage?accounts=all`: one `/usage` row per Provider Account, for clients that saw the
/// `providerAccountRows` capability on `/health`. Plain `/usage` never reaches this file, so it stays upstream's
/// single-account answer byte for byte.
///
/// A provider with two or more token accounts (and a source mode that uses them) gets one row per account, fetched
/// one after another through upstream's own per-account fetch, each carrying `ProviderAccountRowFields`. Every
/// other provider, including one with a single account, gets exactly the row plain `/usage` gives it. Managed Codex
/// accounts and claude-swap slots are later sources of the same row shape; Codex keeps upstream's rows for now.
extension CodexBarCLI {
    /// Fetches one provider's usage with `tokenContext`'s account selection. Live serve passes upstream's
    /// `fetchUsageOutputs`; tests pass a stub, so no test reaches a provider.
    typealias ProviderAccountUsageFetch = @Sendable (UsageProvider, TokenAccountCLIContext) async
        -> UsageCommandOutput

    static let providerAccountsQueryValue = "all"

    static func isProviderAccountUsageRequest(_ request: CLILocalHTTPRequest) -> Bool {
        guard request.method.uppercased() == "GET", request.path == "/usage" else { return false }
        let value = request.queryItems["accounts"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == self.providerAccountsQueryValue
    }

    /// Same auth, response cache and `Cache-Control` as upstream's `/usage`, under its own cache key and
    /// operation fingerprint so a single-account body is never served for an accounts request or the reverse.
    static func serveProviderAccountUsageRoute(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime,
        fetch: ProviderAccountUsageFetch? = nil) async -> CLILocalHTTPResponse
    {
        guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
            return self.serveUnauthorizedResponse()
        }
        let startedAt = ContinuousClock().now
        let provider = request.queryItems["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = provider?.isEmpty == false ? provider : nil
        let snapshot: CLIServeConfigSnapshot
        let operationKey: String
        do {
            snapshot = try self.loadServeConfigSnapshot(configStore: runtime.configStore)
        } catch {
            return self.addingNoStore(self.forkServeError(
                status: .internalServerError,
                message: error.localizedDescription))
        }
        do {
            // Keeps upstream's `usage:` prefix: the response cache's per-account last-good merge keys on it.
            // It throws only for an unknown `provider`.
            operationKey = try "\(self.serveOperationKey(kind: "usage", provider: normalizedProvider)):accounts"
        } catch {
            return self.addingNoStore(self.forkServeError(status: .badRequest, message: error.localizedDescription))
        }
        let context = ServeUsageContext(
            config: snapshot.config,
            configFingerprint: snapshot.cacheToken,
            refreshInterval: runtime.refreshInterval,
            providerTimeout: self.serveProviderTimeout(requestTimeout: runtime.requestTimeout),
            providerDeadline: self.serveProviderDeadline(startedAt: startedAt, requestTimeout: runtime.requestTimeout),
            providerOperations: runtime.providerOperations)
        return await self.addingNoStore(self.cachedServeResponse(
            key: operationKey,
            cache: runtime.cache,
            refreshInterval: runtime.refreshInterval,
            requestTimeout: runtime.requestTimeout,
            configFingerprint: snapshot.cacheToken,
            staleWhileRevalidate: true)
        {
            await self.serveProviderAccountUsage(provider: normalizedProvider, context: context, fetch: fetch)
        })
    }

    static func serveProviderAccountUsage(
        provider rawProvider: String?,
        context: ServeUsageContext,
        fetch: ProviderAccountUsageFetch? = nil,
        now: @Sendable () -> Date = { Date() }) async -> CLILocalHTTPResponse
    {
        let providers: [UsageProvider]
        let defaultContext: TokenAccountCLIContext
        guard let selected = self.serveProviderAccountSelection(rawProvider: rawProvider, config: context.config)
        else {
            return self.forkServeError(status: .badRequest, message: "Unknown provider: \(rawProvider ?? "")")
        }
        providers = selected
        do {
            defaultContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: context.config,
                verbose: false)
        } catch {
            return self.forkServeError(status: .internalServerError, message: error.localizedDescription)
        }
        let command = self.serveUsageCommand(context: context)
        let fetch = fetch ?? { provider, tokenContext in
            await self.fetchUsageOutputs(provider: provider, status: nil, tokenContext: tokenContext, command: command)
        }
        let accountsByProvider = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider, self.providerAccounts(for: provider, context: defaultContext))
        })

        let output = await self.serveCollectUsageOutputs(
            providers: providers,
            configFingerprint: self.serveUsageOperationFingerprint(
                configFingerprint: context.configFingerprint,
                includeAllCodexAccounts: context.includeAllCodexAccounts) + ":provider-accounts=all",
            deadline: context.providerDeadline,
            operations: context.providerOperations)
        { provider in
            await ProviderInteractionContext.$current.withValue(.background) {
                await self.fetchProviderAccountOutputs(
                    provider: provider,
                    accounts: accountsByProvider[provider] ?? [],
                    defaultContext: defaultContext,
                    fetch: fetch)
            }
        }

        let fetchedAt = now()
        let rows = output.payload.map { row in
            self.providerAccountRow(
                row,
                accounts: row.usageProvider.flatMap { accountsByProvider[$0] } ?? [],
                fetchedAt: fetchedAt)
        }
        let json = self.encodeJSON(rows, pretty: false) ?? "[]"
        return CLILocalHTTPResponse(
            status: .ok,
            body: Data(json.utf8),
            usageCacheKeys: output.payload.map(\.cacheAccountKey))
    }

    /// The Provider Accounts `provider` shows as separate rows: its token accounts when it has two or more and the
    /// source mode in use reads them. Empty means the provider keeps upstream's single-account row.
    static func providerAccounts(
        for provider: UsageProvider,
        context: TokenAccountCLIContext) -> [ProviderAccountRowFields]
    {
        // Provider-specific by design: managed Codex accounts are their own source (#168); Codex keeps upstream's
        // reconciled-account rows until then.
        guard provider != .codex,
              let data = context.accountsByProvider[provider],
              data.accounts.count >= 2,
              // Upstream's default selection reads token accounts only in an active source mode, and then
              // exactly one; an empty answer (a passive mode) means the provider doesn't use them.
              let selected = try? context.resolvedAccounts(for: provider),
              !selected.isEmpty
        else { return [] }
        let activeIndex = data.clampedActiveIndex()
        return data.accounts.enumerated().map { index, account in
            ProviderAccountRowFields(
                source: .token,
                id: account.id.uuidString.lowercased(),
                index: index,
                label: Self.providerAccountLabel(account.label, index: index),
                active: index == activeIndex)
        }
    }

    static func providerAccountLabel(_ label: String, index: Int) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Account \(index + 1)" : trimmed
    }

    /// One fetch per Provider Account, in store order, each through upstream's index selection so it reads that
    /// account's token only. A failing account adds its own error row and the others still fetch.
    private static func fetchProviderAccountOutputs(
        provider: UsageProvider,
        accounts: [ProviderAccountRowFields],
        defaultContext: TokenAccountCLIContext,
        fetch: ProviderAccountUsageFetch) async -> UsageCommandOutput
    {
        guard !accounts.isEmpty else { return await fetch(provider, defaultContext) }
        let refreshDelay = TokenAccountSupportCatalog.support(for: provider)?.minimumDelayBetweenAccountRefreshes
        var output = UsageCommandOutput()
        for account in accounts {
            if account.index > 0, let refreshDelay {
                do {
                    try await Task.sleep(for: refreshDelay)
                } catch {
                    return output
                }
            }
            let tokenContext: TokenAccountCLIContext
            do {
                tokenContext = try TokenAccountCLIContext(
                    selection: TokenAccountCLISelection(label: nil, index: account.index, allAccounts: false),
                    config: defaultContext.config,
                    verbose: false)
            } catch {
                continue
            }
            await output.merge(fetch(provider, tokenContext))
        }
        return output
    }

    private static func providerAccountRow(
        _ row: ProviderPayload,
        accounts: [ProviderAccountRowFields],
        fetchedAt: Date) -> ProviderAccountRowPayload
    {
        guard let key = row.cacheAccountKey,
              let account = accounts.first(where: { $0.accountID == key })
        else { return ProviderAccountRowPayload(row: row, account: nil, updatedAt: nil) }
        return ProviderAccountRowPayload(row: row, account: account, updatedAt: row.usage?.updatedAt ?? fetchedAt)
    }

    /// Upstream's private `serveProviderSelection`: the `provider` query, or the enabled providers; nil for an
    /// unknown provider (the route has already answered that with upstream's 400).
    private static func serveProviderAccountSelection(
        rawProvider: String?,
        config: CodexBarConfig) -> [UsageProvider]?
    {
        guard let rawProvider, !rawProvider.isEmpty else {
            return self.providerSelection(
                rawOverride: nil,
                enabled: config.enabledProviders().compactMap(\.firstPartyProvider)).asList
        }
        return ProviderSelection(argument: rawProvider)?.asList
    }
}

/// Where a Provider Account comes from. The id after the colon in `accountId` is opaque to clients.
enum ProviderAccountSource: String, Encodable, Sendable {
    /// A labelled key or cookie in the token-account store; the id is the account's UUID.
    case token
}

/// The fields one Provider Account adds to its `/usage` row.
struct ProviderAccountRowFields: Equatable, Sendable {
    let source: ProviderAccountSource
    let id: String
    /// Position in the provider's account store; selects the account for the fetch, never sent.
    let index: Int
    let label: String
    let active: Bool

    /// `<source>:<opaque id>`, stable across refreshes, renames and reorders. For token accounts it equals the
    /// per-account key upstream already gives the row (`usageCacheAccountKey`), which pairs rows with accounts.
    var accountID: String {
        "\(self.source.rawValue):\(self.id)"
    }
}

/// A `/usage` row: upstream's `ProviderPayload` keys unchanged, then the Provider Account keys when the row is one
/// of several accounts. Without an account it encodes exactly as the bare `ProviderPayload`.
struct ProviderAccountRowPayload: Encodable {
    let row: ProviderPayload
    let account: ProviderAccountRowFields?
    /// The row's own freshness: its usage snapshot's time, or when its fetch failed.
    let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case accountId
        case accountSource
        case accountLabel
        case active
        case updatedAt
    }

    func encode(to encoder: any Encoder) throws {
        try self.row.encode(to: encoder)
        guard let account else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account.accountID, forKey: .accountId)
        try container.encode(account.source, forKey: .accountSource)
        try container.encode(account.label, forKey: .accountLabel)
        try container.encode(account.active, forKey: .active)
        try container.encodeIfPresent(self.updatedAt, forKey: .updatedAt)
    }
}

extension ProviderPayload {
    fileprivate var usageProvider: UsageProvider? {
        UsageProvider(rawValue: self.provider)
    }
}
