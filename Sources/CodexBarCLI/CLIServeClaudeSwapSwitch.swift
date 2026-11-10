import CodexBarCore
import Foundation

// MARK: - Switching the active Claude account through claude-swap (#171)

/// `POST /accounts/switch` with `{"provider": "claude", "accountId": "claude-swap:<slot>"}` makes that claude-swap slot
/// Claude Code's active account, following the Phase 2 explicit activation contract in
/// `docs/claude-multi-account-and-status-items.md`:
///
/// - The route goes through `refuseUnlessMutatingForkRequestAllowed` (CLIServeActionGuard.swift) before it reads its
///   body, and takes only an `application/json` body naming one account.
/// - The slot must be in the account list serve reads right then, with `canSwitch` (an inactive slot whose credential
///   claude-swap can activate). Anything else is refused before any command runs.
/// - The only command is the reader's fixed argument array `cswap --switch-to <slot> --json`, never a shell, with the
///   slot taken from that list. Its result must be schema v1 and name the requested slot; anything else is an error,
///   and no row ever comes from switch output.
/// - Transactions run one at a time (`ClaudeSwapSwitchQueue`), and none is cancelled once started: a client that goes
///   away or times out doesn't stop it, and claude-swap reaches its natural exit.
/// - After the command ran, whatever it answered, serve drops its cached Claude responses and reads the account list
///   again, still inside the transaction. That list read is the account list and, with claude-swap on, Claude's Quota;
///   it alone says which account is active now. When it fails, the last good rows stay, marked stale.
enum ClaudeSwapSwitchRoute {
    static let path = "/accounts/switch"
}

struct ClaudeSwapSwitchBody: Decodable {
    let provider: String
    let accountId: String
}

/// What the switch route answers on success. Never an email, label or credential.
struct ClaudeSwapSwitchPayload: Encodable, Equatable {
    let provider: String
    /// The account the switch targeted.
    let accountId: String
    /// claude-swap's own `switched` flag (false when the slot was already active by the time it ran).
    let switched: Bool
    /// The active account in the list read after the switch; nil when that read failed or no slot is active.
    let activeAccountId: String?
    /// Why the list read after the switch failed; the last good rows then stand in, marked stale.
    let refreshError: String?
}

/// A refused or failed switch: its HTTP status and a message that never quotes the request body.
enum ClaudeSwapSwitchError: Error, Equatable {
    case invalidBody
    case unknownProvider
    case notEnabled
    case unknownAccount
    case notSwitchable
    case listUnavailable(String)
    case switchFailed(String)
    case configUnreadable

    var status: CLIHTTPStatus {
        switch self {
        case .invalidBody, .unknownProvider: .badRequest
        case .unknownAccount: .notFound
        case .notEnabled, .notSwitchable: .conflict
        case .listUnavailable, .switchFailed: .badGateway
        case .configUnreadable: .internalServerError
        }
    }

    var message: String {
        switch self {
        case .invalidBody: "Expected a JSON body."
        case .unknownProvider: "Only Claude accounts can be switched here."
        case .notEnabled: "claude-swap isn't enabled."
        case .unknownAccount: "No such account."
        case .notSwitchable: "This account can't be switched to."
        case let .listUnavailable(detail): "Couldn't read claude-swap's accounts: \(detail)"
        case let .switchFailed(detail): ClaudeSwapAccountProjection.displayError(
                accountError: nil,
                adapterError: nil,
                switchError: detail) ?? detail
        case .configUnreadable: "Couldn't read the config file."
        }
    }
}

/// Runs switch transactions one at a time, in arrival order. Each runs in a detached task of its own, so a caller
/// that goes away (a closed connection, a timed-out request) cancels nothing: once started, a transaction reaches
/// its end, and the next one waits for it.
actor ClaudeSwapSwitchQueue {
    static let shared = ClaudeSwapSwitchQueue()

    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ transaction: @escaping @Sendable () async -> T) async -> T {
        let previous = self.tail
        let task = Task.detached {
            await previous?.value
            return await transaction()
        }
        self.tail = Task.detached { _ = await task.value }
        return await task.value
    }
}

extension CodexBarCLI {
    /// Runs `cswap --switch-to <slot> --json` through the reader; tests pass the same reader over a fake `cswap`.
    typealias ClaudeSwapSwitcher = @Sendable (_ executablePath: String, _ slot: Int) async throws
        -> ClaudeSwapAccountSwitchResult
    /// The claude-swap source for a config, or nil when claude-swap is off or its executable is missing.
    typealias ClaudeSwapSourceResolver = @Sendable (_ snapshot: CLIServeConfigSnapshot) async -> ClaudeSwapServeSource?

    static func isClaudeSwapSwitchRequest(_ request: CLILocalHTTPRequest) -> Bool {
        request.path == ClaudeSwapSwitchRoute.path
    }

    static func serveClaudeSwapSwitchRoute(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime,
        resolveSource: ClaudeSwapSourceResolver? = nil,
        switcher: @escaping ClaudeSwapSwitcher = { path, slot in
            try await ClaudeSwapAccountReader.switchAccount(executablePath: path, accountNumber: slot)
        },
        queue: ClaudeSwapSwitchQueue = .shared) async -> CLILocalHTTPResponse
    {
        guard request.method.uppercased() == "POST" else {
            return self.forkServeError(status: .methodNotAllowed, message: "method not allowed")
        }
        if let refusal = self.refuseUnlessMutatingForkRequestAllowed(request, runtime: runtime) {
            return refusal
        }
        let result = await self.claudeSwapSwitch(
            request,
            runtime: runtime,
            resolveSource: resolveSource ?? { snapshot in
                await self.liveClaudeSwapSource(snapshot: snapshot, runtime: runtime)
            },
            switcher: switcher,
            queue: queue)
        switch result {
        case let .success(payload):
            return self.addingNoStore(self.forkServeJSON(payload))
        case let .failure(error):
            return self.addingNoStore(self.forkServeError(status: error.status, message: error.message))
        }
    }

    private static func claudeSwapSwitch(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime,
        resolveSource: ClaudeSwapSourceResolver,
        switcher: @escaping ClaudeSwapSwitcher,
        queue: ClaudeSwapSwitchQueue) async -> Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>
    {
        let mediaType = request.forkFields.contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        // The decoder's own error can quote the body, so it is never passed on.
        guard mediaType == "application/json",
              let body = try? JSONDecoder().decode(ClaudeSwapSwitchBody.self, from: request.body)
        else { return .failure(.invalidBody) }
        guard UsageProvider(rawValue: body.provider) == ClaudeSwapServeSource.provider else {
            return .failure(.unknownProvider)
        }
        guard let slot = self.claudeSwapSlot(fromAccountID: body.accountId) else {
            return .failure(.unknownAccount)
        }
        let snapshot: CLIServeConfigSnapshot
        do {
            snapshot = try self.loadServeConfigSnapshot(configStore: runtime.configStore)
        } catch {
            return .failure(.configUnreadable)
        }
        guard let source = await resolveSource(snapshot) else { return .failure(.notEnabled) }
        let cache = runtime.cache
        return await queue.run {
            await self.claudeSwapSwitchTransaction(
                slot: slot,
                source: source,
                switcher: switcher,
                invalidate: { await cache.forkInvalidateResponses(where: Self.isClaudeResponseCacheKey) })
        }
    }

    /// One switch, start to finish. Runs inside the queue: validate against a fresh list read, run the command,
    /// drop Claude's cached responses, read the list again.
    static func claudeSwapSwitchTransaction(
        slot: Int,
        source: ClaudeSwapServeSource,
        switcher: ClaudeSwapSwitcher,
        invalidate: @Sendable () async -> Void) async -> Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>
    {
        let accountID = "\(ProviderAccountSource.claudeSwap.rawValue):\(slot)"
        let current = await source.fetch()
        if let adapterError = current.adapterError {
            return .failure(.listUnavailable(adapterError))
        }
        guard let row = current.rows.first(where: { $0.account.fields.accountID == accountID }) else {
            return .failure(.unknownAccount)
        }
        // The slot handed to cswap is the one this list read issued, never the request's text.
        guard row.account.fields.canSwitch,
              case let .claudeSwapSlot(target) = row.account.selector,
              target == slot
        else { return .failure(.notSwitchable) }

        var switched = false
        var switchError: String?
        do {
            switched = try await switcher(source.executablePath, target).switched
        } catch {
            let detail = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
            switchError = detail.isEmpty ? "claude-swap switch failed." : detail
        }
        // Whatever the command answered, Claude Code's account may have changed: nothing cached may outlive it, and
        // only a fresh list read says which account is active now.
        await invalidate()
        let refreshed = await source.fetch()
        if let switchError {
            return .failure(.switchFailed(switchError))
        }
        let active = refreshed.adapterError == nil
            ? refreshed.rows.first(where: \.account.fields.active)?.account.fields.accountID
            : nil
        return .success(ClaudeSwapSwitchPayload(
            provider: ClaudeSwapServeSource.provider.rawValue,
            accountId: accountID,
            switched: switched,
            activeAccountId: active,
            refreshError: refreshed.adapterError))
    }

    /// The slot in `claude-swap:<slot>`, written exactly as serve writes it (a positive decimal, no sign or padding).
    static func claudeSwapSlot(fromAccountID accountID: String) -> Int? {
        let prefix = "\(ProviderAccountSource.claudeSwap.rawValue):"
        guard accountID.hasPrefix(prefix),
              let slot = Int(accountID.dropFirst(prefix.count)),
              slot > 0,
              accountID == "\(prefix)\(slot)"
        else { return nil }
        return slot
    }

    /// Cache keys whose response holds a Claude row: `/usage` (plain and `accounts=all`) and the dashboard snapshot,
    /// for every provider (`default`) or a list naming Claude. Keys are `<kind>:<providers>:...`
    /// (`serveOperationKey`, `serveCacheKey`).
    static func isClaudeResponseCacheKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "usage" || parts[0].hasPrefix("dashboard-") else { return false }
        let providers = parts[1]
        return providers == "default" ||
            providers.split(separator: ",").contains { $0 == ClaudeSwapServeSource.provider.rawValue }
    }

    private static func liveClaudeSwapSource(
        snapshot: CLIServeConfigSnapshot,
        runtime: ServeRuntime) async -> ClaudeSwapServeSource?
    {
        let context = ServeUsageContext(
            config: snapshot.config,
            configFingerprint: snapshot.cacheToken,
            refreshInterval: runtime.refreshInterval,
            providerTimeout: self.serveProviderTimeout(requestTimeout: runtime.requestTimeout),
            providerDeadline: nil,
            providerOperations: runtime.providerOperations)
        return await ClaudeSwapServeSource.live(
            context: context,
            weeklyWorkDays: self.serveUsageCommand(context: context).weeklyWorkDays)
    }
}
