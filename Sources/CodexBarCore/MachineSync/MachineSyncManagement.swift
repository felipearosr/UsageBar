import Foundation

/// A Machine in the Sync Group, as `retire` and `forget` name it.
public struct MachineSyncMachineRef: Sendable, Equatable {
    public let machineID: String
    public let displayName: String?
    public let isThisMachine: Bool

    public init(machineID: String, displayName: String?, isThisMachine: Bool) {
        self.machineID = machineID
        self.displayName = displayName
        self.isThisMachine = isThisMachine
    }

    /// Display name, or the Machine ID when the Machine never uploaded a profile.
    public var label: String {
        self.displayName ?? self.machineID
    }
}

/// The Machine lifecycle from the CLI (§9): rename, retire, forget, leave, and the Pairing Link.
public enum MachineSyncManager {
    /// How many times `retire` re-reads and retries after `412 precondition_failed` before giving up.
    static let maxRetireAttempts = 5

    // MARK: Link

    /// This Machine's Pairing Link. Throws `notPaired` when it doesn't belong to a Sync Group.
    public static func pairingLink(environment: MachineSyncEnvironment) throws -> MachineSyncPairingLink {
        try self.paired(environment).link
    }

    // MARK: Rename

    /// Saves a new display name. The next push uploads it in `profile`, so other Machines see it after their
    /// next read. Works while unpaired too: the name is kept for the next `pair`.
    public static func rename(to displayName: String, environment: MachineSyncEnvironment) throws
        -> MachineSyncSettings
    {
        guard var settings = try environment.store.loadSettings() else { throw MachineSyncError.notPaired }
        settings.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try environment.store.saveSettings(settings)
        return settings
    }

    // MARK: Find

    /// Reads the Sync Group and finds the Machine named by `query`: its Machine ID, or else its display name
    /// (ignoring case).
    public static func findMachine(_ query: String, environment: MachineSyncEnvironment) async throws
        -> MachineSyncMachineRef
    {
        let settings = try self.paired(environment).settings
        let cache = try await MachineSyncReader.refresh(environment: environment).cache
        return try self.resolve(query, in: cache, thisMachineID: settings.machineID)
    }

    static func resolve(_ query: String, in cache: MachineSyncCache, thisMachineID: String?) throws
        -> MachineSyncMachineRef
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func ref(_ machineID: String) -> MachineSyncMachineRef {
            MachineSyncMachineRef(
                machineID: machineID,
                displayName: cache.machines[machineID]?.profile?.displayName,
                isThisMachine: machineID == thisMachineID)
        }
        if cache.machines[query] != nil { return ref(query) }
        let matches = cache.machines
            .filter { $0.value.profile?.displayName.caseInsensitiveCompare(query) == .orderedSame }
            .keys
            .sorted()
        switch matches.count {
        case 0: throw MachineSyncError.machineNotFound(query)
        case 1: return ref(matches[0])
        default: throw MachineSyncError.ambiguousMachine(name: query, machineIDs: matches)
        }
    }

    // MARK: Retire

    /// Adds `machineID` to the group `retired` blob (§5.3) with read-modify-write: GET the blob and its ETag,
    /// add the entry, and PUT with `If-Match`. A `412` means another Machine wrote in between, so it re-reads
    /// and tries again. Retiring again moves `retiredAt` forward, which hides a Machine that has pushed since.
    ///
    /// The protocol has no "create only if absent" precondition, so the first write of the blob is unconditional.
    /// It is read back afterwards and retried if another writer replaced it.
    @discardableResult
    public static func retire(machineID: String, environment: MachineSyncEnvironment) async throws -> Date {
        let paired = try self.paired(environment)
        let retiredAt = environment.now()
        let retiredAtText = ISO8601DateFormatter().string(from: retiredAt)
        let address = MachineSyncBlobAddress(
            groupID: paired.keys.groupIDBase64URL,
            machineID: MachineSyncMachineID.group,
            name: "retired")

        var verifyingCreate = false
        for _ in 0..<Self.maxRetireAttempts {
            let current = try await paired.client.getBlob(at: address, keys: paired.keys)
            var blob = try current.map { try self.decodeRetired($0.envelope, keys: paired.keys, address: address) }
                ?? ["v": 1, "machines": [String: Any]()]
            var machines = blob["machines"] as? [String: Any] ?? [:]
            if verifyingCreate, let entry = machines[machineID] as? [String: Any],
               entry["retiredAt"] as? String == retiredAtText
            {
                return retiredAt
            }

            // Keep any fields this version doesn't know about (§11).
            var entry = machines[machineID] as? [String: Any] ?? [:]
            entry["retiredAt"] = retiredAtText
            machines[machineID] = entry
            blob["machines"] = machines
            let plaintext = try JSONSerialization.data(
                withJSONObject: blob,
                options: [.sortedKeys, .withoutEscapingSlashes])
            let envelope = try MachineSyncEnvelope.seal(plaintext, encKey: paired.keys.encKey, address: address)
            do {
                try await paired.client.putBlob(
                    envelope,
                    at: address,
                    keys: paired.keys,
                    ifMatch: current.map { $0.etag ?? "*" })
            } catch let MachineSyncError.server(status, _, _, _) where status == 412 {
                verifyingCreate = false
                continue
            }
            guard current == nil else { return retiredAt }
            verifyingCreate = true
        }
        throw MachineSyncError.retiredConflict
    }

    /// The `retired` blob as a JSON object. Refuses to go on with a blob it can't read or a newer `v`, since
    /// rewriting it would drop the entries it holds.
    private static func decodeRetired(
        _ envelope: Data,
        keys: MachineSyncKeys,
        address: MachineSyncBlobAddress) throws -> [String: Any]
    {
        guard let plaintext = try? MachineSyncEnvelope.open(envelope, encKey: keys.encKey, address: address),
              let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              object["v"] as? Int == 1
        else { throw MachineSyncError.unreadableRetiredBlob }
        return object
    }

    // MARK: Forget

    /// Deletes a Machine and all its blobs from the server (§6.7), then drops it from the local cache.
    public static func forget(machineID: String, environment: MachineSyncEnvironment) async throws {
        let paired = try self.paired(environment)
        try await paired.client.deleteMachine(machineID, keys: paired.keys)
        // The server has already forgotten it; a failed re-read only leaves the cache stale until the next one.
        _ = try? await MachineSyncReader.refresh(environment: environment)
    }

    // MARK: Leave

    /// Unpairs this Machine: drops the Pairing Link, the push state, and the decrypted cache. Server data stays,
    /// and the Machine ID and display name are kept, so pairing again restores the same Machine.
    @discardableResult
    public static func leave(environment: MachineSyncEnvironment) throws -> MachineSyncSettings {
        guard var settings = try environment.store.loadSettings(), settings.pairingLink != nil else {
            throw MachineSyncError.notPaired
        }
        guard let lock = try MachineSyncPushLock.acquire(at: environment.store.lockURL) else {
            throw MachineSyncError.pushInProgress
        }
        defer { withExtendedLifetime(lock) {} }

        settings.pairingLink = nil
        try environment.store.saveSettings(settings)
        for url in [environment.store.stateURL, environment.store.cacheURL]
            where FileManager.default.fileExists(atPath: url.path)
        {
            try FileManager.default.removeItem(at: url)
        }
        return settings
    }

    // MARK: Helpers

    private struct Paired {
        let settings: MachineSyncSettings
        let link: MachineSyncPairingLink
        let keys: MachineSyncKeys
        let client: MachineSyncClient
    }

    private static func paired(_ environment: MachineSyncEnvironment) throws -> Paired {
        guard let settings = try environment.store.loadSettings(), let rawLink = settings.pairingLink else {
            throw MachineSyncError.notPaired
        }
        let link = try MachineSyncPairingLink(parsing: rawLink)
        return Paired(
            settings: settings,
            link: link,
            keys: link.keys,
            client: MachineSyncClient(apiBaseURL: link.apiBaseURL, transport: environment.transport))
    }
}
