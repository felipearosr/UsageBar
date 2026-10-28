#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

// UsageBar: restored from upstream #2769 (removed in #3006) and extended with account binding and a stale read.

public enum ClaudeStatusLineDropStore {
    /// An observation this young replaces the OAuth request entirely.
    public static let freshnessWindow: TimeInterval = 15 * 60
    /// An observation this young may still stand in when OAuth is rate limited, minus any window that has reset.
    public static let staleWindow: TimeInterval = 6 * 60 * 60
    public static let maximumClockSkew: TimeInterval = 5 * 60
    public static let directoryName = "claude-statusline"

    public static func directoryURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent(self.directoryName, isDirectory: true)
    }

    public static func observationURL(applicationSupport: URL, profileID: String) -> URL {
        self.directoryURL(applicationSupport: applicationSupport)
            .appendingPathComponent("\(profileID).json", isDirectory: false)
    }

    public static func write(
        _ observation: ClaudeStatusLineRateLimits,
        applicationSupport: URL,
        fileManager: FileManager = .default) throws
    {
        guard self.isValid(observation) else { throw ClaudeStatusLineFileError.invalidObservation }
        let codexBarDirectory = applicationSupport.appendingPathComponent("CodexBar", isDirectory: true)
        let directory = self.directoryURL(applicationSupport: applicationSupport)
        try self.preparePrivateDirectory(codexBarDirectory, fileManager: fileManager)
        try self.preparePrivateDirectory(directory, fileManager: fileManager)
        let destination = self.observationURL(applicationSupport: applicationSupport, profileID: observation.profileID)
        guard !self.isSymbolicLink(destination, fileManager: fileManager) else {
            throw ClaudeStatusLineFileError.symbolicLink(destination.path)
        }

        let envelope = ClaudeStatusLineObservationEnvelope(
            schema: ClaudeStatusLineFeed.schemaVersion,
            observation: observation)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try CredentialFileWriter.writePrivate(encoder.encode(envelope), to: destination)
    }

    /// Loads the observation for `expectedProfileID` if it belongs to `expectedAccountID` and is at most
    /// `maximumAge` old. Windows whose reset time has passed are dropped: their percentage no longer applies.
    public static func load(
        applicationSupport: URL,
        expectedProfileID: String,
        expectedAccountID: String,
        maximumAge: TimeInterval = Self.freshnessWindow,
        now: Date = Date()) -> ClaudeStatusLineRateLimits?
    {
        let url = self.observationURL(applicationSupport: applicationSupport, profileID: expectedProfileID)
        guard !self.isSymbolicLink(url),
              let data = try? Data(contentsOf: url),
              let envelope = self.decode(data),
              envelope.observation.profileID == expectedProfileID,
              envelope.observation.accountID == expectedAccountID,
              self.isValid(envelope.observation),
              self.isWithinAge(envelope.observation, maximumAge: maximumAge, now: now)
        else { return nil }
        return self.droppingResetWindows(envelope.observation, now: now)
    }

    public static func isWithinAge(_ observation: ClaudeStatusLineRateLimits, maximumAge: TimeInterval, now: Date)
        -> Bool
    {
        let age = now.timeIntervalSince(observation.capturedAt)
        return age <= maximumAge && age >= -self.maximumClockSkew
    }

    public static func makeSnapshot(from limits: ClaudeStatusLineRateLimits) -> UsageSnapshot? {
        guard self.isValid(limits) else { return nil }
        return UsageSnapshot(
            primary: limits.fiveHour.map { self.window($0, minutes: 300) },
            secondary: limits.sevenDay.map { self.window($0, minutes: 10080) },
            updatedAt: limits.capturedAt,
            identity: nil,
            dataConfidence: .unknown)
    }

    static func droppingResetWindows(_ limits: ClaudeStatusLineRateLimits, now: Date) -> ClaudeStatusLineRateLimits? {
        func current(_ window: ClaudeStatusLineWindow?) -> ClaudeStatusLineWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            return window
        }
        let fiveHour = current(limits.fiveHour)
        let sevenDay = current(limits.sevenDay)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeStatusLineRateLimits(
            profileID: limits.profileID,
            accountID: limits.accountID,
            capturedAt: limits.capturedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay)
    }

    private static func decode(_ data: Data) -> ClaudeStatusLineObservationEnvelope? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let envelope = try? decoder.decode(ClaudeStatusLineObservationEnvelope.self, from: data),
              envelope.schema == ClaudeStatusLineFeed.schemaVersion
        else { return nil }
        return envelope
    }

    private static func isValid(_ observation: ClaudeStatusLineRateLimits) -> Bool {
        guard !observation.profileID.isEmpty,
              !observation.accountID.isEmpty,
              observation.capturedAt.timeIntervalSince1970.isFinite,
              observation.fiveHour != nil || observation.sevenDay != nil
        else { return false }
        return [observation.fiveHour, observation.sevenDay].compactMap(\.self).allSatisfy { window in
            window.usedPercent.isFinite &&
                (0...100).contains(window.usedPercent) &&
                self.isValidReset(window.resetsAt)
        }
    }

    private static func isValidReset(_ reset: Date?) -> Bool {
        guard let reset else { return true }
        let seconds = reset.timeIntervalSince1970
        return seconds.isFinite && ClaudeStatusLineFeed.validResetEpochSecondsRange.contains(seconds)
    }

    private static func window(_ source: ClaudeStatusLineWindow, minutes: Int) -> RateWindow {
        RateWindow(
            usedPercent: source.usedPercent,
            windowMinutes: minutes,
            resetsAt: source.resetsAt,
            resetDescription: nil)
    }

    private static func preparePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        guard !self.isSymbolicLink(url, fileManager: fileManager) else {
            throw ClaudeStatusLineFileError.symbolicLink(url.path)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ClaudeStatusLineFileError.notDirectory(url.path) }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}

public enum ClaudeStatusLineFileError: LocalizedError, Equatable {
    case symbolicLink(String)
    case notDirectory(String)
    case invalidObservation

    public var errorDescription: String? {
        switch self {
        case let .symbolicLink(path): "Refusing to write through symbolic link: \(path)"
        case let .notDirectory(path): "Expected a directory at: \(path)"
        case .invalidObservation: "Claude statusLine observation has no valid usage window."
        }
    }
}
