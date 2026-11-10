import Foundation

// UsageBar: Claude Code's signed-in account applied to one claude-swap slot (#170). See docs/claude-statusline-feed.md.
//
// claude-swap lists several accounts; Claude Code is signed in to one of them. That slot, and only that slot, can
// carry what Claude Code knows about its account: the plan family from `oauthAccount.organizationType`, and the
// statusLine capture when the feed is on. The slot is the one whose email and organization match Claude Code's
// current `oauthAccount`. Never by position, and never when the match is ambiguous.

/// The account Claude Code is signed in to, from its own plain-text account config (`.claude.json`). A file read
/// only: no Keychain, no credential file, no subprocess. Email and organization are display data used for matching;
/// they are never logged or persisted.
public struct ClaudeCodeSignedInAccount: Equatable, Sendable {
    public let accountUuid: String
    public let email: String
    public let organizationName: String
    /// `oauthAccount.organizationType`, e.g. `claude_max`; empty when absent.
    public let organizationType: String

    public init(accountUuid: String, email: String, organizationName: String, organizationType: String = "") {
        self.accountUuid = accountUuid
        self.email = email
        self.organizationName = organizationName
        self.organizationType = organizationType
    }

    private struct Config: Decodable {
        struct OAuthAccount: Decodable {
            let accountUuid: String?
            let emailAddress: String?
            let organizationName: String?
            let organizationType: String?
        }

        let oauthAccount: OAuthAccount?
    }

    /// Nil when the config is missing, unreadable, malformed, or names no account with a UUID and an email.
    public static func load(environment: [String: String]) -> Self? {
        let url = ClaudeConfigPaths.accountConfigURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return self.parse(data)
    }

    public static func parse(_ data: Data) -> Self? {
        guard let account = (try? JSONDecoder().decode(Config.self, from: data))?.oauthAccount,
              let uuid = account.accountUuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty,
              let email = account.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty
        else { return nil }
        return Self(
            accountUuid: uuid,
            email: email,
            organizationName: (account.organizationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            organizationType: (account.organizationType ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The plan as a `loginMethod` the way the single-account fetch words it: `claude_max` → `Claude Max`. Nil for an
    /// absent or unrecognised organization type.
    public var planLoginMethod: String? {
        let type = self.organizationType.lowercased()
        let prefix = "claude_"
        guard type.hasPrefix(prefix), type.count <= 40 else { return nil }
        let words = type.dropFirst(prefix.count).split(separator: "_")
        guard !words.isEmpty,
              words.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        else { return nil }
        return (["Claude"] + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}

/// What Claude Code says about its signed-in account: the account, and its statusLine capture when the feed is on.
public struct ClaudeCodeSignedInState: Equatable, Sendable {
    public let account: ClaudeCodeSignedInAccount
    public let capture: ClaudeStatusLineRateLimits?

    public init(account: ClaudeCodeSignedInAccount, capture: ClaudeStatusLineRateLimits?) {
        self.account = account
        self.capture = capture
    }

    /// One read of the account config gives both the identity and the capture's account hash, so the two cannot
    /// describe different accounts. `applicationSupport` nil (the feed is off) reads no capture. The capture is at
    /// most the feed's stale window old, minus windows that have reset.
    public static func load(
        environment: [String: String],
        applicationSupport: URL?,
        now: Date = Date()) -> Self?
    {
        guard let account = ClaudeCodeSignedInAccount.load(environment: environment) else { return nil }
        let capture = applicationSupport.flatMap { support in
            ClaudeStatusLineDropStore.load(
                applicationSupport: support,
                expectedProfileID: ClaudeStatusLineProfile.identifier(environment: environment),
                expectedAccountID: ClaudeStatusLineProfile.accountID(accountUuid: account.accountUuid),
                maximumAge: ClaudeStatusLineDropStore.staleWindow,
                allowsResetWindows: true,
                now: now)
        }
        return Self(account: account, capture: capture)
    }
}

public enum ClaudeSwapStatusLineOverride {
    /// Whether the user opted in to the statusLine feed (`"statusLineFeed": true` on the claude provider).
    public static func isFeedEnabled(in config: ProviderConfig?) -> Bool {
        ClaudeStatusLineFeedRouting.isEnabled(in: config)
    }

    /// The one slot whose email and organization match `account`; nil when none or several do.
    public static func matchingSlot(in list: ClaudeSwapAccountList, account: ClaudeCodeSignedInAccount) -> Int? {
        let email = self.normalized(account.email)
        let organization = self.normalized(account.organizationName)
        guard !email.isEmpty else { return nil }
        let matches = list.accounts.filter {
            self.normalized($0.email) == email && self.normalized($0.organizationName) == organization
        }
        return matches.count == 1 ? matches[0].number : nil
    }

    /// `snapshot` with the capture's windows, when the capture is newer than the Quota it holds (no Quota counts as
    /// older). A window the capture lacks keeps claude-swap's value. `updatedAt` is the capture time only when the
    /// capture replaced every window the snapshot had; otherwise the older of the two, so nothing looks fresher than
    /// it is. Nil when the capture is not newer.
    public static func applying(
        _ limits: ClaudeStatusLineRateLimits,
        to snapshot: UsageSnapshot?,
        identity: ProviderIdentitySnapshot?) -> UsageSnapshot?
    {
        if let snapshot, snapshot.updatedAt >= limits.capturedAt { return nil }
        guard let captured = ClaudeStatusLineDropStore.makeSnapshot(from: limits) else { return nil }
        let replacesEverything = (snapshot?.primary == nil || captured.primary != nil) &&
            (snapshot?.secondary == nil || captured.secondary != nil) &&
            (snapshot?.extraRateWindows ?? []).isEmpty
        let updatedAt = replacesEverything
            ? limits.capturedAt
            : min(limits.capturedAt, snapshot?.updatedAt ?? limits.capturedAt)
        return UsageSnapshot(
            primary: captured.primary ?? snapshot?.primary,
            secondary: captured.secondary ?? snapshot?.secondary,
            extraRateWindows: snapshot?.extraRateWindows,
            providerCost: snapshot?.providerCost,
            updatedAt: updatedAt,
            identity: identity ?? snapshot?.identity)
    }

    /// `statusline` for a capture young enough to replace OAuth, `statusline-stale` otherwise.
    public static func sourceLabel(for limits: ClaudeStatusLineRateLimits, now: Date) -> String {
        ClaudeStatusLineDropStore.isWithinAge(limits, maximumAge: ClaudeStatusLineDropStore.freshnessWindow, now: now)
            ? ClaudeStatusLineFeed.sourceLabel
            : ClaudeStatusLineFeed.staleSourceLabel
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
