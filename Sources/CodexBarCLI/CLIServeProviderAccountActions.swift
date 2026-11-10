import CodexBarCore
import Foundation

// MARK: - Provider Account actions on serve

/// serve's account action routes, answered through `forkServeResponse`:
/// - `GET /accounts/kinds`: which kind of Provider Account each provider can add (`ProviderAccountKind`).
/// - `POST /accounts/add`: store a labelled key or cookie as a new token account (`key` kind).
/// - `POST /accounts/rename`, `POST /accounts/remove`: change or delete one account, named by the `accountId` its
///   `/usage?accounts=all` row carries.
///
/// The POST routes take a JSON body and change the config, so on top of the data-route auth `/sync/push` uses they
/// refuse any request with an `Origin` header (a browser page, same-site or not) and any body that isn't
/// `application/json` (which a cross-site form can't send without a preflight). Writes go to the token-account store
/// (the config's `tokenAccounts`) under the config file's write lock, with the same rules as the macOS app's
/// Settings (`SettingsStore+TokenAccounts.swift`). No response, error or log line carries a token.
enum CLIServeProviderAccountRoute: Equatable {
    case kinds
    case add
    case rename
    case remove

    /// nil for a path that isn't an account action; throws for one of them with the wrong method.
    static func route(method: String, path: String) throws -> CLIServeProviderAccountRoute? {
        let route: CLIServeProviderAccountRoute
        switch path {
        case "/accounts/kinds": route = .kinds
        case "/accounts/add": route = .add
        case "/accounts/rename": route = .rename
        case "/accounts/remove": route = .remove
        default: return nil
        }
        let expected = route == .kinds ? "GET" : "POST"
        guard method.uppercased() == expected else { throw CLIServeRouteError.methodNotAllowed }
        return route
    }
}

/// How a provider adds a Provider Account. Clients dispatch on it: `key` opens a label-and-key form; the
/// interactive kinds run a `codexbar` helper in a terminal.
enum ProviderAccountKind: String, Encodable, Sendable {
    /// A labelled API key or cookie header in the token-account store.
    case key
    /// The provider's own CLI login, run in a home directory UsageBar manages (Codex, #169).
    case cliLogin = "cli-login"
    /// A Claude subscription saved through claude-swap (#172).
    case claudeSwap = "claude-swap"
}

/// One provider's entry in `GET /accounts/kinds`.
struct ProviderAccountKindPayload: Encodable, Equatable {
    let kind: ProviderAccountKind
    /// The provider's hint for the key field (`key` only), e.g. "Paste API key…".
    let placeholder: String?
}

struct ProviderAccountKindsPayload: Encodable, Equatable {
    /// Keyed by provider id (a `/usage` row's `provider`); providers that can't add an account are left out.
    let providers: [String: ProviderAccountKindPayload]
}

/// A failed account action: its HTTP status and a message that never quotes the request body.
enum ProviderAccountActionError: Error, Equatable {
    case invalidBody
    case unknownProvider
    case kindNotSupported
    case missingToken
    case missingLabel
    case labelTooLong
    case unknownAccount
    case removeNotSupported
    case storeBusy
    case storeFailed

    var status: CLIHTTPStatus {
        switch self {
        case .invalidBody, .unknownProvider, .kindNotSupported, .missingToken, .missingLabel, .labelTooLong:
            .badRequest
        case .unknownAccount:
            .notFound
        case .removeNotSupported, .storeBusy:
            .conflict
        case .storeFailed:
            .internalServerError
        }
    }

    var message: String {
        switch self {
        case .invalidBody: "Expected a JSON body."
        case .unknownProvider: "Unknown provider."
        case .kindNotSupported: "This provider can't add key accounts."
        case .missingToken: "A key is required."
        case .missingLabel: "A label is required."
        case .labelTooLong: "The label is too long."
        case .unknownAccount: "No such account."
        case .removeNotSupported: "This account can't be removed here."
        case .storeBusy: "The config file is busy. Try again."
        case .storeFailed: "Couldn't save the config file."
        }
    }
}

/// What an add or rename answers: the account as its `/usage` row will show it. Never the token.
struct ProviderAccountActionPayload: Encodable, Equatable {
    let provider: String
    let accountId: String
    let accountLabel: String?
    let active: Bool?
    let removed: Bool?
}

extension CodexBarCLI {
    static let providerAccountLabelLimit = 100

    /// The kind of Provider Account `provider` can add, or nil when it has no multi-account support here.
    static func addableProviderAccountKind(for provider: UsageProvider) -> ProviderAccountKind? {
        switch provider {
        // Provider-specific by design: these accounts come from a login flow, not a pasted key. Codex adds managed
        // homes (cli-login, #169) and Claude adds claude-swap slots (#172). Antigravity's token accounts are OAuth
        // credentials from its own sign-in, and removing one must also clear its shared credential cache.
        case .codex, .claude, .antigravity:
            nil
        default:
            TokenAccountSupportCatalog.support(for: provider) == nil ? nil : .key
        }
    }

    static func providerAccountKinds() -> ProviderAccountKindsPayload {
        var providers: [String: ProviderAccountKindPayload] = [:]
        for provider in UsageProvider.allCases {
            guard let kind = self.addableProviderAccountKind(for: provider) else { continue }
            let placeholder = kind == .key ? TokenAccountSupportCatalog.support(for: provider)?.placeholder : nil
            providers[provider.rawValue] = ProviderAccountKindPayload(kind: kind, placeholder: placeholder)
        }
        return ProviderAccountKindsPayload(providers: providers)
    }

    static func serveProviderAccountRoute(
        _ route: CLIServeProviderAccountRoute,
        request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse
    {
        guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
            return self.serveUnauthorizedResponse()
        }
        if route == .kinds {
            return self.addingNoStore(self.forkServeJSON(self.providerAccountKinds()))
        }
        // A browser sends Origin on every POST; UsageBar's clients (the extension, the CLI, curl) send none.
        guard request.forkFields.origin == nil else {
            return self.addingNoStore(self.forkServeError(status: .forbidden, message: "forbidden origin"))
        }
        let result: Result<ProviderAccountActionPayload, ProviderAccountActionError>
        do {
            let store = runtime.configStore
            switch route {
            case .kinds:
                return self.addingNoStore(self.forkServeJSON(self.providerAccountKinds()))
            case .add:
                let body = try self.decodeProviderAccountBody(AddKeyAccountBody.self, request: request)
                result = try await .success(self.addKeyAccount(body, store: store))
            case .rename:
                let body = try self.decodeProviderAccountBody(RenameAccountBody.self, request: request)
                result = try await .success(self.renameAccount(body, store: store))
            case .remove:
                let body = try self.decodeProviderAccountBody(RemoveAccountBody.self, request: request)
                result = try await .success(self.removeAccount(body, store: store))
            }
        } catch let error as ProviderAccountActionError {
            result = .failure(error)
        } catch {
            result = .failure(.storeFailed)
        }
        switch result {
        case let .success(payload):
            return self.addingNoStore(self.forkServeJSON(payload))
        case let .failure(error):
            return self.addingNoStore(self.forkServeError(status: error.status, message: error.message))
        }
    }

    private static func decodeProviderAccountBody<Body: Decodable>(
        _: Body.Type,
        request: CLILocalHTTPRequest) throws -> Body
    {
        let mediaType = request.forkFields.contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard mediaType == "application/json" else { throw ProviderAccountActionError.invalidBody }
        // The decoder's own error can quote the body, so it is never passed on.
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            throw ProviderAccountActionError.invalidBody
        }
        return body
    }

    // MARK: Writes

    static func addKeyAccount(
        _ body: AddKeyAccountBody,
        store: CodexBarConfigStore,
        now: Date = Date()) async throws -> ProviderAccountActionPayload
    {
        guard let provider = UsageProvider(rawValue: body.provider) else {
            throw ProviderAccountActionError.unknownProvider
        }
        guard self.addableProviderAccountKind(for: provider) == .key else {
            throw ProviderAccountActionError.kindNotSupported
        }
        let token = body.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderAccountActionError.missingToken }
        let label = try self.providerAccountLabel(body.label, required: false)
        if try store.load() == nil {
            do {
                _ = try store.loadOrCreateDefault()
            } catch {
                throw ProviderAccountActionError.storeFailed
            }
        }
        let account = try await self.updatingTokenAccounts(store: store) { config in
            ProviderTokenAccountEditor.add(
                to: &config,
                provider: provider,
                label: label,
                token: token,
                addedAt: now.timeIntervalSince1970)
        }
        self.logTokenAccountChange("Token account added", provider: provider, store: store)
        return ProviderAccountActionPayload(
            provider: provider.rawValue,
            accountId: account.accountID,
            accountLabel: account.label,
            active: account.active,
            removed: nil)
    }

    static func renameAccount(
        _ body: RenameAccountBody,
        store: CodexBarConfigStore) async throws -> ProviderAccountActionPayload
    {
        let (provider, id) = try self.tokenAccountTarget(provider: body.provider, accountID: body.accountId)
        guard let label = try self.providerAccountLabel(body.label, required: true) else {
            throw ProviderAccountActionError.missingLabel
        }
        let account = try await self.updatingTokenAccounts(store: store) { config in
            try ProviderTokenAccountEditor.rename(in: &config, provider: provider, id: id, label: label)
        }
        self.logTokenAccountChange("Token account updated", provider: provider, store: store)
        return ProviderAccountActionPayload(
            provider: provider.rawValue,
            accountId: account.accountID,
            accountLabel: account.label,
            active: account.active,
            removed: nil)
    }

    static func removeAccount(
        _ body: RemoveAccountBody,
        store: CodexBarConfigStore) async throws -> ProviderAccountActionPayload
    {
        let (provider, id) = try self.tokenAccountTarget(provider: body.provider, accountID: body.accountId)
        // Provider-specific by design: the macOS app also clears Antigravity's shared OAuth cache on removal.
        guard provider != .antigravity else { throw ProviderAccountActionError.removeNotSupported }
        try await self.updatingTokenAccounts(store: store) { config in
            try ProviderTokenAccountEditor.remove(from: &config, provider: provider, id: id)
        }
        self.logTokenAccountChange("Token account removed", provider: provider, store: store)
        return ProviderAccountActionPayload(
            provider: provider.rawValue,
            accountId: "\(ProviderAccountSource.token.rawValue):\(id.uuidString.lowercased())",
            accountLabel: nil,
            active: nil,
            removed: true)
    }

    /// The provider and token-account UUID an action names. Only `token:` accounts can be renamed or removed;
    /// any other id is unknown here.
    private static func tokenAccountTarget(provider rawProvider: String, accountID: String) throws
        -> (UsageProvider, UUID)
    {
        guard let provider = UsageProvider(rawValue: rawProvider) else {
            throw ProviderAccountActionError.unknownProvider
        }
        let parts = accountID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              ProviderAccountSource(rawValue: parts[0]) == .token,
              let id = UUID(uuidString: parts[1])
        else { throw ProviderAccountActionError.unknownAccount }
        return (provider, id)
    }

    /// Trimmed; nil when blank and not `required` (the store then names it "Account N", as the app does).
    private static func providerAccountLabel(_ raw: String?, required: Bool) throws -> String? {
        let label = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else {
            if required { throw ProviderAccountActionError.missingLabel }
            return nil
        }
        guard label.count <= self.providerAccountLabelLimit else { throw ProviderAccountActionError.labelTooLong }
        return label
    }

    /// Runs `edit` on the config under the config file's write lock, so a concurrent writer (the extension, another
    /// `codexbar config` call) can't be lost. The store skips a locked file rather than wait, so this retries briefly.
    private static func updatingTokenAccounts<Value>(
        store: CodexBarConfigStore,
        _ edit: (inout CodexBarConfig) throws -> Value) async throws -> Value
    {
        guard (try? store.load()) != nil else { throw ProviderAccountActionError.unknownAccount }
        for _ in 0..<40 {
            var value: Value?
            do {
                try store.updateIfAvailable { config in
                    value = try edit(&config)
                    return true
                }
            } catch let error as ProviderAccountActionError {
                throw error
            } catch {
                throw ProviderAccountActionError.storeFailed
            }
            if let value { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw ProviderAccountActionError.storeBusy
    }

    private static func logTokenAccountChange(_ message: String, provider: UsageProvider, store: CodexBarConfigStore) {
        let count = (try? store.load())?.providerConfig(for: provider.instanceID)?.tokenAccounts?.accounts.count ?? 0
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            message,
            metadata: ["provider": provider.rawValue, "count": "\(count)"])
    }
}

struct AddKeyAccountBody: Decodable, Equatable {
    let provider: String
    let label: String?
    let token: String
}

struct RenameAccountBody: Decodable, Equatable {
    let provider: String
    let accountId: String
    let label: String
}

struct RemoveAccountBody: Decodable, Equatable {
    let provider: String
    let accountId: String
}

/// The token-account edits the macOS app's Settings make (`SettingsStore+TokenAccounts.swift`), on a config value so
/// serve can run them without the app: the same trimming, "Account N" fallback, active-account rules and
/// `clearsAPIKeyOnMutation`.
enum ProviderTokenAccountEditor {
    /// Appends the account under a new UUID and makes it the active one, as the app's Add does.
    static func add(
        to config: inout CodexBarConfig,
        provider: UsageProvider,
        label: String?,
        token: String,
        addedAt: TimeInterval) -> ProviderAccountRowFields
    {
        var entry = config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        let existing = entry.tokenAccounts
        let accounts = existing?.accounts ?? []
        let account = ProviderTokenAccount(
            id: UUID(),
            label: label ?? "Account \(accounts.count + 1)",
            token: token,
            addedAt: addedAt,
            lastUsed: nil)
        entry.tokenAccounts = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.clearAPIKeyIfNeeded(&entry, provider: provider)
        config.setProviderConfig(entry)
        return self.fields(account, active: true)
    }

    static func rename(
        in config: inout CodexBarConfig,
        provider: UsageProvider,
        id: UUID,
        label: String) throws -> ProviderAccountRowFields
    {
        guard var entry = config.providerConfig(for: provider.instanceID),
              let data = entry.tokenAccounts,
              let index = data.accounts.firstIndex(where: { $0.id == id })
        else { throw ProviderAccountActionError.unknownAccount }
        let old = data.accounts[index]
        let renamed = ProviderTokenAccount(
            id: old.id,
            label: label,
            token: old.token,
            addedAt: old.addedAt,
            lastUsed: old.lastUsed,
            externalIdentifier: old.externalIdentifier,
            usageScope: old.usageScope,
            organizationID: old.organizationID,
            workspaceID: old.workspaceID,
            seatCreditEntitlement: old.seatCreditEntitlement)
        var accounts = data.accounts
        accounts[index] = renamed
        let activeIndex = data.clampedActiveIndex()
        entry.tokenAccounts = ProviderTokenAccountData(
            version: data.version,
            accounts: accounts,
            activeIndex: activeIndex)
        self.clearAPIKeyIfNeeded(&entry, provider: provider)
        config.setProviderConfig(entry)
        return self.fields(renamed, active: index == activeIndex)
    }

    /// Removes the account. The active account stays active; removing the active one activates its neighbour, and
    /// removing the last one drops the provider's token accounts.
    static func remove(from config: inout CodexBarConfig, provider: UsageProvider, id: UUID) throws {
        guard var entry = config.providerConfig(for: provider.instanceID),
              let data = entry.tokenAccounts,
              let removedIndex = data.accounts.firstIndex(where: { $0.id == id })
        else { throw ProviderAccountActionError.unknownAccount }
        let activeID = data.accounts[data.clampedActiveIndex()].id
        let remaining = data.accounts.filter { $0.id != id }
        if remaining.isEmpty {
            entry.tokenAccounts = nil
        } else {
            let activeIndex = activeID != id ? remaining.firstIndex { $0.id == activeID } : nil
            entry.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: remaining,
                activeIndex: activeIndex ?? min(removedIndex, remaining.count - 1))
        }
        self.clearAPIKeyIfNeeded(&entry, provider: provider)
        config.setProviderConfig(entry)
    }

    private static func clearAPIKeyIfNeeded(_ entry: inout ProviderConfig, provider: UsageProvider) {
        if TokenAccountSupportCatalog.support(for: provider)?.clearsAPIKeyOnMutation == true {
            entry.apiKey = nil
        }
    }

    private static func fields(_ account: ProviderTokenAccount, active: Bool) -> ProviderAccountRowFields {
        ProviderAccountRowFields(
            source: .token,
            id: account.id.uuidString.lowercased(),
            label: account.label,
            active: active)
    }
}
