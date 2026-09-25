import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// This Machine's Machine Sync settings, shared by the app and the CLI (§4).
public struct MachineSyncSettings: Codable, Sendable, Equatable {
    public var version: Int = 1
    /// Created once and kept after leaving a Sync Group, so re-pairing restores the same Machine.
    public var machineID: String
    public var displayName: String?
    /// Present only while this Machine belongs to a Sync Group. Holds the group key: keep the file private.
    public var pairingLink: String?

    public init(machineID: String, displayName: String? = nil, pairingLink: String? = nil) {
        self.machineID = machineID
        self.displayName = displayName
        self.pairingLink = pairingLink
    }
}

/// What the pusher remembers between runs. Owned by whoever holds the push lock.
public struct MachineSyncPushState: Codable, Sendable, Equatable {
    /// Group the hashes below belong to; a different group starts from scratch.
    public var groupID: String?
    /// SHA-256 (hex) of the plaintext last uploaded successfully, per blob name.
    public var uploadedHashes: [String: String] = [:]
    public var coverageStart: String?
    public var consecutiveFailures: Int = 0
    public var nextAttemptAt: Date?

    public init(groupID: String? = nil) {
        self.groupID = groupID
    }
}

/// Files next to `config.json`: `sync.json` (settings), `sync-state.json` (push state), `sync.lock`.
public struct MachineSyncStore: Sendable {
    public let directory: URL

    public init(directory: URL = CodexBarConfigStore.defaultURL().deletingLastPathComponent()) {
        self.directory = directory
    }

    public var settingsURL: URL {
        self.directory.appendingPathComponent("sync.json")
    }

    public var stateURL: URL {
        self.directory.appendingPathComponent("sync-state.json")
    }

    public var lockURL: URL {
        self.directory.appendingPathComponent("sync.lock")
    }

    public func loadSettings() throws -> MachineSyncSettings? {
        try self.load(MachineSyncSettings.self, from: self.settingsURL)
    }

    public func saveSettings(_ settings: MachineSyncSettings) throws {
        try self.save(settings, to: self.settingsURL)
    }

    public func loadState() throws -> MachineSyncPushState? {
        try self.load(MachineSyncPushState.self, from: self.stateURL)
    }

    public func saveState(_ state: MachineSyncPushState) throws {
        try self.save(state, to: self.stateURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func save(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
    }
}

/// Exclusive, non-blocking lock on `sync.lock` so only one process on a Machine pushes at a time (§4).
public final class MachineSyncPushLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Returns `nil` when another process (or another holder in this process) has the lock.
    public static func acquire(at url: URL) throws -> MachineSyncPushLock? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return MachineSyncPushLock(fd: fd)
    }

    deinit {
        _ = flock(self.fd, LOCK_UN)
        close(self.fd)
    }
}
