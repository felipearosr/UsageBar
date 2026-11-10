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
///   The dashboard snapshot, which shares the plain fetch, keeps upstream's rows (`ServeUsageContext.claudeSwapRows`).
///
/// Raw stdout never leaves the reader: rows carry only projected fields, with labels and messages sanitized and
/// bounded. When a read fails (an unknown `schemaVersion`, a malformed list, a timeout), the last good rows come back
/// with the adapter error and `stale: true`; with none, the ambient fetch answers and carries the adapter error as its
/// `diagnostic`. With claude-swap disabled, or its executable missing, nothing here runs and the Claude rows are
/// upstream's.
struct ClaudeSwapServeSource: Sendable {
    typealias ListReader = @Sendable (_ executablePath: String, _ timeout: TimeInterval) async throws
        -> ClaudeSwapAccountList
    typealias ClaudeCodeLoader = @Sendable (_ now: Date) -> ClaudeCodeSignedInState?

    // Provider-specific by design: claude-swap is Claude's opt-in multi-account adapter; every Claude check in serve's
    // claude-swap path goes through this one constant.
    static let provider = UsageProvider.claude
    static let source = ClaudeSwapAccountProjection.sourceName
    static let staleSource = "\(ClaudeSwapAccountProjection.sourceName)-stale"

    let executablePath: String
    let timeout: TimeInterval
    let weeklyWorkDays: Int?
    /// How long the last good rows may stand in for a failed read (serve's stale TTL).
    let staleTTL: TimeInterval
    let state: ClaudeSwapServeState
    let readList: ListReader
    let loadClaudeCode: ClaudeCodeLoader
    let now: @Sendable () -> Date

    init(
        executablePath: String,
        timeout: TimeInterval = ClaudeSwapAccountReader.defaultTimeout,
        weeklyWorkDays: Int? = nil,
        staleTTL: TimeInterval = CLIServeResponseCache.maximumStaleTTL,
        state: ClaudeSwapServeState,
        readList: @escaping ListReader = { path, timeout in
            try await ClaudeSwapAccountReader.readAccountList(executablePath: path, timeout: timeout)
        },
        loadClaudeCode: @escaping ClaudeCodeLoader = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.executablePath = executablePath
        self.timeout = timeout
        self.weeklyWorkDays = weeklyWorkDays
        self.staleTTL = staleTTL
        self.state = state
        self.readList = readList
        self.loadClaudeCode = loadClaudeCode
        self.now = now
    }

    /// The source serve uses for `context`, or nil when claude-swap is off or its executable can't be found (the
    /// Claude rows are then upstream's, and `state` forgets its rows). Claude Code's account config is read for the
    /// slot it is signed in to; its statusLine capture only when the user opted in to the feed.
    static func live(
        context: ServeUsageContext,
        weeklyWorkDays: Int?,
        state: ClaudeSwapServeState = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> Self?
    {
        guard let config = context.config.providerConfig(for: self.provider.instanceID),
              config.claudeSwapEnabled == true,
              let configured = config.sanitizedClaudeSwapExecutablePath,
              let executablePath = resolvedExecutable(configured, environment: environment)
        else {
            await state.clear()
            return nil
        }
        let support = ClaudeSwapStatusLineOverride.isFeedEnabled(in: config)
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            : nil
        return Self(
            executablePath: executablePath,
            timeout: min(
                ClaudeSwapAccountReader.defaultTimeout,
                context.providerTimeout ?? ClaudeSwapAccountReader.defaultTimeout),
            weeklyWorkDays: weeklyWorkDays,
            staleTTL: CodexBarCLI.serveStaleTTL(refreshInterval: context.refreshInterval),
            state: state,
            loadClaudeCode: { now in
                ClaudeCodeSignedInState.load(environment: environment, applicationSupport: support, now: now)
            })
    }

    /// The configured path as an absolute executable file: tilde-expanded, or looked up on the absolute entries of
    /// `PATH` when it is a bare name. A relative path is refused.
    static func resolvedExecutable(_ configured: String, environment: [String: String]) -> String? {
        guard let expanded = try? ClaudeSwapAccountReader.resolvedExecutablePath(configured) else { return nil }
        if expanded.contains("/") {
            guard expanded.hasPrefix("/") else { return nil }
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = "\(directory)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// One list read, projected into rows. On failure, the last good rows (at most `staleTTL` old) marked stale.
    func fetch() async -> ClaudeSwapServeResult {
        let now = self.now()
        let list: ClaudeSwapAccountList
        do {
            list = try await self.readList(self.executablePath, self.timeout)
        } catch {
            // The list-level message is the reader's or parser's own, which for a handled claude-swap failure
            // includes the error envelope's type and message.
            let diagnostic = CLIClaudeSwapText.sanitizeDiagnostic(error.localizedDescription)
            let message = diagnostic.isEmpty ? "claude-swap list failed." : diagnostic
            let lastGood = await self.state.lastGoodRows(for: self.executablePath, now: now, maxAge: self.staleTTL)
            return ClaudeSwapServeResult(rows: lastGood.map { $0.stale(adapterError: message) }, adapterError: message)
        }
        let previous = await self.state.previousSnapshots(for: self.executablePath)
        let snapshots = ClaudeSwapAccountProjection.accountSnapshots(from: list, previousAccounts: previous, now: now)
        let signedIn = self.loadClaudeCode(now)
        let signedInSlot = signedIn.flatMap { ClaudeSwapStatusLineOverride.matchingSlot(in: list, account: $0.account) }
        let rows = snapshots.compactMap { snapshot -> ClaudeSwapServeRow? in
            guard let slot = Int(snapshot.id.opaqueID),
                  let row = list.accounts.first(where: { $0.number == slot })
            else { return nil }
            return ClaudeSwapServeRow(
                snapshot: snapshot,
                row: row,
                signedIn: slot == signedInSlot ? signedIn : nil,
                weeklyWorkDays: self.weeklyWorkDays,
                now: now)
        }
        await self.state.record(path: self.executablePath, snapshots: snapshots, rows: rows, at: now)
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

    /// `signedIn` is what Claude Code says about its account, passed only for the slot whose identity matches it: its
    /// plan names the slot's `loginMethod`, and its statusLine capture replaces the slot's windows when newer.
    init(
        snapshot: ProviderAccountUsageSnapshot,
        row: ClaudeSwapAccountRow,
        signedIn: ClaudeCodeSignedInState?,
        weeklyWorkDays: Int?,
        now: Date)
    {
        let provider = ClaudeSwapServeSource.provider
        // The projection marks a disabled slot "(disabled)"; that goes in its own field, the label stays the name.
        let decoration = " (disabled)"
        let baseLabel = row.isDisabled && snapshot.displayLabel.hasSuffix(decoration)
            ? String(snapshot.displayLabel.dropLast(decoration.count))
            : snapshot.displayLabel
        let label = CLIClaudeSwapText.sanitizeLabel(baseLabel)
        var usesLastKnown = snapshot.usesLastKnownUsage
        var fields = ProviderAccountRowFields(
            source: .claudeSwap,
            id: String(row.number),
            label: label.isEmpty ? "Account \(row.number)" : label,
            active: snapshot.isActive,
            labelIsDefault: label.isEmpty || Self.isFallbackLabel(baseLabel, row: row),
            disabled: row.isDisabled)
        let email = CLIClaudeSwapText.sanitizeLabel(row.email)
        let organization = CLIClaudeSwapText.sanitizeLabel(row.organizationName)
        // The projection's `loginMethod` names the adapter, not a plan. The plan comes from Claude Code's own account
        // config, for the slot it is signed in to; other slots carry none.
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: email.isEmpty ? nil : email,
            accountOrganization: organization.isEmpty ? nil : organization,
            loginMethod: signedIn?.account.planLoginMethod,
            accountID: fields.accountID)
        var usage = snapshot.snapshot.map { Self.replacingIdentity(of: $0, with: identity) }
        var source = ClaudeSwapServeSource.source
        var error = snapshot.error.map(CLIClaudeSwapText.sanitizeDiagnostic).flatMap { $0.isEmpty ? nil : $0 }
        var diagnostic: String?
        // A current Quota with a note (an at-limit reset) is not a failure.
        if usage != nil, !usesLastKnown {
            diagnostic = error
            error = nil
        }
        if let capture = signedIn?.capture,
           let captured = ClaudeSwapStatusLineOverride.applying(capture, to: usage, identity: identity)
        {
            usage = captured
            source = ClaudeSwapStatusLineOverride.sourceLabel(for: capture, now: now)
            diagnostic = error ?? diagnostic
            error = nil
            usesLastKnown = false
        }
        // A source-declared last-known Quota is shown, but marked stale.
        fields.stale = usesLastKnown && usage != nil
        if fields.stale { source = ClaudeSwapServeSource.staleSource }
        self.account = ProviderAccount(fields: fields, selector: .claudeSwapSlot(row.number))
        self.payload = ProviderPayload(
            provider: provider,
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
                CLIRenderer.providerPacePayload(provider: provider, snapshot: $0, weeklyWorkDays: weeklyWorkDays)
            })
    }

    /// Whether the projection made `label` up for `row`: "Account N" for a slot without an email, or an
    /// "· Account N" suffix that tells apart slots sharing an email. An alias, an email, or `email · organization`
    /// is a real label. `label` is the undecorated one (no "(disabled)").
    static func isFallbackLabel(_ label: String, row: ClaudeSwapAccountRow) -> Bool {
        guard (row.alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { return false }
        return row.email.isEmpty || label.hasSuffix(" · Account \(row.number)")
    }

    /// This last good row after a failed list read: its Quota (if any) kept, the adapter error attached, marked stale.
    /// The source says so too, for a client reading plain `/usage` (which has no `stale` key): a statusLine row
    /// becomes `statusline-stale` (still labelled as the user's statusLine), claude-swap's `claude-swap-stale`.
    func stale(adapterError: String) -> Self {
        let message = ClaudeSwapAccountProjection.displayError(
            accountError: self.payload.usage == nil ? self.payload.error?.message : nil,
            adapterError: adapterError) ?? adapterError
        var fields = self.account.fields
        fields.stale = true
        let isStatusLine = [ClaudeStatusLineFeed.sourceLabel, ClaudeStatusLineFeed.staleSourceLabel]
            .contains(self.payload.source)
        return Self(
            account: ProviderAccount(fields: fields, selector: self.account.selector),
            payload: self.payload.claudeSwapCopy(
                account: self.payload.account,
                cacheAccountKey: self.payload.cacheAccountKey,
                source: isStatusLine ? ClaudeStatusLineFeed.staleSourceLabel : ClaudeSwapServeSource.staleSource,
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
/// at-limit retention) and the last good rows (served stale when a read fails, up to serve's stale TTL). Memory only;
/// nothing is persisted, and turning claude-swap off forgets it.
actor ClaudeSwapServeState {
    static let shared = ClaudeSwapServeState()

    private var executablePath: String?
    private var snapshots: [ProviderAccountUsageSnapshot] = []
    private var rows: [ClaudeSwapServeRow] = []
    private var recordedAt: Date?

    func previousSnapshots(for path: String) -> [ProviderAccountUsageSnapshot] {
        path == self.executablePath ? self.snapshots : []
    }

    func lastGoodRows(for path: String, now: Date, maxAge: TimeInterval) -> [ClaudeSwapServeRow] {
        guard path == self.executablePath,
              let recordedAt,
              now.timeIntervalSince(recordedAt) <= maxAge
        else { return [] }
        return self.rows
    }

    /// The Provider Accounts of the last good read, when a fetch didn't hand serve its own (a timeout).
    func accounts(for path: String, now: Date, maxAge: TimeInterval) -> [ProviderAccount] {
        self.lastGoodRows(for: path, now: now, maxAge: maxAge).map(\.account)
    }

    func record(path: String, snapshots: [ProviderAccountUsageSnapshot], rows: [ClaudeSwapServeRow], at now: Date) {
        self.executablePath = path
        self.snapshots = snapshots
        self.rows = rows
        self.recordedAt = now
    }

    func clear() {
        self.executablePath = nil
        self.snapshots = []
        self.rows = []
        self.recordedAt = nil
    }
}

/// The result of this request's own claude-swap read, so `/usage?accounts=all` tags rows with the accounts that read
/// returned rather than with shared state. Empty when the coordinator answered without running it (a timeout).
actor ClaudeSwapResultBox {
    private(set) var result: ClaudeSwapServeResult?

    func set(_ result: ClaudeSwapServeResult) {
        self.result = result
    }
}

extension CodexBarCLI {
    /// `/usage?accounts=all`'s Claude fetch with claude-swap on: every slot's row, tagged. With no rows (an empty
    /// list, or a failed read with nothing to show), upstream's ambient fetch answers, carrying any adapter error as
    /// its `diagnostic`.
    static func claudeSwapAccountOutput(
        _ claudeSwap: ClaudeSwapServeSource,
        box: ClaudeSwapResultBox,
        ambient: @Sendable () async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        let result = await claudeSwap.fetch()
        await box.set(result)
        guard !result.rows.isEmpty else {
            return await Self.addingClaudeSwapDiagnostic(result.adapterError, to: ambient())
        }
        var output = UsageCommandOutput()
        output.payload = result.rows.map(\.payload)
        return output
    }

    /// The accounts `/usage?accounts=all` tags Claude's rows with: this request's read, else the last good one.
    static func claudeSwapAccounts(
        _ claudeSwap: ClaudeSwapServeSource,
        box: ClaudeSwapResultBox) async -> [ProviderAccount]
    {
        if let result = await box.result {
            return result.rows.map(\.account)
        }
        return await claudeSwap.state.accounts(
            for: claudeSwap.executablePath,
            now: claudeSwap.now(),
            maxAge: claudeSwap.staleTTL)
    }

    /// Plain `/usage`'s Claude fetch: the active slot's row with claude-swap on, else `fetch` (upstream's), which then
    /// carries any adapter error as its `diagnostic`.
    static func serveClaudeSwapOrFetch(
        provider: UsageProvider,
        claudeSwap: ClaudeSwapServeSource?,
        fetch: @Sendable () async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        guard provider == ClaudeSwapServeSource.provider, let claudeSwap else { return await fetch() }
        let result = await claudeSwap.fetch()
        if let active = result.rows.first(where: \.account.fields.active) {
            var output = UsageCommandOutput()
            // Plain /usage has no account fields. A stale row drops its cache key, so serve's last-good merge
            // can't swap it for an older copy without the adapter error.
            output.payload = [active.payload.claudeSwapCopy(
                account: nil,
                cacheAccountKey: active.account.fields.stale ? nil : active.account.fields.accountID,
                source: active.payload.source,
                error: active.payload.error)]
            return output
        }
        // No active slot (Claude Code is signed in to an account claude-swap doesn't list) or nothing to show: the
        // ambient fetch duplicates nothing.
        return await Self.addingClaudeSwapDiagnostic(result.adapterError, to: fetch())
    }

    /// The context upstream's plain `/usage` route builds: the only one that lets claude-swap answer Claude.
    static func servePlainUsageContext(
        snapshot: CLIServeConfigSnapshot,
        runtime: ServeRuntime,
        providerTimeout: TimeInterval?,
        providerDeadline: ContinuousClock.Instant?) -> ServeUsageContext
    {
        ServeUsageContext(
            config: snapshot.config,
            configFingerprint: snapshot.cacheToken,
            refreshInterval: runtime.refreshInterval,
            providerTimeout: providerTimeout,
            providerDeadline: providerDeadline,
            providerOperations: runtime.providerOperations,
            claudeSwapRows: true)
    }

    /// The plain `/usage` hook in upstream's `serveUsageOutput`. claude-swap answers only when the route asked for it
    /// (`context.claudeSwapRows`); the dashboard snapshot keeps upstream's fetch. `ambient` stands in for upstream's
    /// fetch in tests, so none reaches a real provider.
    static func forkServeFetchUsageOutputs(
        provider: UsageProvider,
        tokenContext: TokenAccountCLIContext,
        command: UsageCommandContext,
        context: ServeUsageContext,
        state: ClaudeSwapServeState = .shared,
        ambient: (@Sendable () async -> UsageCommandOutput)? = nil) async -> UsageCommandOutput
    {
        let fetch: @Sendable () async -> UsageCommandOutput = ambient ?? {
            await self.fetchUsageOutputs(provider: provider, status: nil, tokenContext: tokenContext, command: command)
        }
        guard context.claudeSwapRows, provider == ClaudeSwapServeSource.provider else { return await fetch() }
        let claudeSwap = await ClaudeSwapServeSource.live(
            context: context,
            weeklyWorkDays: command.weeklyWorkDays,
            state: state)
        return await self.serveClaudeSwapOrFetch(provider: provider, claudeSwap: claudeSwap, fetch: fetch)
    }

    /// `output`'s Claude rows with the claude-swap adapter error added to their `diagnostic`.
    private static func addingClaudeSwapDiagnostic(_ adapterError: String?, to output: UsageCommandOutput)
        -> UsageCommandOutput
    {
        guard let adapterError else { return output }
        var output = output
        let note = "claude-swap: \(adapterError)"
        output.payload = output.payload.map { row in
            guard row.provider == ClaudeSwapServeSource.provider.rawValue else { return row }
            return row.claudeSwapCopy(
                account: row.account,
                cacheAccountKey: row.cacheAccountKey,
                source: row.source,
                error: row.error,
                diagnostic: [row.diagnostic, note].compactMap(\.self).joined(separator: " "))
        }
        return output
    }
}

extension ProviderPayload {
    /// A copy with the account fields, source, error and (optionally) diagnostic replaced; everything else unchanged.
    fileprivate func claudeSwapCopy(
        account: String?,
        cacheAccountKey: String?,
        source: String,
        error: ProviderErrorPayload?,
        diagnostic: String? = nil) -> ProviderPayload
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
            diagnostic: diagnostic ?? self.diagnostic,
            pace: self.pace)
    }
}
