import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct MachineSyncManagementTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    private func twoMachines() async throws -> (laptop: MachineSyncTestContext, desk: MachineSyncTestContext) {
        let laptop = MachineSyncTestContext(now: Self.now)
        var desk = MachineSyncTestContext(now: Self.now, server: laptop.server)
        desk.hostName = "desk"
        laptop.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: 2)]
        desk.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 10), cost: 0.5)]
        let created = try await laptop.create()
        _ = try await laptop.push()
        try await desk.pair(created.link.link)
        _ = try await desk.push()
        return (laptop, desk)
    }

    private func keys(_ context: MachineSyncTestContext) throws -> MachineSyncKeys {
        try MachineSyncPairingLink(parsing: #require(try context.store.loadSettings()?.pairingLink)).keys
    }

    private func retiredAddress(_ keys: MachineSyncKeys) -> MachineSyncBlobAddress {
        MachineSyncBlobAddress(groupID: keys.groupIDBase64URL, machineID: "group", name: "retired")
    }

    /// The group `retired` blob as the server holds it, decrypted.
    private func retiredEntries(_ context: MachineSyncTestContext) throws -> [String: String] {
        let keys = try self.keys(context)
        let envelope = try #require(context.server.blob(machineID: "group", name: "retired"))
        let plaintext = try MachineSyncEnvelope.open(envelope, encKey: keys.encKey, address: self.retiredAddress(keys))
        let object = try #require(try JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        let machines = try #require(object["machines"] as? [String: [String: Any]])
        return machines.compactMapValues { $0["retiredAt"] as? String }
    }

    /// Writes the `retired` blob as another Machine would.
    private func storeRetired(_ json: String, in context: MachineSyncTestContext) throws {
        let keys = try self.keys(context)
        try context.server.store(machineID: "group", name: "retired", body: MachineSyncEnvelope.seal(
            Data(json.utf8),
            encKey: keys.encKey,
            address: self.retiredAddress(keys)))
    }

    // MARK: Retire

    @Test
    func `retiring by name keeps the Spend in totals and hides the Machine from active`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let deskID = try #require(try desk.store.loadSettings()?.machineID)

        let found = try await MachineSyncManager.findMachine("DESK", environment: laptop.environment)
        #expect(found == MachineSyncMachineRef(machineID: deskID, displayName: "desk", isThisMachine: false))
        let retiredAt = try await MachineSyncManager.retire(machineID: deskID, environment: laptop.environment)

        #expect(retiredAt == Self.now)
        #expect(try self.retiredEntries(laptop) == [deskID: "2026-09-24T12:30:00Z"])
        let status = try await laptop.status()
        let row = try #require(status.machines.first { $0.machineId == deskID })
        #expect(row.retired)
        #expect(!row.active)
        #expect(status.total.today.costUSD == 2.5)
    }

    @Test
    func `a retire that loses the race re-reads after 412 and keeps the other retirement`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let first = MachineSyncMachineID.generate()
        let other = MachineSyncMachineID.generate()
        let target = MachineSyncMachineID.generate()
        try self.storeRetired(#"{"v":1,"machines":{"\#(first)":{"retiredAt":"2026-09-01T10:00:00Z"}}}"#, in: laptop)
        // Another Machine retires `other` between our GET and our PUT, so our If-Match is stale.
        let racer = try self.keys(laptop)
        laptop.server.beforeNextPut(named: "retired") {
            let json = #"{"v":1,"machines":{"\#(first)":{"retiredAt":"2026-09-01T10:00:00Z"},"#
                + #""\#(other)":{"retiredAt":"2026-09-24T12:29:00Z","note":"kept"}}}"#
            let envelope = try? MachineSyncEnvelope.seal(
                Data(json.utf8),
                encKey: racer.encKey,
                address: self.retiredAddress(racer))
            laptop.server.store(machineID: "group", name: "retired", body: envelope ?? Data())
        }

        try await MachineSyncManager.retire(machineID: target, environment: laptop.environment)

        #expect(try self.retiredEntries(laptop) == [
            first: "2026-09-01T10:00:00Z",
            other: "2026-09-24T12:29:00Z",
            target: "2026-09-24T12:30:00Z",
        ])
        let puts = laptop.server.requests.filter { $0.httpMethod == "PUT" && $0.url?.lastPathComponent == "retired" }
        #expect(puts.count == 2)
        #expect(puts.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") != nil })
        #expect(puts[0].value(forHTTPHeaderField: "If-Match") != puts[1].value(forHTTPHeaderField: "If-Match"))
        // Fields this version doesn't know about survive the rewrite (§11).
        let keys = try self.keys(laptop)
        let plaintext = try MachineSyncEnvelope.open(
            #require(laptop.server.blob(machineID: "group", name: "retired")),
            encKey: keys.encKey,
            address: self.retiredAddress(keys))
        #expect(String(bytes: plaintext, encoding: .utf8)?.contains(#""note":"kept""#) == true)
    }

    @Test
    func `two Machines retiring at the same time both survive`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let seeded = MachineSyncMachineID.generate()
        try self.storeRetired(#"{"v":1,"machines":{"\#(seeded)":{"retiredAt":"2026-09-01T10:00:00Z"}}}"#, in: laptop)
        let fromLaptop = MachineSyncMachineID.generate()
        let fromDesk = MachineSyncMachineID.generate()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group
                .addTask { try await MachineSyncManager.retire(machineID: fromLaptop, environment: laptop.environment) }
            group.addTask { try await MachineSyncManager.retire(machineID: fromDesk, environment: desk.environment) }
            try await group.waitForAll()
        }

        #expect(try Set(self.retiredEntries(laptop).keys) == [seeded, fromLaptop, fromDesk])
    }

    @Test
    func `the first write of the retired list is read back and retried if another Machine replaced it`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let other = MachineSyncMachineID.generate()
        let target = MachineSyncMachineID.generate()
        let keys = try self.keys(laptop)
        // No blob yet, so our PUT is unconditional; another Machine's unconditional PUT lands right after it.
        laptop.server.afterNextPut(named: "retired") {
            let json = #"{"v":1,"machines":{"\#(other)":{"retiredAt":"2026-09-24T12:29:00Z"}}}"#
            let envelope = try? MachineSyncEnvelope.seal(
                Data(json.utf8),
                encKey: keys.encKey,
                address: self.retiredAddress(keys))
            laptop.server.store(machineID: "group", name: "retired", body: envelope ?? Data())
        }

        try await MachineSyncManager.retire(machineID: target, environment: laptop.environment)

        #expect(try Set(self.retiredEntries(laptop).keys) == [other, target])
        let puts = laptop.server.requests.filter { $0.httpMethod == "PUT" && $0.url?.lastPathComponent == "retired" }
        #expect(puts.map { $0.value(forHTTPHeaderField: "If-Match") == nil } == [true, false])
    }

    @Test
    func `a retired Machine that pushes again shows as active, and retiring again hides it`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let deskID = try #require(try desk.store.loadSettings()?.machineID)
        var later = laptop
        later.now = Self.now.addingTimeInterval(60)
        try await MachineSyncManager.retire(machineID: deskID, environment: later.environment)
        #expect(try await later.status().machines.first { $0.machineId == deskID }?.retired == true)

        var back = desk
        back.now = Self.now.addingTimeInterval(180)
        back.server.now = back.now
        _ = try await back.push()
        later.now = back.now
        let revived = try #require(try await later.status().machines.first { $0.machineId == deskID })
        #expect(!revived.retired)
        #expect(revived.active)

        later.now = back.now.addingTimeInterval(60)
        try await MachineSyncManager.retire(machineID: deskID, environment: later.environment)
        let again = try #require(try await later.status().machines.first { $0.machineId == deskID })
        #expect(again.retired)
        #expect(!again.active)
    }

    @Test
    func `an unreadable retired list is left alone`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        try self.storeRetired(#"{"v":2,"machines":{}}"#, in: laptop)
        let before = laptop.server.blob(machineID: "group", name: "retired")

        await #expect(throws: MachineSyncError.unreadableRetiredBlob) {
            try await MachineSyncManager.retire(
                machineID: MachineSyncMachineID.generate(),
                environment: laptop.environment)
        }
        #expect(laptop.server.blob(machineID: "group", name: "retired") == before)
    }

    // MARK: Find

    @Test
    func `machines are found by ID or name, and ambiguous or unknown names are refused`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let laptopID = try #require(try laptop.store.loadSettings()?.machineID)
        let deskID = try #require(try desk.store.loadSettings()?.machineID)

        let byID = try await MachineSyncManager.findMachine(deskID, environment: laptop.environment)
        #expect(byID.machineID == deskID)
        let this = try await MachineSyncManager.findMachine("test-host", environment: laptop.environment)
        #expect(this.machineID == laptopID)
        #expect(this.isThisMachine)
        await #expect(throws: MachineSyncError.machineNotFound("nope")) {
            try await MachineSyncManager.findMachine("nope", environment: laptop.environment)
        }

        _ = try MachineSyncManager.rename(to: "Desk", environment: laptop.environment)
        var pushed = laptop
        pushed.now = Self.now.addingTimeInterval(10)
        _ = try await pushed.push()
        await #expect(throws: MachineSyncError.ambiguousMachine(
            name: "desk",
            machineIDs: [deskID, laptopID].sorted()))
        {
            try await MachineSyncManager.findMachine("desk", environment: laptop.environment)
        }
    }

    // MARK: Forget

    @Test
    func `forget deletes the Machine and its Spend from the server`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let deskID = try #require(try desk.store.loadSettings()?.machineID)

        try await MachineSyncManager.forget(machineID: deskID, environment: laptop.environment)

        let delete = try #require(laptop.server.requests.last { $0.httpMethod == "DELETE" })
        #expect(delete.url?.path.hasSuffix("/machines/\(deskID)") == true)
        #expect(delete.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(laptop.server.blob(machineID: deskID, name: "profile") == nil)
        #expect(try laptop.store.loadCache()?.machines[deskID] == nil)
        let status = try await laptop.status()
        #expect(status.machines.map(\.displayName) == ["test-host"])
        #expect(status.total.today.costUSD == 2)
    }

    // MARK: Leave

    @Test
    func `leave unpairs locally, keeps server data, and re-pairing restores the same Machine`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let link = try MachineSyncManager.pairingLink(environment: desk.environment)
        let before = try #require(try desk.store.loadSettings())
        _ = try await desk.status()
        let requestsBefore = desk.server.requests.count

        let left = try MachineSyncManager.leave(environment: desk.environment)

        #expect(desk.server.requests.count == requestsBefore)
        #expect(left.pairingLink == nil)
        #expect(try desk.store.loadSettings() == MachineSyncSettings(
            machineID: before.machineID,
            displayName: "desk"))
        #expect(!FileManager.default.fileExists(atPath: desk.store.stateURL.path))
        #expect(!FileManager.default.fileExists(atPath: desk.store.cacheURL.path))
        #expect(desk.server.blob(machineID: before.machineID, name: "profile") != nil)
        #expect(throws: MachineSyncError.notPaired) { try MachineSyncManager.pairingLink(environment: desk.environment)
        }
        await #expect(throws: MachineSyncError.notPaired) { try await desk.push() }

        let repaired = try await desk.pair(link.link)
        #expect(repaired.settings.machineID == before.machineID)
        #expect(repaired.settings.displayName == "desk")
    }

    @Test
    func `leave refuses while a push holds the lock, and when not paired`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let lock = try #require(try MachineSyncPushLock.acquire(at: desk.store.lockURL))
        #expect(throws: MachineSyncError.pushInProgress) { try MachineSyncManager.leave(environment: desk.environment) }
        #expect(try desk.store.loadSettings()?.pairingLink != nil)
        withExtendedLifetime(lock) {}

        let stranger = MachineSyncTestContext(now: Self.now)
        defer { stranger.cleanup() }
        #expect(throws: MachineSyncError.notPaired) { try MachineSyncManager.leave(environment: stranger.environment) }
    }

    // MARK: Rename

    @Test
    func `rename reaches the other Machines with the next push`() async throws {
        let (laptop, desk) = try await self.twoMachines()
        defer {
            laptop.cleanup()
            desk.cleanup()
        }
        let deskID = try #require(try desk.store.loadSettings()?.machineID)

        let settings = try MachineSyncManager.rename(to: "  study desk ", environment: desk.environment)
        let outcome = try await desk.push()

        #expect(settings.displayName == "study desk")
        #expect(try desk.store.loadSettings()?.displayName == "study desk")
        #expect(outcome == .pushed(uploaded: ["profile"], unchanged: 1))
        let row = try await laptop.status().machines.first { $0.machineId == deskID }
        #expect(row?.displayName == "study desk")
    }

    @Test
    func `rename needs a Machine ID first`() throws {
        let fresh = MachineSyncTestContext(now: Self.now)
        defer { fresh.cleanup() }
        #expect(throws: MachineSyncError.notPaired) {
            try MachineSyncManager.rename(to: "laptop", environment: fresh.environment)
        }
    }
}
