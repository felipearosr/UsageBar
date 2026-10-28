import CoreFoundation
import Crypto
import Foundation

// UsageBar: restored from upstream #2769 (removed in #3006), bound to the signed-in Claude account so the feed can
// stand in for the rate-limited `/api/oauth/usage` endpoint. See docs/claude-statusline-feed.md.

public enum ClaudeStatusLineFeed {
    public static let sourceLabel = "statusline"
    public static let staleSourceLabel = "statusline-stale"
    public static let schemaVersion = 2
    public static let maximumInputBytes = 1_048_576
    /// StatusLine reset epochs outside 2000-01-01 through 2100-01-01 are treated as drifted metadata.
    public static let validResetEpochSecondsRange: ClosedRange<Double> = 946_684_800...4_102_444_800
    /// `config.json` key on the Claude provider entry that opts in to the feed.
    public static let configKey = "statusLineFeed"
}

public struct ClaudeStatusLineWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ClaudeStatusLineRateLimits: Codable, Equatable, Sendable {
    public let profileID: String
    /// One-way hash of the Claude account UUID that was signed in when Claude Code emitted the payload.
    public let accountID: String
    public let capturedAt: Date
    public let fiveHour: ClaudeStatusLineWindow?
    public let sevenDay: ClaudeStatusLineWindow?

    public init(
        profileID: String,
        accountID: String,
        capturedAt: Date,
        fiveHour: ClaudeStatusLineWindow?,
        sevenDay: ClaudeStatusLineWindow?)
    {
        self.profileID = profileID
        self.accountID = accountID
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public enum ClaudeStatusLineProfile {
    public static func identifier(environment: [String: String]) -> String {
        let raw = environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] ?? ""
        let material = raw.isEmpty ? "codexbar.claude-statusline.default" : "codexbar.claude-statusline.\(raw)"
        return self.sha256Hex(material)
    }

    /// The account the profile is signed in to right now, from Claude Code's own plain-text config.
    /// Nil when the config cannot prove a signed-in account; callers then treat the feed as absent.
    public static func accountID(environment: [String: String]) -> String? {
        guard let uuid = ClaudeAccountProfile.accountUuid(environment: environment) else { return nil }
        return self.sha256Hex("codexbar.claude-account.\(uuid.lowercased())")
    }

    private static func sha256Hex(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Parses Claude Code's statusLine stdin. Only the two documented rate-limit windows are accepted.
public enum ClaudeStatusLinePayloadParser {
    public static func parseOfficialPayload(
        _ data: Data,
        capturedAt: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeStatusLineRateLimits?
    {
        guard data.count <= ClaudeStatusLineFeed.maximumInputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any],
              let accountID = ClaudeStatusLineProfile.accountID(environment: environment)
        else { return nil }

        let fiveHour = self.window(rateLimits["five_hour"])
        let sevenDay = self.window(rateLimits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeStatusLineRateLimits(
            profileID: ClaudeStatusLineProfile.identifier(environment: environment),
            accountID: accountID,
            capturedAt: capturedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay)
    }

    private static func window(_ raw: Any?) -> ClaudeStatusLineWindow? {
        guard let object = raw as? [String: Any],
              let used = self.finiteNumber(object["used_percentage"]),
              (0...100).contains(used)
        else { return nil }
        return ClaudeStatusLineWindow(usedPercent: used, resetsAt: self.resetDate(object["resets_at"]))
    }

    private static func resetDate(_ raw: Any?) -> Date? {
        guard let seconds = self.finiteNumber(raw),
              ClaudeStatusLineFeed.validResetEpochSecondsRange.contains(seconds)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

struct ClaudeStatusLineObservationEnvelope: Codable, Equatable {
    let schema: Int
    let observation: ClaudeStatusLineRateLimits
}
