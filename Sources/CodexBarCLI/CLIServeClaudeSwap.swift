import CodexBarCore
import Foundation

// MARK: - claude-swap slots as Provider Accounts on serve (#170)

/// With claude-swap enabled, serve's Claude rows come from one `cswap --list --json` read through the existing
/// reader and projection (`docs/claude-multi-account-and-status-items.md`), and that read replaces the ambient Claude
/// fetch, so the active account is never fetched twice:
///
/// - `/usage?accounts=all` gets one row per slot, tagged `claude-swap:<slot>`, with claude-swap's `active` flag and
///   `updatedAt` from the slot's `usageFetchedAt`.
/// - Plain `/usage` gets the active slot's row, untagged. With no active slot (Claude Code signed in to an account
///   claude-swap doesn't manage, or an empty list) it keeps upstream's ambient fetch, which then fetches nothing twice.
///
/// Raw stdout never leaves the reader: rows carry only projected fields. When the list read fails (an unknown
/// `schemaVersion`, a malformed list, a timeout), the last good rows come back with the adapter error, `source`
/// `claude-swap-stale`, and `stale: true`. With claude-swap disabled, or its executable missing, nothing here runs and
/// the Claude rows are upstream's.
struct ClaudeSwapServeSource: Sendable {
    typealias ListReader = @Sendable (_ executablePath: String, _ timeout: TimeInterval) async throws
        -> ClaudeSwapAccountList
    typealias CaptureLoader = @Sendable (_ now: Date) -> ClaudeSwapStatusLineCapture?

    static let source = ClaudeSwapAccountProjection.sourceName
    static let staleSource = "\(ClaudeSwapAccountProjection.sourceName)-stale"

    let executablePath: String
    let timeout: TimeInterval
    let weeklyWorkDays: Int?
    let state: ClaudeSwapServeState
    let readList: ListReader
    let loadCapture: CaptureLoader
    let now: @Sendable () -> Date

    init(
        executablePath: String,
        timeout: TimeInterval = ClaudeSwapAccountReader.defaultTimeout,
        weeklyWorkDays: Int? = nil,
        state: ClaudeSwapServeState,
        readList: @escaping ListReader = { path, timeout in
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path, timeout: timeout)
        },
        loadCapture: @escaping CaptureLoader = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.executablePath = executablePath
        self.timeout = timeout
        self.weeklyWorkDays = weeklyWorkDays
        self.state = state
        self.readList = readList
        self.loadCapture = loadCapture
        self.now = now
    }

    /// The source serve uses for `config`, or nil when claude-swap is off or its executable can't be found (the
    /// Claude rows are then upstream's). The statusLine capture is read only when the user opted in to the feed.
    static func live(
        config: CodexBarConfig,
        providerTimeout: TimeInterval?,
        weeklyWorkDays: Int?,
        state: ClaudeSwapServeState = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Self?
    {
        // Provider-specific by design: claude-swap is Claude's opt-in multi-account adapter.
        guard let claude = config.providerConfig(for: .claude),
              claude.claudeSwapEnabled == true,
              let configured = claude.sanitizedClaudeSwapExecutablePath,
              let executablePath = resolvedExecutable(configured, environment: environment)
        else { return nil }
        var loadCapture: CaptureLoader = { _ in nil }
        if ClaudeSwapStatusLineOverride.isFeedEnabled(in: claude) {
            loadCapture = { now in
                guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first
                else { return nil }
                return ClaudeSwapStatusLineOverride.loadCapture(
                    environment: environment,
                    applicationSupport: support,
                    now: now)
            }
        }
        return Self(
            executablePath: executablePath,
            timeout: min(
                ClaudeSwapAccountReader.defaultTimeout,
                providerTimeout ?? ClaudeSwapAccountReader.defaultTimeout),
            weeklyWorkDays: weeklyWorkDays,
            state: state,
            loadCapture: loadCapture)
    }

    /// The configured path as an executable file: tilde-expanded, or looked up on `PATH` when it is a bare name.
    static func resolvedExecutable(_ configured: String, environment: [String: String]) -> String? {
        guard let expanded = try? ClaudeSwapAccountReader.resolvedExecutablePath(configured) else { return nil }
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// One list read, projected into rows. On failure, the last good rows marked stale.
    func fetch() async -> ClaudeSwapServeResult {
        let now = self.now()
        let list: ClaudeSwapAccountList
        do {
            list = try await self.readList(self.executablePath, self.timeout)
        } catch {
            let diagnostic = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
            let message = diagnostic.isEmpty ? "claude-swap list failed." : diagnostic
            let lastGood = await self.state.lastGoodRows(for: self.executablePath)
            return ClaudeSwapServeResult(rows: lastGood.map { $0.stale(adapterError: message) }, adapterError: message)
        }
        let previous = await self.state.previousSnapshots(for: self.executablePath)
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list, previousAccounts: previous, now: now)
        let capture = self.loadCapture(now)
        let capturedSlot = capture.flatMap { ClaudeSwapStatusLineOverride.matchingSlot(in: list, account: $0.account) }
        let rows = snapshots.compactMap { snapshot -> ClaudeSwapServeRow? in
            guard let slot = Int(snapshot.id.opaqueID) else { return nil }
            return ClaudeSwapServeRow(
                snapshot: snapshot,
                slot: slot,
                labelIsDefault: list.accounts.first { $0.number == slot }
                    .map { ClaudeSwapServeRow.isFallbackLabel(snapshot.displayLabel, row: $0) } ?? false,
                capture: slot == capturedSlot ? capture?.limits : nil,
                weeklyWorkDays: self.weeklyWorkDays,
                now: now)
        }
        await self.state.record(path: self.executablePath, snapshots: snapshots, rows: rows)
        return ClaudeSwapServeResult(rows: rows, adapterError: nil)
    }
}

struct ClaudeSwapServeResult: Sendable {
    let rows: [ClaudeSwapServeRow]
    /// Why the list read failed; `rows` are then the last good rows, marked stale.
    let adapterError: String?
}

/// One claude-swap slot as a serve row: the Provider Account and its `/usage` payload, tagged with the account.
struct ClaudeSwapServeRow: Sendable {
    let account: ProviderAccount
    let payload: ProviderPayload

    init(account: ProviderAccount, payload: ProviderPayload) {
        self.account = account
        self.payload = payload
    }

    /// `capture` is the statusLine capture for this slot's identity, if any; it replaces the slot's windows only
    /// when it is newer than them.
    init(
        snapshot: ProviderAccountUsageSnapshot,
        slot: Int,
        labelIsDefault: Bool = false,
        capture: ClaudeStatusLineRateLimits?,
        weeklyWorkDays: Int?,
        now: Date)
    {
        let fields = ProviderAccountRowFields(
            source: .claudeSwap,
            id: String(slot),
            label: snapshot.displayLabel,
            active: snapshot.isActive,
            labelIsDefault: labelIsDefault)
        // The projection's `loginMethod` names the adapter, not a plan; keep it out so no client shows it as one.
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: snapshot.accountEmail,
            accountOrganization: nil,
            loginMethod: nil,
            accountID: fields.accountID)
        var usage = snapshot.snapshot.map { Self.replacingIdentity(of: $0, with: identity) }
        var source = snapshot.usesLastKnownUsage && usage != nil ? ClaudeSwapServeSource.staleSource
            : ClaudeSwapServeSource.source
        var error = snapshot.error
        var diagnostic: String?
        // A current Quota with a note (an at-limit reset) is not a failure.
        if usage != nil, !snapshot.usesLastKnownUsage {
            diagnostic = error
            error = nil
        }
        if let capture,
           let captured = ClaudeSwapStatusLineOverride.applying(capture, to: usage, identity: identity)
        {
            usage = captured
            source = ClaudeSwapStatusLineOverride.sourceLabel(for: capture, now: now)
            diagnostic = error ?? diagnostic
            error = nil
        }
        self.account = ProviderAccount(fields: fields, selector: .claudeSwapSlot(slot))
        self.payload = ProviderPayload(
            provider: .claude,
            account: fields.label,
            cacheAccountKey: fields.accountID,
            version: nil,
            source: source,
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: error.map { ProviderErrorPayload(code: 1, message: $0, kind: .provider) },
            diagnostic: diagnostic,
            pace: usage.flatMap {
                CLIRenderer.providerPacePayload(provider: .claude, snapshot: $0, weeklyWorkDays: weeklyWorkDays)
            })
    }

    /// Whether the projection made `label` up for `row`: "Account N" for a slot without an email, or an
    /// "· Account N" suffix that tells apart slots sharing an email. An alias, an email, or `email · organization`
    /// is a real label.
    static func isFallbackLabel(_ label: String, row: ClaudeSwapAccountRow) -> Bool {
        guard (row.alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { return false }
        if row.email.isEmpty { return true }
        let suffix = " · Account \(row.number)"
        return label.hasSuffix(suffix) || label.hasSuffix("\(suffix) (disabled)")
    }

    /// This last good row after a failed list read: its Quota (if any) kept, the adapter error attached, marked stale.
    func stale(adapterError: String) -> Self {
        let message = ClaudeSwapAccountProjection.displayError(
            accountError: self.payload.usage == nil ? self.payload.error?.message : nil,
            adapterError: adapterError) ?? adapterError
        return Self(account: self.account, payload: self.payload.claudeSwapCopy(
            account: self.payload.account,
            cacheAccountKey: self.payload.cacheAccountKey,
            source: ClaudeSwapServeSource.staleSource,
            error: ProviderErrorPayload(code: 1, message: message, kind: .provider)))
    }

    private static func replacingIdentity(of snapshot: UsageSnapshot, with identity: ProviderIdentitySnapshot)
        -> UsageSnapshot
    {
        // The projection fills only these fields.
        UsageSnapshot(
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            extraRateWindows: snapshot.extraRateWindows,
            providerCost: snapshot.providerCost,
            updatedAt: snapshot.updatedAt,
            identity: identity,
            dataConfidence: snapshot.dataConfidence)
    }
}

/// What serve remembers between claude-swap reads, per executable: the projection's previous snapshots (for its
/// at-limit retention) and the last good rows (served stale when a read fails). Memory only; nothing is persisted.
actor ClaudeSwapServeState {
    static let shared = ClaudeSwapServeState()

    private var executablePath: String?
    private var snapshots: [ProviderAccountUsageSnapshot] = []
    private var rows: [ClaudeSwapServeRow] = []

    func previousSnapshots(for path: String) -> [ProviderAccountUsageSnapshot] {
        path == self.executablePath ? self.snapshots : []
    }

    func lastGoodRows(for path: String) -> [ClaudeSwapServeRow] {
        path == self.executablePath ? self.rows : []
    }

    /// The Provider Accounts of the last good read, for serve's all-or-nothing tagging.
    func accounts(for path: String) -> [ProviderAccount] {
        self.lastGoodRows(for: path).map(\.account)
    }

    func record(path: String, snapshots: [ProviderAccountUsageSnapshot], rows: [ClaudeSwapServeRow]) {
        self.executablePath = path
        self.snapshots = snapshots
        self.rows = rows
    }
}

extension CodexBarCLI {
    /// `/usage?accounts=all`'s Claude fetch with claude-swap on: every slot's row, tagged. An empty list keeps
    /// upstream's ambient fetch (`ambient`); a failed read with nothing to show is one untagged error row.
    static func claudeSwapAccountOutput(
        _ claudeSwap: ClaudeSwapServeSource,
        ambient: @Sendable () async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        let result = await claudeSwap.fetch()
        if result.rows.isEmpty {
            guard let adapterError = result.adapterError else { return await ambient() }
            return Self.claudeSwapErrorOutput(adapterError)
        }
        var output = UsageCommandOutput()
        output.payload = result.rows.map(\.payload)
        return output
    }

    /// Plain `/usage`'s Claude fetch: the active slot's row with claude-swap on, else `fetch` (upstream's).
    static func serveClaudeSwapOrFetch(
        provider: UsageProvider,
        claudeSwap: ClaudeSwapServeSource?,
        fetch: @Sendable () async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        guard provider == .claude, let claudeSwap else { return await fetch() }
        let result = await claudeSwap.fetch()
        if let active = result.rows.first(where: \.account.fields.active) {
            var output = UsageCommandOutput()
            let stale = active.payload.source == ClaudeSwapServeSource.staleSource
            // Plain /usage has no account fields. A stale row drops its cache key, so serve's last-good merge
            // can't swap it for an older copy without the adapter error.
            output.payload = [active.payload.claudeSwapCopy(
                account: nil,
                cacheAccountKey: stale ? nil : active.account.fields.accountID,
                source: active.payload.source,
                error: active.payload.error)]
            return output
        }
        if let adapterError = result.adapterError { return Self.claudeSwapErrorOutput(adapterError) }
        // No active slot: Claude Code is signed in to an account claude-swap doesn't list, so the ambient fetch
        // duplicates nothing.
        return await fetch()
    }

    /// The plain `/usage` hook in upstream's `serveUsageOutput`.
    static func forkServeFetchUsageOutputs(
        provider: UsageProvider,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext,
        context: ServeUsageContext) async -> UsageCommandOutput
    {
        let claudeSwap = provider == .claude
            ? ClaudeSwapServeSource.live(
                config: context.config,
                providerTimeout: context.providerTimeout,
                weeklyWorkDays: command.weeklyWorkDays)
            : nil
        return await self.serveClaudeSwapOrFetch(provider: provider, claudeSwap: claudeSwap) {
            await self.fetchUsageOutputs(provider: provider, status: nil, tokenContext: tokenContext, command: command)
        }
    }

    private static func claudeSwapErrorOutput(_ message: String) -> UsageCommandOutput {
        var output = UsageCommandOutput()
        output.payload = [ProviderPayload(
            provider: .claude,
            account: nil,
            version: nil,
            source: ClaudeSwapServeSource.source,
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: 1, message: message, kind: .provider))]
        return output
    }
}

extension ProviderPayload {
    /// A copy with the account fields, source and error replaced; everything else unchanged.
    fileprivate func claudeSwapCopy(
        account: String?,
        cacheAccountKey: String?,
        source: String,
        error: ProviderErrorPayload?) -> ProviderPayload
    {
        ProviderPayload(
            providerID: self.provider,
            account: account,
            cacheAccountKey: cacheAccountKey,
            version: self.version,
            source: source,
            status: self.status,
            usage: self.usage,
            credits: self.credits,
            antigravityPlanInfo: self.antigravityPlanInfo,
            openaiDashboard: self.openaiDashboard,
            error: error,
            diagnostic: self.diagnostic,
            pace: self.pace)
    }
}
