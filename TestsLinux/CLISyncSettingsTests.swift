import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLISyncSettingsTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    private static func json(_ value: some Encodable) throws -> [String: Any] {
        let text = try #require(CodexBarCLI.encodeJSON(value, pretty: false))
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: Error reasons

    @Test
    func `errors carry a reason surfaces can explain`() {
        let limit = MachineSyncError.server(status: 403, code: "machine_limit", message: nil, retryAfter: nil)
        #expect(CodexBarCLI.syncErrorReason(limit) == "machine_limit")
        let expired = MachineSyncError.server(status: 403, code: "enrollment_expired", message: nil, retryAfter: nil)
        #expect(CodexBarCLI.syncErrorReason(expired) == "enrollment_expired")
        let bare = MachineSyncError.server(status: 500, code: nil, message: nil, retryAfter: nil)
        #expect(CodexBarCLI.syncErrorReason(bare) == "http_500")
        #expect(CodexBarCLI.syncErrorReason(MachineSyncError.enrollmentTokenRequired) == "enrollment_required")
        #expect(CodexBarCLI.syncErrorReason(MachineSyncError.cleartextNotConfirmed(host: "nas"))
            == "cleartext_not_confirmed")
        #expect(CodexBarCLI.syncErrorReason(MachineSyncError.network("offline")) == "network")
        #expect(CodexBarCLI.syncErrorReason(MachineSyncPairingLinkError.invalidHost) == "invalid_address")
        #expect(CodexBarCLI.syncErrorReason(MachineSyncPairingLinkError.invalidRootKey) == "invalid_key")
        #expect(CodexBarCLI.syncErrorReason(CocoaError(.fileReadCorruptFile)) == nil)
    }

    @Test
    func `JSON errors include the reason only when there is one`() throws {
        let withReason = try #require(CodexBarCLI.makeCLIErrorPayload(
            message: "This Sync Group has reached its Machine limit.",
            code: .failure,
            kind: .runtime,
            reason: "machine_limit",
            pretty: false))
        #expect(withReason.contains(#""reason":"machine_limit""#))

        let without = try #require(CodexBarCLI.makeCLIErrorPayload(
            message: "Missing --server <url>.",
            code: .failure,
            kind: .args,
            pretty: false))
        #expect(!without.contains("reason"))
    }

    // MARK: sync info

    @Test
    func `info reports whether the server wants an Enrollment Token`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        for enrollment in ["none", "optional", "required"] {
            context.server.enrollment = enrollment
            let result = try await MachineSyncServerProbe.info(
                serverURL: " https://sync.example.com/base/ ",
                environment: context.environment)
            #expect(result.info.enrollment == enrollment)
            #expect(result.baseURL == "https://sync.example.com/base")
            #expect(result.supported)
            #expect(!result.cleartextWarning)
        }
        // Only the unauthenticated info endpoint; no group is created.
        #expect(context.server.requests.allSatisfy { $0.url?.path == "/base/v1/info" && $0.httpMethod == "GET" })
        #expect(context.server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(try context.store.loadSettings() == nil)
    }

    @Test
    func `info payload flags plain http and unsupported servers`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.enrollment = "optional"
        context.server.protocols = [2]

        let result = try await MachineSyncServerProbe.info(
            serverURL: "http://nas.lan:8080",
            environment: context.environment)
        let object = try Self.json(SyncInfoPayload(result))
        #expect(object["server"] as? String == "http://nas.lan:8080")
        #expect(object["host"] as? String == "nas.lan")
        #expect(object["enrollment"] as? String == "optional")
        #expect(object["supported"] as? Bool == false)
        #expect(object["cleartextWarning"] as? Bool == true)
        #expect(object["retentionDays"] as? Int == 400)
        #expect(CodexBarCLI.syncInfoText(result).contains("Enrollment Token is optional"))

        let loopback = try await MachineSyncServerProbe.info(
            serverURL: "http://127.0.0.1:8787",
            environment: context.environment)
        #expect(!loopback.cleartextWarning)
    }

    @Test
    func `info rejects a bad address before any request`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        await #expect(throws: MachineSyncPairingLinkError.unsupportedScheme) {
            try await MachineSyncServerProbe.info(serverURL: "sync.example.com", environment: context.environment)
        }
        #expect(context.server.requests.isEmpty)
    }

    // MARK: sync settings

    @Test
    func `settings payload shows the server but never the Pairing Link`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        #expect(try Self.json(SyncSettingsPayload(nil))["paired"] as? Bool == false)

        let created = try await context.create()
        let settings = try context.store.loadSettings()
        let text = try #require(CodexBarCLI.encodeJSON(SyncSettingsPayload(settings), pretty: false))
        #expect(!text.contains(created.link.link))
        #expect(!text.contains(created.link.rootKey.base64URL))
        #expect(!text.contains("codexbar-sync"))

        let object = try Self.json(SyncSettingsPayload(settings))
        #expect(object["paired"] as? Bool == true)
        #expect(object["server"] as? String == "https://sync.example.com/base")
        #expect(object["displayName"] as? String == "test-host")
        let day = try #require(object["reportingDay"] as? [String: Any])
        #expect(day["timeZone"] == nil)
        #expect(day["startHour"] as? Int == 0)
        #expect(day["effectiveTimeZone"] is String)
    }

    @Test
    func `reporting day is saved, kept across leave, and can be reset`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        // Unpaired and never set up: saving creates the settings file.
        let saved = try MachineSyncManager.setReportingDay(
            MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4),
            environment: context.environment)
        #expect(saved.pairingLink == nil)
        #expect(try context.store.loadSettings()?.reportingDay
            == MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4))

        try await context.create()
        #expect(try context.store.loadSettings()?.machineID == saved.machineID)
        try MachineSyncManager.leave(environment: context.environment)
        #expect(try context.store.loadSettings()?.reportingDay?.startHour == 4)

        try MachineSyncManager.setReportingDay(nil, environment: context.environment)
        #expect(try context.store.loadSettings()?.reportingDay == nil)
    }

    @Test
    func `invalid reporting day is refused and nothing is written`() throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        #expect(throws: MachineSyncError.invalidReportingDay) {
            try MachineSyncManager.setReportingDay(
                MachineSyncReportingDay(timeZone: "Mars/Olympus", startHour: 0),
                environment: context.environment)
        }
        #expect(throws: MachineSyncError.invalidReportingDay) {
            try MachineSyncManager.setReportingDay(
                MachineSyncReportingDay(timeZone: nil, startHour: 24),
                environment: context.environment)
        }
        #expect(try context.store.loadSettings() == nil)
        #expect(MachineSyncError.invalidReportingDay.reason == "invalid_reporting_day")
    }

    @Test
    func `reporting day flags change only what they name`() throws {
        func change(
            _ options: [String: [String]],
            flags: Set<String> = [],
            current: MachineSyncReportingDay? = nil) throws -> SyncSettingChange<MachineSyncReportingDay?>?
        {
            try CodexBarCLI.syncReportingDayChange(
                ParsedValues(positional: [], options: options, flags: flags),
                current: current)
        }
        let berlin4 = MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 4)

        #expect(try change([:]) == nil)
        #expect(try change(["dayStart": ["6"]], current: berlin4)?.value
            == MachineSyncReportingDay(timeZone: "Europe/Berlin", startHour: 6))
        #expect(try change(["timezone": ["UTC"]], current: berlin4)?.value
            == MachineSyncReportingDay(timeZone: "UTC", startHour: 4))
        #expect(try change(["timezone": ["system"]], current: berlin4)?.value
            == MachineSyncReportingDay(timeZone: nil, startHour: 4))
        #expect(try change([:], flags: ["resetReportingDay"], current: berlin4).map { $0.value == nil } == true)
        #expect(throws: (any Error).self) { try change(["dayStart": ["six"]]) }
    }
}
