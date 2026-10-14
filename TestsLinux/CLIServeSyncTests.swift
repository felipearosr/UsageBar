import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIServeSyncTests {
    private static let now = MachineSyncTestContext.utc(2026, 9, 24, 12, 30)

    private static func object(_ response: CLILocalHTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private static func status(
        _ context: MachineSyncTestContext,
        refresh: Bool,
        coordinator: CLIServeSyncCoordinator = CLIServeSyncCoordinator()) async throws -> [String: Any]
    {
        let response = await CodexBarCLI.serveSyncStatus(
            refresh: refresh,
            environment: context.environment,
            coordinator: coordinator)
        #expect(response.status == .ok)
        return try self.object(response)
    }

    private static func runtime(bindHost: String = "127.0.0.1", token: String? = nil) -> ServeRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeSyncTests-\(UUID().uuidString)", isDirectory: true)
        return ServeRuntime(
            configStore: CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: nil,
            dashboardAuth: CLIServeDashboardAuth(bearer: token),
            bindHost: bindHost)
    }

    private static func request(
        _ method: String,
        _ target: String,
        authorization: String? = nil) throws -> CLILocalHTTPRequest
    {
        var raw = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let authorization { raw += "Authorization: \(authorization)\r\n" }
        raw += "\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    @Test
    func `routes sync status and push`() throws {
        #expect(try CLIServeSyncRoute.route(method: "GET", path: "/sync/status", queryItems: [:])
            == .syncStatus(refresh: false))
        #expect(try CLIServeSyncRoute.route(method: "GET", path: "/sync/status", queryItems: ["refresh": "1"])
            == .syncStatus(refresh: true))
        #expect(try CLIServeSyncRoute.route(method: "GET", path: "/sync/status", queryItems: ["refresh": "0"])
            == .syncStatus(refresh: false))
        #expect(try CLIServeSyncRoute.route(method: "post", path: "/sync/push", queryItems: [:]) == .syncPush)
        #expect(throws: CLIServeRouteError.methodNotAllowed) {
            try CLIServeSyncRoute.route(method: "GET", path: "/sync/push", queryItems: [:])
        }
        #expect(throws: CLIServeRouteError.methodNotAllowed) {
            try CLIServeSyncRoute.route(method: "POST", path: "/sync/status", queryItems: [:])
        }
        #expect(try CLIServeSyncRoute.route(method: "GET", path: "/usage", queryItems: [:]) == nil)
        #expect(try CLIServeSyncRoute.route(method: "GET", path: "/sync", queryItems: [:]) == nil)
    }

    @Test
    func `hook passes upstream routes through`() async throws {
        let runtime = Self.runtime()
        for target in ["/", "/health", "/usage", "/cost?days=7", "/sync", "/sync/other"] {
            #expect(try await CodexBarCLI.forkServeResponse(Self.request("GET", target), runtime: runtime) == nil)
        }
        #expect(try await CodexBarCLI.forkServeResponse(Self.request("POST", "/usage"), runtime: runtime) == nil)
    }

    @Test
    func `wrong method answers 405 before auth and without no-store`() async throws {
        let runtime = Self.runtime(bindHost: "0.0.0.0", token: "secret")
        for (method, target) in [("GET", "/sync/push"), ("POST", "/sync/status"), ("DELETE", "/sync/push")] {
            let response = try await CodexBarCLI.handleServeRequest(Self.request(method, target), runtime: runtime)
            #expect(response.status == .methodNotAllowed)
            #expect(try Self.object(response)["error"] as? String == "method not allowed")
            #expect(!response.extraHeaders.contains { $0.0 == "Cache-Control" })
        }
    }

    @Test
    func `non-loopback binds require the bearer token`() async throws {
        let runtime = Self.runtime(bindHost: "0.0.0.0", token: "secret")
        for (method, target) in [("GET", "/sync/status"), ("GET", "/sync/status?refresh=1"), ("POST", "/sync/push")] {
            for authorization in [nil, "Bearer wrong"] {
                let response = try await CodexBarCLI.handleServeRequest(
                    Self.request(method, target, authorization: authorization),
                    runtime: runtime)
                #expect(response.status == .unauthorized)
                #expect(response.extraHeaders.contains { $0 == ("WWW-Authenticate", "Bearer") })
                #expect(response.extraHeaders.contains { $0 == ("Cache-Control", "no-store") })
            }
        }
    }

    @Test
    func `upstream router no longer knows sync paths`() {
        #expect(throws: CLIServeRouteError.notFound) {
            try CLIServeRouter.route(method: "GET", path: "/sync/status", queryItems: [:])
        }
    }

    @Test
    func `status says not paired without touching the network`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }

        let object = try await Self.status(context, refresh: true)
        #expect(object["paired"] as? Bool == false)
        #expect(object["status"] == nil)
        #expect(context.server.requests.isEmpty)
    }

    @Test
    func `push then refresh shows this Machine`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: 2)]
        try await context.create()

        let coordinator = CLIServeSyncCoordinator()
        let push = await CodexBarCLI.serveSyncPush(environment: context.environment, coordinator: coordinator)
        #expect(push.status == .ok)
        #expect(try Self.object(push)["status"] as? String == "pushed")

        // Paired but never read: no status yet.
        let before = try await Self.status(context, refresh: false, coordinator: coordinator)
        #expect(before["paired"] as? Bool == true)
        #expect(before["status"] == nil)

        let object = try await Self.status(context, refresh: true, coordinator: coordinator)
        #expect(object["paired"] as? Bool == true)
        #expect(object["error"] == nil)
        #expect(object["refreshedAt"] as? String == "2026-09-24T12:30:00Z")
        let status = try #require(object["status"] as? [String: Any])
        let machines = try #require(status["machines"] as? [[String: Any]])
        #expect(machines.count == 1)
        #expect(machines.first?["isThisMachine"] as? Bool == true)
        #expect(machines.first?["active"] as? Bool == true)
    }

    @Test
    func `status without refresh reads only the cache`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        try await context.create()
        _ = try await context.push()
        _ = try await context.refresh()
        let requests = context.server.requests.count

        let object = try await Self.status(context, refresh: false)
        #expect(object["status"] is [String: Any])
        #expect(object["refreshedAt"] as? String == "2026-09-24T12:30:00Z")
        #expect(context.server.requests.count == requests)
    }

    @Test
    func `failed refresh keeps the last good data and says why`() async throws {
        var context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: 2)]
        try await context.create()
        _ = try await context.push()
        _ = try await context.refresh()

        context.now = Self.now.addingTimeInterval(600)
        context.server.failNextWithNetworkError()
        let object = try await Self.status(context, refresh: true)
        #expect(object["paired"] as? Bool == true)
        #expect((object["error"] as? String)?.contains("Couldn't reach the Sync Server") == true)
        // Still the time of the last successful read.
        #expect(object["refreshedAt"] as? String == "2026-09-24T12:30:00Z")
        let status = try #require(object["status"] as? [String: Any])
        let total = try #require(status["total"] as? [String: Any])
        let today = try #require(total["today"] as? [String: Any])
        #expect(today["costUSD"] as? Double == 2)
    }

    @Test
    func `status ignores a cache from another Sync Group`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        try await context.create()
        try context.store.saveCache(MachineSyncCache(groupID: "AAAAAAAAAAAAAAAAAAAAAA"))

        let object = try await Self.status(context, refresh: false)
        #expect(object["paired"] as? Bool == true)
        #expect(object["status"] == nil)
    }

    @Test
    func `push answers conflict when not paired and bad gateway when the server fails`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        let coordinator = CLIServeSyncCoordinator()

        let unpaired = await CodexBarCLI.serveSyncPush(environment: context.environment, coordinator: coordinator)
        #expect(unpaired.status == .conflict)

        try await context.create()
        context.server.failNext(FakeSyncServer.Failure(status: 403, code: "machine_limit"))
        let failed = await CodexBarCLI.serveSyncPush(environment: context.environment, coordinator: coordinator)
        #expect(failed.status == .badGateway)
        #expect(try Self.object(failed)["error"] is String)
    }

    @Test
    func `concurrent pushes share one cycle`() async throws {
        let context = MachineSyncTestContext(now: Self.now)
        defer { context.cleanup() }
        context.spend.buckets = [MachineSyncTestContext.bucket(MachineSyncTestContext.utc(2026, 9, 24, 9), cost: 2)]
        try await context.create()
        let coordinator = CLIServeSyncCoordinator()
        let environment = context.environment

        context.spend.holdNextScan()
        async let first = coordinator.push(environment: environment)
        await context.spend.waitUntilScanning()
        async let second = coordinator.push(environment: environment)
        // Give the second request time to reach the coordinator before the scan finishes.
        try await Task.sleep(nanoseconds: 50_000_000)
        context.spend.release()

        let outcomes = try await [first.get(), second.get()]
        // Without sharing, the overlapping request would lose the push lock and report `skippedLocked`.
        #expect(!outcomes.contains(.skippedLocked))
        #expect(context.server.putNames.count(where: { $0 == "profile" }) == 1)
    }
}
