import Foundation

// UsageBar: Claude Code statusLine feed routing. See docs/claude-statusline-feed.md.
//
// `/api/oauth/usage` is throttled hard enough that a single machine polling every five minutes sees 429s. Claude
// Code already receives the same 5-hour and 7-day windows on every Messages API response and hands them to the
// user's statusLine command, which can pipe them to `codexbar claude statusline capture`. With the feed opted in:
//
// 1. a fresh observation (≤ 15 min) answers before OAuth, so no usage request is sent;
// 2. otherwise OAuth runs as before, and when it is rate limited an older observation (≤ 6 h, minus windows that
//    have since reset) answers instead of an error.
//
// Observations carry a hash of the account UUID from Claude Code's config and are ignored for any other account.

enum ClaudeStatusLineFeedRouting {
    /// The opt-in lives on the provider's config.json entry as `"statusLineFeed": true`.
    static func isEnabled(in config: ProviderConfig?) -> Bool {
        config?.extensionValue(Bool.self, forKey: ClaudeStatusLineFeed.configKey) ?? false
    }

    static func applies(to context: ProviderFetchContext) -> Bool {
        guard context.settings?.claude?.statusLineFeedEnabled == true,
              context.selectedTokenAccountID == nil
        else { return false }
        return context.sourceMode == .auto || context.sourceMode == .oauth
    }

    /// Puts the fresh feed first and lets a rate-limited OAuth step fall through to the stale feed.
    static func route(_ strategies: [any ProviderFetchStrategy], context: ProviderFetchContext)
        -> [any ProviderFetchStrategy]
    {
        guard self.applies(to: context) else { return strategies }
        var routed: [any ProviderFetchStrategy] = [ClaudeStatusLineFetchStrategy(mode: .fresh)]
        for strategy in strategies {
            if strategy.id == ClaudeStatusLineRateLimitFallbackStrategy.oauthStrategyID {
                routed.append(ClaudeStatusLineRateLimitFallbackStrategy(base: strategy))
                routed.append(ClaudeStatusLineFetchStrategy(mode: .stale))
            } else {
                routed.append(strategy)
            }
        }
        return routed
    }
}

struct ClaudeStatusLineFetchStrategy: ProviderFetchStrategy {
    enum Mode: Sendable {
        case fresh
        case stale

        var maximumAge: TimeInterval {
            switch self {
            case .fresh: ClaudeStatusLineDropStore.freshnessWindow
            case .stale: ClaudeStatusLineDropStore.staleWindow
            }
        }

        var sourceLabel: String {
            switch self {
            case .fresh: ClaudeStatusLineFeed.sourceLabel
            case .stale: ClaudeStatusLineFeed.staleSourceLabel
            }
        }
    }

    typealias ObservationLoader = @Sendable (ProviderFetchContext, TimeInterval) -> ClaudeStatusLineRateLimits?

    #if DEBUG
    @TaskLocal static var observationLoaderOverrideForTesting: ObservationLoader?
    #endif

    let mode: Mode
    let kind: ProviderFetchKind = .localProbe

    var id: String {
        switch self.mode {
        case .fresh: "claude.statusline"
        case .stale: "claude.statusline.stale"
        }
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        self.loadObservation(context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let limits = self.loadObservation(context),
              let snapshot = ClaudeStatusLineDropStore.makeSnapshot(from: limits)
        else { throw ClaudeStatusLineFetchError.noObservation }
        return self.makeResult(usage: snapshot, sourceLabel: self.mode.sourceLabel)
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        !ClaudeOAuthFetchError.isCancellation(error)
    }

    private func loadObservation(_ context: ProviderFetchContext) -> ClaudeStatusLineRateLimits? {
        #if DEBUG
        if let override = Self.observationLoaderOverrideForTesting {
            return override(context, self.mode.maximumAge)
        }
        #endif
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let accountID = ClaudeStatusLineProfile.accountID(environment: context.env)
        else { return nil }
        return ClaudeStatusLineDropStore.load(
            applicationSupport: support,
            expectedProfileID: ClaudeStatusLineProfile.identifier(environment: context.env),
            expectedAccountID: accountID,
            maximumAge: self.mode.maximumAge)
    }
}

/// Wraps the OAuth step so a usage-endpoint rate limit falls through to the stale feed instead of ending the chain.
struct ClaudeStatusLineRateLimitFallbackStrategy: ProviderFetchStrategy {
    static let oauthStrategyID = "claude.oauth"

    let base: any ProviderFetchStrategy

    var id: String {
        self.base.id
    }

    var kind: ProviderFetchKind {
        self.base.kind
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await self.base.isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try await self.base.fetch(context)
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if ClaudeUsageError.isClaudeOAuthUsageRateLimit(error) {
            return true
        }
        return self.base.shouldFallback(on: error, context: context)
    }
}

enum ClaudeStatusLineFetchError: Error {
    case noObservation
}
