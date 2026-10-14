import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLICapabilitiesTests {
    private static let releaseVersion = "0.73.0+usagebar.1.1.0-rc.2"

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func runtime(
        healthVersion: String?,
        bindHost: String = "127.0.0.1",
        token: String? = nil) -> ServeRuntime
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLICapabilitiesTests-\(UUID().uuidString)", isDirectory: true)
        return ServeRuntime(
            configStore: CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: healthVersion,
            dashboardAuth: CLIServeDashboardAuth(bearer: token),
            bindHost: bindHost)
    }

    private static func request(_ method: String, _ target: String) throws -> CLILocalHTTPRequest {
        let raw = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        return try CLILocalHTTPRequest.parse(Data(raw.utf8)).get()
    }

    @Test
    func `machine sync is the first capability`() {
        #expect(CLICapability.allCases.first == .machineSync)
        #expect(CLICapabilitiesPayload(version: nil).capabilities == CLICapability.allCases)
    }

    @Test
    func `release versions split into upstream base and UsageBar version`() {
        let payload = CLICapabilitiesPayload(version: Self.releaseVersion)
        #expect(payload.version == Self.releaseVersion)
        #expect(payload.upstreamBase == "0.73.0")
        #expect(payload.usagebarVersion == "1.1.0-rc.2")
    }

    @Test
    func `other versions report neither half`() {
        for version in ["0.73.0", "+usagebar.1.1.0", "0.73.0+usagebar.", "0.73.0+build.5"] {
            let payload = CLICapabilitiesPayload(version: version)
            #expect(payload.version == version)
            #expect(payload.upstreamBase == nil)
            #expect(payload.usagebarVersion == nil)
        }
    }

    @Test
    func `health keeps status and version and adds capabilities`() async throws {
        let response = try await CodexBarCLI.handleServeRequest(
            Self.request("GET", "/health"),
            runtime: Self.runtime(healthVersion: Self.releaseVersion))
        #expect(response.status == .ok)
        #expect(!response.extraHeaders.contains { $0.0 == "Cache-Control" })
        let object = try Self.object(response.body)
        #expect(object["status"] as? String == "ok")
        #expect(object["version"] as? String == Self.releaseVersion)
        #expect(object["upstreamBase"] as? String == "0.73.0")
        #expect(object["usagebarVersion"] as? String == "1.1.0-rc.2")
        #expect(object["capabilities"] as? [String] == ["machineSync"])
    }

    @Test
    func `health without a version keeps upstream's shape plus capabilities`() async throws {
        let response = try await CodexBarCLI.handleServeRequest(
            Self.request("GET", "/health"),
            runtime: Self.runtime(healthVersion: nil))
        let object = try Self.object(response.body)
        #expect(Set(object.keys) == ["status", "capabilities"])
        #expect(object["capabilities"] as? [String] == ["machineSync"])
    }

    @Test
    func `health stays open on non-loopback binds`() async throws {
        let response = try await CodexBarCLI.handleServeRequest(
            Self.request("GET", "/health"),
            runtime: Self.runtime(healthVersion: Self.releaseVersion, bindHost: "0.0.0.0", token: "secret"))
        #expect(response.status == .ok)
        #expect(try Self.object(response.body)["capabilities"] as? [String] == ["machineSync"])
    }

    @Test
    func `health with the wrong method still gets upstream's 405`() async throws {
        let runtime = Self.runtime(healthVersion: Self.releaseVersion)
        #expect(try await CodexBarCLI.forkServeResponse(Self.request("POST", "/health"), runtime: runtime) == nil)
        let response = try await CodexBarCLI.handleServeRequest(Self.request("POST", "/health"), runtime: runtime)
        #expect(response.status == .methodNotAllowed)
    }

    @Test
    func `version json needs the json flag`() {
        #expect(CodexBarCLI.forkVersionJSON(argv: ["usage", "--version"], version: Self.releaseVersion) == nil)
        #expect(CodexBarCLI.forkVersionJSON(argv: ["usage", "-V", "--json"], version: Self.releaseVersion) != nil)
    }

    @Test
    func `version json and health agree`() async throws {
        for version in [Self.releaseVersion, "0.73.0", nil] {
            let json = try #require(CodexBarCLI.forkVersionJSON(
                argv: ["usage", "--version", "--json"],
                version: version))
            let cli = try Self.object(Data(json.utf8))
            let response = try await CodexBarCLI.handleServeRequest(
                Self.request("GET", "/health"),
                runtime: Self.runtime(healthVersion: version))
            var health = try Self.object(response.body)
            #expect(health.removeValue(forKey: "status") as? String == "ok")
            #expect(NSDictionary(dictionary: cli).isEqual(to: health))
            #expect(cli["capabilities"] as? [String] == CLICapability.allCases.map(\.rawValue))
        }
    }
}
