import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct MachineSyncCreateTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    @Test
    func `create registers the derived group and saves the Pairing Link`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.enrollment = "required"

        let result = try await context.create(token: " tok_123 ")

        let post = try #require(context.server.requests.first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Enrollment tok_123")
        let httpBody = try #require(post.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: String])
        #expect(body["groupId"] == result.link.keys.groupIDBase64URL)
        #expect(body["authKeyHash"] == result.link.keys.authKeyHashBase64URL)
        #expect(!result.link.link.contains("tok_123"))

        let settings = try #require(try context.store.loadSettings())
        #expect(settings.pairingLink == result.link.link)
        #expect(settings.displayName == "test-host")
        #expect(MachineSyncMachineID.isValid(settings.machineID))
        let savedLink = try #require(settings.pairingLink)
        #expect(try MachineSyncPairingLink(parsing: savedLink).apiBaseURL == "https://sync.example.com/base/v1")
        let attributes = try FileManager.default.attributesOfItem(atPath: context.store.settingsURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func `open servers get no Enrollment header`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        try await context.create(token: "tok_123")

        let post = try #require(context.server.requests.first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `a required token is asked for before creating anything`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.enrollment = "required"

        await #expect(throws: MachineSyncError.enrollmentTokenRequired) { try await context.create() }
        #expect(context.server.requests.map(\.httpMethod) == ["GET"])
        #expect(try context.store.loadSettings() == nil)
    }

    @Test(arguments: [
        ("enrollment_invalid", 403, "isn't valid"),
        ("enrollment_expired", 403, "expired"),
        ("enrollment_used", 403, "already created a Sync Group"),
        ("enrollment_required", 402, "requires an Enrollment Token"),
    ])
    func `enrollment errors become clear messages`(code: String, status: Int, phrase: String) async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.enrollment = "optional"
        context.server.failPost(with: .init(status: status, code: code))

        do {
            try await context.create(token: "tok_bad")
            Issue.record("create should have failed")
        } catch let error as MachineSyncError {
            #expect(error.errorDescription?.contains(phrase) == true)
            #expect(error.errorDescription?.contains("server says no") == false)
        }
        #expect(try context.store.loadSettings() == nil)
    }

    @Test
    func `unknown server errors fall back to the server message`() {
        let error = MachineSyncError.server(status: 500, code: "internal_error", message: "boom", retryAfter: nil)
        #expect(error.errorDescription == "The Sync Server returned HTTP 500: boom.")
    }

    @Test
    func `servers without protocol v1 are refused`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.server.protocols = [2]

        await #expect(throws: MachineSyncError.unsupportedServer) { try await context.create() }
        #expect(context.server.requests.count == 1)
    }

    @Test
    func `invalid server addresses fail without network calls`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        await #expect(throws: MachineSyncPairingLinkError.unsupportedScheme) {
            try await MachineSyncGroupCreator.create(
                serverURL: "sync.example.com",
                enrollmentToken: nil,
                displayName: nil,
                environment: context.environment)
        }
        #expect(context.server.requests.isEmpty)
    }

    @Test
    func `a paired Machine can't create a second group`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        try await context.create()
        let requests = context.server.requests.count

        await #expect(throws: MachineSyncError.alreadyPaired) { try await context.create() }
        #expect(context.server.requests.count == requests)
    }

    @Test
    func `the Machine ID survives leaving and re-creating`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        try context.store.saveSettings(MachineSyncSettings(machineID: "oKGio6SlpqeoqaqrrK2urw", displayName: "desk"))

        let result = try await MachineSyncGroupCreator.create(
            serverURL: "http://127.0.0.1:8787",
            enrollmentToken: nil,
            displayName: nil,
            environment: context.environment)

        #expect(result.settings.machineID == "oKGio6SlpqeoqaqrrK2urw")
        #expect(result.settings.displayName == "desk")
        #expect(result.link.link.hasPrefix("codexbar-sync+http://127.0.0.1:8787#"))
        #expect(!result.link.cleartextWarning)
    }
}
