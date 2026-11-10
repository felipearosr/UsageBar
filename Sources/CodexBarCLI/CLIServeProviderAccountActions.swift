import CodexBarCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Provider Account actions on serve

/// serve's account action routes, answered through `forkServeResponse`:
/// - `GET /accounts/kinds`: per provider, the kind of Provider Account it can add (`ProviderAccountKind`) and
///   whether its accounts can be renamed and removed here.
/// - `POST /accounts/add`: store a labelled key or cookie as a new token account (`key` kind).
/// - `POST /accounts/rename`, `POST /accounts/remove`: change or delete one account, named by the `accountId` its
///   `/usage?accounts=all` row carries.
///
/// The POST routes change the config, so they go through `refuseUnlessMutatingForkRequestAllowed`
/// (CLIServeActionGuard.swift: data-route bearer, action token, no `Origin`) and take only an `application/json`
/// body. Writes go to the token-account store (the config's `tokenAccounts`) under the config file's write lock,
/// with the same rules as the macOS app's Settings (`SettingsStore+TokenAccounts.swift`). No response, error or log
/// line carries a token.
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
    /// What "Add account…" adds; absent when this provider's accounts can't be added here.
    let kind: ProviderAccountKind?
    /// The provider's hint for the key field (`key` only), e.g. "Paste API key…".
    let placeholder: String?
    /// Whether this provider's account rows can be renamed and removed through serve.
    let rename: Bool
    let remove: Bool
    /// The provider has no token accounts yet and `add` has no config key to keep, so the first account takes over
    /// from whatever credential UsageBar uses now (a cookie, an environment key, a CLI login); clients warn first.
    let replacesCurrent: Bool
}

struct ProviderAccountKindsPayload: Encodable, Equatable {
    /// Keyed by provider id (a `/usage` row's `provider`); providers without multi-account support are left out.
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
        case .storeFailed: "Couldn't read or save the config file."
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

    /// The kind of Provider Account `provider` can add, or nil when it can't add one here.
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

    /// Whether serve can remove `provider`'s token accounts.
    static func canRemoveProviderAccount(of provider: UsageProvider) -> Bool {
        // Provider-specific by design: the macOS app also clears Antigravity's shared OAuth cache on removal.
        provider != .antigravity
    }

    /// Every provider with token-account support, with what can be done to its accounts here. `config` decides
    /// `replacesCurrent`.
    static func providerAccountKinds(config: CodexBarConfig?) -> ProviderAccountKindsPayload {
        var providers: [String: ProviderAccountKindPayload] = [:]
        for provider in UsageProvider.allCases {
            guard let support = TokenAccountSupportCatalog.support(for: provider) else { continue }
            let kind = self.addableProviderAccountKind(for: provider)
            providers[provider.rawValue] = ProviderAccountKindPayload(
                kind: kind,
                placeholder: kind == .key ? support.placeholder : nil,
                rename: true,
                remove: self.canRemoveProviderAccount(of: provider),
                replacesCurrent: kind == .key && ProviderTokenAccountEditor.firstAddReplacesCurrentCredential(
                    provider: provider,
                    entry: config?.providerConfig(for: provider.instanceID)))
        }
        return ProviderAccountKindsPayload(providers: providers)
    }

    static func serveProviderAccountRoute(
        _ route: CLIServeProviderAccountRoute,
        request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse
    {
        if route == .kinds {
            guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
                return self.serveUnauthorizedResponse()
            }
            let config = try? runtime.configStore.load()
            return self.addingNoStore(self.forkServeJSON(self.providerAccountKinds(config: config)))
        }
        if let refusal = self.refuseUnlessMutatingForkRequestAllowed(request, runtime: runtime) {
            return refusal
        }
        let result: Result<ProviderAccountActionPayload, ProviderAccountActionError>
        do {
            let store = runtime.configStore
            switch route {
            case .kinds:
                return self.forkServeError(status: .methodNotAllowed, message: "method not allowed")
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
        let (account, count) = try await self
            .editingConfig(store: store, provider: provider, createIfMissing: true) { config in
                ProviderTokenAccountEditor.add(
                    to: &config,
                    provider: provider,
                    label: label,
                    token: token,
                    addedAt: now.timeIntervalSince1970)
            }
        self.logTokenAccountChange("Token account added", provider: provider, count: count)
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
        let (account, count) = try await self
            .editingConfig(store: store, provider: provider, createIfMissing: false) { config in
                try ProviderTokenAccountEditor.rename(in: &config, provider: provider, id: id, label: label)
            }
        self.logTokenAccountChange("Token account updated", provider: provider, count: count)
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
        guard self.canRemoveProviderAccount(of: provider) else { throw ProviderAccountActionError.removeNotSupported }
        let (_, count) = try await self
            .editingConfig(store: store, provider: provider, createIfMissing: false) { config in
                try ProviderTokenAccountEditor.remove(from: &config, provider: provider, id: id)
            }
        self.logTokenAccountChange("Token account removed", provider: provider, count: count)
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

    /// Reads, edits and writes the config while holding the config file's write lock, so a concurrent writer (the
    /// extension, a `codexbar config` call, another request) is never lost, including when the file doesn't exist
    /// yet. Returns `edit`'s value and the provider's token-account count afterwards (for the log line).
    /// A missing config is created from the default only when `createIfMissing`; otherwise there is no account to
    /// act on. A config that can't be read is `storeFailed`, never an unknown account.
    private static func editingConfig<Value>(
        store: CodexBarConfigStore,
        provider: UsageProvider,
        createIfMissing: Bool,
        _ edit: (inout CodexBarConfig) throws -> Value) async throws -> (Value, Int)
    {
        let descriptor = try await self.lockConfigFile(store)
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let loaded: CodexBarConfig?
        do {
            loaded = try store.load()
        } catch {
            throw ProviderAccountActionError.storeFailed
        }
        guard var config = loaded ?? (createIfMissing ? CodexBarConfig.makeDefault() : nil) else {
            throw ProviderAccountActionError.unknownAccount
        }
        let value = try edit(&config)
        do {
            try CredentialFileWriter.writePrivate(store.encodedData(for: config), to: store.fileURL)
        } catch {
            throw ProviderAccountActionError.storeFailed
        }
        return (value, config.providerConfig(for: provider.instanceID)?.tokenAccounts?.accounts.count ?? 0)
    }

    /// The same advisory lock `CodexBarConfigStore` takes for its writes (`<config>.lock`, `flock` exclusive), so
    /// serve's edits and the store's own writes exclude each other. Waits up to two seconds, then `storeBusy`.
    private static func lockConfigFile(_ store: CodexBarConfigStore) async throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw ProviderAccountActionError.storeFailed
        }
        let descriptor = open(
            store.fileURL.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            0o600)
        guard descriptor >= 0 else { throw ProviderAccountActionError.storeFailed }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == geteuid()
        else {
            close(descriptor)
            throw ProviderAccountActionError.storeFailed
        }
        for _ in 0..<40 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            guard errno == EWOULDBLOCK || errno == EINTR else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        close(descriptor)
        throw ProviderAccountActionError.storeBusy
    }

    private static func logTokenAccountChange(_ message: String, provider: UsageProvider, count: Int) {
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
///
/// The app also calls `applyTokenAccountCookieSource` after each edit, which sets the provider's cookie source to
/// manual for `requiresManualCookieSource` providers. That is an AppKit settings write; it is skipped here because
/// the shared resolver already forces the manual source whenever such a provider has a token account
/// (`ProviderCookieSettingsResolver`), so serve's fetches read the account's cookie either way.
enum ProviderTokenAccountEditor {
    /// The first account's label when an existing config `apiKey` becomes a token account.
    static let migratedAPIKeyLabel = "Account 1"

    /// Appends the account under a new UUID and makes it the active one, as the app's Add does.
    ///
    /// The first add for a provider that has a config `apiKey` and no token accounts keeps that key: it moves into
    /// the first token account ("Account 1", and out of `apiKey`) before the new one is added, so the card shows
    /// both and removing accounts never brings a forgotten `apiKey` back. Only when that `apiKey` is exactly what
    /// the provider's token accounts replace (`migratableAPIKey`).
    static func add(
        to config: inout CodexBarConfig,
        provider: UsageProvider,
        label: String?,
        token: String,
        addedAt: TimeInterval) -> ProviderAccountRowFields
    {
        var entry = config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        let existing = entry.tokenAccounts
        var accounts = existing?.accounts ?? []
        if accounts.isEmpty, let apiKey = self.migratableAPIKey(provider: provider, entry: entry) {
            accounts.append(ProviderTokenAccount(
                id: UUID(),
                label: self.migratedAPIKeyLabel,
                token: apiKey,
                addedAt: addedAt,
                lastUsed: nil))
            entry.apiKey = nil
        }
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

    /// The config `apiKey` the first add keeps as a token account, or nil. Only when the provider projects that
    /// key into exactly the environment variable its token accounts inject, so the key and an account are the same
    /// kind of credential (not, say, Grok's API key next to its OAuth-token accounts, DeepSeek's unprojected key, or
    /// a Doubao access key).
    static func migratableAPIKey(provider: UsageProvider, entry: ProviderConfig?) -> String? {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              case let .environment(key) = support.injection,
              let entry,
              entry.tokenAccounts?.accounts.isEmpty ?? true,
              let apiKey = entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              ProviderConfigEnvironment.applyAPIKeyOverride(base: [:], provider: provider, config: entry)[key]?
                  .trimmingCharacters(in: .whitespacesAndNewlines) == apiKey
        else { return nil }
        return apiKey
    }

    /// Whether the first add takes over from whatever credential UsageBar uses now without keeping it: true for
    /// every first add that has no config key to migrate (a cookie, an environment key, a provider's own CLI login
    /// such as Grok's). False once the provider has token accounts.
    static func firstAddReplacesCurrentCredential(provider: UsageProvider, entry: ProviderConfig?) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil,
              entry?.tokenAccounts?.accounts.isEmpty ?? true
        else { return false }
        return self.migratableAPIKey(provider: provider, entry: entry) == nil
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
