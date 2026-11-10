import CodexBarCore
import Foundation

// MARK: - Switching the active Claude account through claude-swap (#171)

/// `POST /accounts/switch` with `{"provider": "claude", "accountId": "claude-swap:<slot>"}` makes that claude-swap slot
/// Claude Code's active account, following the Phase 2 explicit activation contract in
/// `docs/claude-multi-account-and-status-items.md`:
///
/// - The route goes through `refuseUnlessMutatingForkRequestAllowed` (CLIServeActionGuard.swift) before it reads its
///   body, and takes only an `application/json` body naming one account.
/// - Transactions run one at a time (`ClaudeSwapSwitchQueue`), and none is cancelled once started: a client that goes
///   away or times out doesn't stop it, and claude-swap reaches its natural exit.
/// - Inside the transaction serve reads the config (claude-swap on, and which executable) and the account list again.
///   The slot must be in that list, with `canSwitch` (an inactive slot whose credential claude-swap can activate).
///   Anything else is refused before any command runs.
/// - The only command is the reader's fixed argument array `cswap --switch-to <slot> --json`, never a shell, with the
///   slot taken from that list. Its result must be schema v1 and name the requested slot; anything else is an error,
///   and no row ever comes from switch output.
/// - Once the command exits, whatever it answered, the switch generation moves on (so `/usage?accounts=all` gets new
///   cache and merge keys, and nothing a fetch from before the switch commits can answer it), serve drops its cached
///   Claude responses, and the answer goes out: a switch error is known before any refresh.
/// - Still inside the transaction, serve then reads the account list again, when claude-swap still runs the same
///   executable (a changed configuration discards the refresh), and drops its cached Claude responses once more. That
///   list read is the account list and, with claude-swap on, Claude's Quota; it alone says which account is active now.
///   When it fails, the last good rows stay, marked stale.
enum ClaudeSwapSwitchRoute {
    static let path = "/accounts/switch"
}

struct ClaudeSwapSwitchBody: Decodable {
    let provider: String
    let accountId: String
}

/// What the switch route answers on success, right after the command exits. Never an email, label or credential.
/// Which account is active now is for the next `/usage?accounts=all` to say.
struct ClaudeSwapSwitchPayload: Encodable, Equatable {
    let provider: String
    /// The account the switch targeted.
    let accountId: String
    /// claude-swap's own `switched` flag (false when the slot was already active by the time it ran).
    let switched: Bool
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
///
/// Shutdown: serve stopping mid-switch ends this process and the tasks with it; nothing here waits for them or
/// persists anything. The `cswap` child is not killed by this queue and may still finish its own transaction. A new
/// serve keeps nothing from the old one (no cache, no generation) and reads the account list afresh, so it never
/// shows a pre-switch row as current.
actor ClaudeSwapSwitchQueue {
    static let shared = ClaudeSwapSwitchQueue()

    private var tail: Task<Void, Never>?

    /// Queues `transaction` behind every earlier one and returns without waiting for it.
    @discardableResult
    func submit(_ transaction: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = self.tail
        let task = Task.detached {
            await previous?.value
            await transaction()
        }
        self.tail = task
        return task
    }

    /// Returns once every transaction queued so far (and any queued meanwhile) has finished.
    func drain() async {
        while let tail = self.tail {
            await tail.value
            if self.tail == tail { return }
        }
    }
}

/// Moves on each time a switch command exits. `/usage?accounts=all` puts it in its cache and merge keys whenever its
/// selection includes Claude, so a response (or per-account last-good row) from before a switch never answers or
/// patches a request made after it, even when a fetch that started before the switch commits late.
final class ClaudeSwapSwitchGeneration: @unchecked Sendable {
    static let shared = ClaudeSwapSwitchGeneration()

    private let lock = NSLock()
    private var value = 0

    var current: Int {
        self.lock.withLock { self.value }
    }

    func advance() {
        self.lock.withLock { self.value += 1 }
    }

    /// `fingerprint`, with the generation when the request's providers include Claude.
    func fingerprint(_ fingerprint: String, providers: [UsageProvider]?) -> String {
        guard providers?.contains(ClaudeSwapServeSource.provider) == true else { return fingerprint }
        return "\(fingerprint):claude-switch-\(self.current)"
    }
}

/// One queued switch: the slot, how to resolve claude-swap from the config as it is now, the command, the generation
/// to move on and how to drop Claude's cached responses.
struct ClaudeSwapSwitchJob: Sendable {
    let slot: Int
    let currentSource: CodexBarCLI.ClaudeSwapCurrentSource
    let switcher: CodexBarCLI.ClaudeSwapSwitcher
    let generation: ClaudeSwapSwitchGeneration
    let invalidate: @Sendable () async -> Void
}

extension CodexBarCLI {
    /// Runs `cswap --switch-to <slot> --json` through the reader; tests pass the same reader over a fake `cswap`.
    typealias ClaudeSwapSwitcher = @Sendable (_ executablePath: String, _ slot: Int) async throws
        -> ClaudeSwapAccountSwitchResult
    /// The claude-swap source for a config, or nil when claude-swap is off or its executable is missing.
    typealias ClaudeSwapSourceResolver = @Sendable (_ snapshot: CLIServeConfigSnapshot) async -> ClaudeSwapServeSource?
    /// The claude-swap source for the config as it is now, read inside the transaction.
    typealias ClaudeSwapCurrentSource = @Sendable () async -> Result<ClaudeSwapServeSource, ClaudeSwapSwitchError>

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
        queue: ClaudeSwapSwitchQueue = .shared,
        generation: ClaudeSwapSwitchGeneration = .shared) async -> CLILocalHTTPResponse
    {
        guard request.method.uppercased() == "POST" else {
            return self.forkServeError(status: .methodNotAllowed, message: "method not allowed")
        }
        if let refusal = self.refuseUnlessMutatingForkRequestAllowed(request, runtime: runtime) {
            return refusal
        }
        let result: Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>
        switch self.claudeSwapSwitchTarget(request) {
        case let .failure(error):
            result = .failure(error)
        case let .success(slot):
            let resolve = resolveSource ?? { snapshot in
                await self.liveClaudeSwapSource(snapshot: snapshot, runtime: runtime)
            }
            let store = runtime.configStore
            let currentSource: ClaudeSwapCurrentSource = {
                guard let snapshot = try? self.loadServeConfigSnapshot(configStore: store) else {
                    return .failure(.configUnreadable)
                }
                guard let source = await resolve(snapshot) else { return .failure(.notEnabled) }
                return .success(source)
            }
            let cache = runtime.cache
            result = await self.runClaudeSwapSwitch(
                ClaudeSwapSwitchJob(
                    slot: slot,
                    currentSource: currentSource,
                    switcher: switcher,
                    generation: generation,
                    invalidate: { await cache.forkInvalidateResponses(where: Self.isClaudeResponseCacheKey) }),
                queue: queue)
        }
        switch result {
        case let .success(payload):
            return self.addingNoStore(self.forkServeJSON(payload))
        case let .failure(error):
            return self.addingNoStore(self.forkServeError(status: error.status, message: error.message))
        }
    }

    /// The slot the body names, checked before anything is queued.
    private static func claudeSwapSwitchTarget(_ request: CLILocalHTTPRequest) -> Result<Int, ClaudeSwapSwitchError> {
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
        return .success(slot)
    }

    /// Queues one switch and returns its answer as soon as the command has exited; the refresh after it keeps running
    /// in the queue, so the next switch still waits for it.
    static func runClaudeSwapSwitch(
        _ job: ClaudeSwapSwitchJob,
        queue: ClaudeSwapSwitchQueue) async -> Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>
    {
        await withCheckedContinuation { continuation in
            Task {
                await queue.submit {
                    let (answer, refresh) = await self.claudeSwapSwitchTransaction(job)
                    continuation.resume(returning: answer)
                    await refresh?()
                }
            }
        }
    }

    /// One switch: resolve claude-swap from the config as it is now, validate against a fresh list read, run the
    /// command, move the generation on and drop Claude's cached responses. Returns the answer and, when the command
    /// ran, the refresh to run after the answer went out.
    static func claudeSwapSwitchTransaction(_ job: ClaudeSwapSwitchJob) async
        -> (Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>, (@Sendable () async -> Void)?)
    {
        let (slot, currentSource, invalidate) = (job.slot, job.currentSource, job.invalidate)
        let source: ClaudeSwapServeSource
        switch await currentSource() {
        case let .failure(error): return (.failure(error), nil)
        case let .success(resolved): source = resolved
        }
        let accountID = "\(ProviderAccountSource.claudeSwap.rawValue):\(slot)"
        let current = await source.fetch()
        if let adapterError = current.adapterError {
            return (.failure(.listUnavailable(adapterError)), nil)
        }
        guard let row = current.rows.first(where: { $0.account.fields.accountID == accountID }) else {
            return (.failure(.unknownAccount), nil)
        }
        // The slot handed to cswap is the one this list read issued, never the request's text.
        guard row.account.fields.canSwitch,
              case let .claudeSwapSlot(target) = row.account.selector,
              target == slot
        else { return (.failure(.notSwitchable), nil) }

        let answer: Result<ClaudeSwapSwitchPayload, ClaudeSwapSwitchError>
        do {
            let result = try await job.switcher(source.executablePath, target)
            answer = .success(ClaudeSwapSwitchPayload(
                provider: ClaudeSwapServeSource.provider.rawValue,
                accountId: accountID,
                switched: result.switched))
        } catch {
            let detail = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
            answer = .failure(.switchFailed(detail.isEmpty ? "claude-swap switch failed." : detail))
        }
        // Whatever the command answered, Claude Code's account may have changed: nothing cached may outlive it, and
        // only a fresh list read says which account is active now.
        job.generation.advance()
        await invalidate()
        let executablePath = source.executablePath
        let refresh: @Sendable () async -> Void = {
            // A configuration that changed meanwhile (claude-swap off, another executable) discards the refresh.
            guard case let .success(now) = await currentSource(), now.executablePath == executablePath else { return }
            _ = await now.fetch()
            await invalidate()
        }
        return (answer, refresh)
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
