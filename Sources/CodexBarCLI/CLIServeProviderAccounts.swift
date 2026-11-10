import CodexBarCore
import Foundation

// MARK: - Provider Account rows on serve's /usage

/// `GET /usage?accounts=all`: one `/usage` row per Provider Account, for clients that saw the
/// `providerAccountRows` capability on `/health`. Plain `/usage` never reaches this file, so it stays upstream's
/// single-account answer.
///
/// A provider with two or more token accounts (and a source mode that uses them) gets one row per account, fetched
/// one after another through upstream's own per-account fetch, each carrying `ProviderAccountRowFields`. With
/// claude-swap enabled, Claude gets one row per claude-swap slot from a single list read (CLIServeClaudeSwap.swift)
/// instead. Every other provider, including one with a single account, gets exactly the row plain `/usage` gives
/// it. Managed Codex accounts are a later source of the same row shape; Codex keeps upstream's rows for now.
///
/// Tagging is all or nothing per provider: once a provider has Provider Accounts, every row it returns carries one
/// account's fields, including a provider-level timeout, which becomes one error row per account. Clients can rely
/// on that, and serve's per-account last-good merge (keyed on each row's `accountId`) restores each account.
extension CodexBarCLI {
    /// Fetches one provider's usage for one account (`selector`), or with upstream's default selection when
    /// `selector` is nil. Live serve maps the selector onto upstream's `fetchUsageOutputs`; tests pass a stub, so no
    /// test reaches a provider. The rows it returns need no particular cache key: serve tags them with the account.
    typealias ProviderAccountUsageFetch = @Sendable (UsageProvider, ProviderAccountSelector?) async
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
        fetch: ProviderAccountUsageFetch? = nil,
        claudeSwap: ClaudeSwapServeSource? = nil) async -> CLILocalHTTPResponse
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
            await self.serveProviderAccountUsage(
                provider: normalizedProvider,
                context: context,
                fetch: fetch,
                claudeSwap: claudeSwap)
        })
    }

    /// `claudeSwap` stands in for the live claude-swap source (tests); nil reads it from the config.
    static func serveProviderAccountUsage(
        provider rawProvider: String?,
        context: ServeUsageContext,
        fetch: ProviderAccountUsageFetch? = nil,
        claudeSwap: ClaudeSwapServeSource? = nil) async -> CLILocalHTTPResponse
    {
        guard let providers = self.serveProviderAccountSelection(rawProvider: rawProvider, config: context.config)
        else {
            return self.forkServeError(status: .badRequest, message: "Unknown provider: \(rawProvider ?? "")")
        }
        let defaultContext: TokenAccountCLIContext
        do {
            defaultContext = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
                config: context.config,
                verbose: false)
        } catch {
            return self.forkServeError(status: .internalServerError, message: error.localizedDescription)
        }
        let command = self.serveUsageCommand(context: context)
        let fetch = fetch ?? self.liveProviderAccountFetch(defaultContext: defaultContext, command: command)
        // claude-swap's slots replace Claude's token accounts and its ambient fetch. They are known only after a
        // list read, so tagging starts from the last good read's and takes the new read's once it is in.
        let claudeSwap = providers.contains(.claude)
            ? claudeSwap ?? ClaudeSwapServeSource.live(
                config: context.config,
                providerTimeout: context.providerTimeout,
                weeklyWorkDays: command.weeklyWorkDays)
            : nil
        var accountsByProvider = Dictionary(
            providers.map { ($0, self.providerAccounts(for: $0, context: defaultContext)) },
            uniquingKeysWith: { first, _ in first })
        if let claudeSwap {
            accountsByProvider[.claude] = await claudeSwap.state.accounts(for: claudeSwap.executablePath)
        }
        let fetchAccounts = accountsByProvider

        // The coordinator slot is per provider and shared with upstream's plain /usage. The fingerprint differs, so
        // for one provider the coordinator runs the two routes' fetches one after the other, never at once, and
        // never hands one route's rows to the other.
        let output = await self.serveCollectUsageOutputs(
            providers: providers,
            configFingerprint: self.serveUsageOperationFingerprint(
                configFingerprint: context.configFingerprint,
                includeAllCodexAccounts: context.includeAllCodexAccounts) + ":provider-accounts=all",
            deadline: context.providerDeadline,
            operations: context.providerOperations)
        { provider in
            await ProviderInteractionContext.$current.withValue(.background) {
                if provider == .claude, let claudeSwap {
                    return await self.claudeSwapAccountOutput(claudeSwap) { await fetch(provider, nil) }
                }
                return await self.fetchProviderAccountOutputs(
                    provider: provider,
                    accounts: fetchAccounts[provider] ?? [],
                    fetch: fetch)
            }
        }

        if let claudeSwap {
            accountsByProvider[.claude] = await claudeSwap.state.accounts(for: claudeSwap.executablePath)
        }
        let rows = self.providerAccountRows(output.payload, accountsByProvider: accountsByProvider)
        let json = self.encodeJSON(rows, pretty: false) ?? "[]"
        // A stale row already carries its last good Quota and the error that made it stale. Without a cache key,
        // serve's last-good merge leaves it as is instead of swapping in an older copy without the error.
        return CLILocalHTTPResponse(
            status: .ok,
            body: Data(json.utf8),
            usageCacheKeys: rows.map { $0.stale ? nil : $0.row.cacheAccountKey })
    }

    /// Upstream's per-provider fetch, with the token-account selection the selector names.
    private static func liveProviderAccountFetch(
        defaultContext: TokenAccountCLIContext,
        command: UsageCommandContext) -> ProviderAccountUsageFetch
    {
        { provider, selector in
            let tokenContext: TokenAccountCLIContext
            switch selector {
            case nil:
                tokenContext = defaultContext
            case let .tokenIndex(index):
                // Upstream's index selection reads exactly that stored account's token.
                guard let selected = try? TokenAccountCLIContext(
                    selection: TokenAccountCLISelection(label: nil, index: index, allAccounts: false),
                    config: defaultContext.config,
                    verbose: false)
                else { return UsageCommandOutput() }
                tokenContext = selected
            case .claudeSwapSlot:
                // claude-swap rows come from one list read (CLIServeClaudeSwap.swift), never a per-slot fetch.
                return UsageCommandOutput()
            }
            return await self.fetchUsageOutputs(
                provider: provider,
                status: nil,
                tokenContext: tokenContext,
                command: command)
        }
    }

    /// The Provider Accounts `provider` shows as separate rows: its token accounts when it has two or more and the
    /// source mode in use reads them. Empty means the provider keeps upstream's single-account row.
    static func providerAccounts(
        for provider: UsageProvider,
        context: TokenAccountCLIContext) -> [ProviderAccount]
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
            ProviderAccount(
                fields: ProviderAccountRowFields(
                    source: .token,
                    id: account.id.uuidString.lowercased(),
                    label: Self.providerAccountLabel(account.label, index: index),
                    active: index == activeIndex),
                selector: .tokenIndex(index))
        }
    }

    static func providerAccountLabel(_ label: String, index: Int) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Account \(index + 1)" : trimmed
    }

    /// One fetch per Provider Account, in store order, each selecting only that account. A failing account adds its
    /// own error row and the others still fetch. Every row an account's fetch returns belongs to that account, so
    /// it is tagged with the account's id here, whatever cache key upstream gave it.
    ///
    /// All accounts share the provider's one budget: when it runs out, the coordinator answers with its single
    /// timeout row, and accounts that had already finished are lost with it (`providerAccountRows` turns that row
    /// into one per account, which the last-good merge then restores). A deadline per account is a follow-up.
    private static func fetchProviderAccountOutputs(
        provider: UsageProvider,
        accounts: [ProviderAccount],
        fetch: ProviderAccountUsageFetch) async -> UsageCommandOutput
    {
        guard !accounts.isEmpty else { return await fetch(provider, nil) }
        let refreshDelay = TokenAccountSupportCatalog.support(for: provider)?.minimumDelayBetweenAccountRefreshes
        var output = UsageCommandOutput()
        for (position, account) in accounts.enumerated() {
            if position > 0, let refreshDelay {
                do {
                    try await Task.sleep(for: refreshDelay)
                } catch {
                    return output
                }
            }
            var accountOutput = await fetch(provider, account.selector)
            accountOutput.payload = accountOutput.payload.map { $0.tagged(with: account.fields) }
            output.merge(accountOutput)
        }
        return output
    }

    /// Attaches each row's account fields, and makes tagging all or nothing per provider. A provider with Provider
    /// Accounts gets, for each account without a row, a copy of the provider's untagged error row (the coordinator's
    /// timeout row is the only untagged row it can return) tagged with that account; untagged rows are dropped.
    static func providerAccountRows(
        _ payload: [ProviderPayload],
        accountsByProvider: [UsageProvider: [ProviderAccount]]) -> [ProviderAccountRowPayload]
    {
        var rows: [ProviderAccountRowPayload] = []
        var expandedProviders: Set<String> = []
        for row in payload {
            guard let provider = row.usageProvider,
                  let accounts = accountsByProvider[provider],
                  !accounts.isEmpty
            else {
                rows.append(ProviderAccountRowPayload(row: row, account: nil))
                continue
            }
            if let account = accounts.first(where: { $0.fields.accountID == row.cacheAccountKey }) {
                rows.append(ProviderAccountRowPayload(row: row, account: account.fields))
                continue
            }
            guard row.error != nil, expandedProviders.insert(row.provider).inserted else { continue }
            let answered = Set(payload.filter { $0.provider == row.provider }.compactMap(\.cacheAccountKey))
            for account in accounts where !answered.contains(account.fields.accountID) {
                rows.append(ProviderAccountRowPayload(row: row.tagged(with: account.fields), account: account.fields))
            }
        }
        return rows
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
    /// A claude-swap slot; the id is the slot number claude-swap issued.
    case claudeSwap = "claude-swap"
}

/// How serve fetches one Provider Account. Source-specific and never sent; managed Codex homes add their own case.
enum ProviderAccountSelector: Equatable, Sendable {
    /// The account at this position in the provider's token-account store.
    case tokenIndex(Int)
    /// A claude-swap slot. All slots are read together; the slot is what an explicit switch targets.
    case claudeSwapSlot(Int)
}

/// One Provider Account serve shows as its own row: what the row says about it, and how to fetch it.
struct ProviderAccount: Equatable, Sendable {
    let fields: ProviderAccountRowFields
    let selector: ProviderAccountSelector
}

/// The fields one Provider Account adds to its `/usage` row, the same for every source.
struct ProviderAccountRowFields: Equatable, Sendable {
    let source: ProviderAccountSource
    let id: String
    let label: String
    let active: Bool
    /// `label` is a made-up fallback ("Account N", "email · Account N"), not a name the user chose or the account's
    /// email. Sent as `accountLabelIsDefault: true` (same field and meaning as #177).
    var labelIsDefault = false

    /// `<source>:<opaque id>`, stable across refreshes, renames and reorders. Serve also makes it the row's cache
    /// key, so the per-account last-good merge restores each account on its own.
    var accountID: String {
        "\(self.source.rawValue):\(self.id)"
    }
}

/// A `/usage` row: upstream's `ProviderPayload` keys unchanged, then the Provider Account keys when the row is one
/// of several accounts. Without an account it encodes exactly as the bare `ProviderPayload`.
struct ProviderAccountRowPayload: Encodable {
    let row: ProviderPayload
    let account: ProviderAccountRowFields?

    /// When the Quota this row shows was fetched: its usage snapshot's time. Absent on an error row, which shows no
    /// Quota of its own.
    var updatedAt: Date? {
        self.row.usage?.updatedAt
    }

    /// The Quota shown is an older one served in place of a current one: claude-swap's last good rows after a
    /// failed read, a slot's source-declared last-known usage, or an old statusLine capture.
    var stale: Bool {
        self.account != nil && [ClaudeSwapServeSource.staleSource, ClaudeStatusLineFeed.staleSourceLabel]
            .contains(self.row.source)
    }

    private enum CodingKeys: String, CodingKey {
        case accountId
        case accountSource
        case accountLabel
        case active
        case updatedAt
        case stale
        case accountLabelIsDefault
    }

    func encode(to encoder: any Encoder) throws {
        try self.row.encode(to: encoder)
        guard let account else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(account.accountID, forKey: .accountId)
        try container.encode(account.source, forKey: .accountSource)
        try container.encode(account.label, forKey: .accountLabel)
        if account.labelIsDefault {
            try container.encode(true, forKey: .accountLabelIsDefault)
        }
        try container.encode(account.active, forKey: .active)
        try container.encodeIfPresent(self.updatedAt, forKey: .updatedAt)
        if self.stale {
            try container.encode(true, forKey: .stale)
        }
    }
}

extension ProviderPayload {
    fileprivate var usageProvider: UsageProvider? {
        UsageProvider(rawValue: self.provider)
    }

    /// This row as `account`'s: its label, and its id as the cache key. Everything else is unchanged.
    fileprivate func tagged(with account: ProviderAccountRowFields) -> ProviderPayload {
        ProviderPayload(
            providerID: self.provider,
            account: account.label,
            cacheAccountKey: account.accountID,
            version: self.version,
            source: self.source,
            status: self.status,
            usage: self.usage,
            credits: self.credits,
            antigravityPlanInfo: self.antigravityPlanInfo,
            openaiDashboard: self.openaiDashboard,
            error: self.error,
            diagnostic: self.diagnostic,
            pace: self.pace)
    }
}
