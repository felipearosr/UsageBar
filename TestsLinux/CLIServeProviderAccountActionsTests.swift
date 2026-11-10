import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// serve's Provider Account action routes: `/accounts/kinds`, `/accounts/add`, `/accounts/rename` and
/// `/accounts/remove`. Each test writes a temporary config file; tokens are fake strings, and no test reaches a
/// provider (the one `/usage` check uses a stub fetch).
struct CLIServeProviderAccountActionsTests {
    private static let personalID = UUID(uuidString: "6F0C2A9E-1B4D-4C8A-9E2F-0A1B2C3D4E5F")!
    private static let workID = UUID(uuidString: "0D9E8F7A-6B5C-4D3E-8F1A-2B3C4D5E6F70")!
    private static let personalAccountID = "token:6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f"
    private static let workAccountID = "token:0d9e8f7a-6b5c-4d3e-8f1a-2b3c4d5e6f70"
    /// A token no response or failure message may ever contain. Tests compare bytes against it and never print it.
    private static let secret = "fake-secret-0123456789abcdef"

    private static func account(_ id: UUID, _ label: String, token: String? = nil) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: label, token: token ?? "fake-\(label)", addedAt: 0, lastUsed: nil)
    }

    private static let twoAccounts = [account(personalID, "Personal"), account(workID, "Work")]

    private static func config(
        _ accounts: [ProviderTokenAccount],
        provider: UsageProvider = .openrouter,
        activeIndex: Int = 0) -> CodexBarConfig
    {
        CodexBarConfig(providers: [ProviderConfig(
            id: provider.instanceID,
            enabled: true,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: activeIndex))])
    }

    private static func runtime(
        config: CodexBarConfig? = nil,
        bindHost: String = "127.0.0.1",
        token: String? = nil) throws -> ServeRuntime
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeProviderAccountActionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        if let config { try store.save(config) }
        return ServeRuntime(
            configStore: store,
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: nil,
            dashboardAuth: CLIServeDashboardAuth(bearer: token),
            bindHost: bindHost)
    }

    /// A raw request through upstream's parser, so the body and headers arrive as they would on the wire.
    private static func request(
        _ target: String,
        method: String = "POST",
        json: [String: Any]? = nil,
        rawBody: String? = nil,
        contentType: String? = "application/json",
        extraHeaders: [String] = []) throws -> CLILocalHTTPRequest
    {
        let body = try rawBody ?? json.map { try String(
            decoding: JSONSerialization.data(withJSONObject: $0),
            as: UTF8.self) }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if body != nil, let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let body { head += "Content-Length: \(body.utf8.count)\r\n" }
        for header in extraHeaders {
            head += "\(header)\r\n"
        }
        return try CLILocalHTTPRequest.parse(Data((head + "\r\n" + (body ?? "")).utf8)).get()
    }

    private static func send(_ request: CLILocalHTTPRequest, _ runtime: ServeRuntime) async throws
        -> CLILocalHTTPResponse
    {
        let response = await CodexBarCLI.forkServeResponse(request, runtime: runtime)
        return try #require(response)
    }

    private static func object(_ response: CLILocalHTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private static func accounts(_ runtime: ServeRuntime, _ provider: UsageProvider = .openrouter) throws
        -> ProviderTokenAccountData?
    {
        try runtime.configStore.load()?.providerConfig(for: provider.instanceID)?.tokenAccounts
    }

    /// True when `data` holds `secret`. Only the result is asserted, so a failure never prints the secret.
    private static func leaks(_ data: Data) -> Bool {
        data.range(of: Data(self.secret.utf8)) != nil
    }

    // MARK: Routes

    @Test
    func `account routes answer only their own method`() async throws {
        let runtime = try Self.runtime()
        for target in ["/accounts/add", "/accounts/rename", "/accounts/remove"] {
            let response = try await Self.send(Self.request(target, method: "GET"), runtime)
            #expect(response.status == .methodNotAllowed)
        }
        let kinds = try await Self.send(Self.request("/accounts/kinds", method: "POST", json: [:]), runtime)
        #expect(kinds.status == .methodNotAllowed)
        #expect(try await CodexBarCLI.forkServeResponse(Self.request("/accounts", method: "GET"), runtime: runtime)
            == nil)
    }

    @Test
    func `kinds report key for token account providers and nothing for the rest`() async throws {
        let response = try await Self.send(Self.request("/accounts/kinds", method: "GET"), Self.runtime())
        #expect(response.status == .ok)
        #expect(response.extraHeaders.contains { $0 == ("Cache-Control", "no-store") })
        let providers = try #require(Self.object(response)["providers"] as? [String: [String: Any]])
        let openrouter = try #require(providers["openrouter"])
        #expect(openrouter["kind"] as? String == "key")
        #expect((openrouter["placeholder"] as? String)?.isEmpty == false)
        #expect(providers["copilot"]?["kind"] as? String == "key")
        // No token accounts at all, and the providers whose accounts come from a login flow.
        for provider in ["gemini", "codex", "claude", "antigravity"] {
            #expect(providers[provider] == nil, "\(provider)")
        }
        for provider in UsageProvider.allCases where TokenAccountSupportCatalog.support(for: provider) == nil {
            #expect(providers[provider.rawValue] == nil, "\(provider.rawValue)")
        }
    }

    // MARK: Add

    @Test
    func `add stores a labelled token and the next usage shows its row`() async throws {
        let runtime = try Self.runtime(config: Self.config([Self.account(Self.personalID, "Personal")]))
        let response = try await Self.send(Self.request("/accounts/add", json: [
            "provider": "openrouter", "label": "  Work  ", "token": "  \(Self.secret)\n",
        ]), runtime)
        #expect(response.status == .ok)
        #expect(!Self.leaks(response.body))
        let object = try Self.object(response)
        #expect(object["provider"] as? String == "openrouter")
        #expect(object["accountLabel"] as? String == "Work")
        #expect(object["active"] as? Bool == true)
        #expect(object["token"] == nil)

        let stored = try #require(try Self.accounts(runtime))
        #expect(stored.accounts.map(\.label) == ["Personal", "Work"])
        #expect(stored.accounts.last?.token == Self.secret)
        #expect(stored.activeIndex == 1)
        let newID = try #require(stored.accounts.last?.id)
        #expect(object["accountId"] as? String == "token:\(newID.uuidString.lowercased())")

        // The next /usage?accounts=all answers one row per account, the new one included.
        let snapshot = try CodexBarCLI.loadServeConfigSnapshot(configStore: runtime.configStore)
        let usage = await CodexBarCLI.serveProviderAccountUsage(
            provider: "openrouter",
            context: ServeUsageContext(
                config: snapshot.config,
                configFingerprint: snapshot.cacheToken,
                refreshInterval: 60,
                providerTimeout: nil,
                providerDeadline: nil,
                providerOperations: CLIServeOperationCoordinator()))
        { provider, _ in
            var output = UsageCommandOutput()
            output.payload.append(ProviderPayload(
                provider: provider,
                account: nil,
                cacheAccountKey: nil,
                version: nil,
                source: "api",
                status: nil,
                usage: UsageSnapshot(
                    primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil))
            return output
        }
        let rows = try #require(JSONSerialization.jsonObject(with: usage.body) as? [[String: Any]])
        #expect(rows.map { $0["accountId"] as? String } == [Self.personalAccountID, object["accountId"] as? String])
        #expect(rows.map { $0["accountLabel"] as? String } == ["Personal", "Work"])
        #expect(!Self.leaks(usage.body))
    }

    @Test
    func `add without a label names the account and creates a missing config`() async throws {
        let runtime = try Self.runtime()
        let response = try await Self.send(Self.request("/accounts/add", json: [
            "provider": "openrouter", "token": Self.secret,
        ]), runtime)
        #expect(response.status == .ok)
        #expect(try Self.object(response)["accountLabel"] as? String == "Account 1")
        #expect(try Self.accounts(runtime)?.accounts.map(\.label) == ["Account 1"])
    }

    @Test
    func `add refuses bad input without echoing the token`() async throws {
        let runtime = try Self.runtime(config: Self.config(Self.twoAccounts))
        let cases: [(CLILocalHTTPRequest, CLIHTTPStatus)] = try [
            (Self.request("/accounts/add", json: ["provider": "nope", "token": Self.secret]), .badRequest),
            (Self.request("/accounts/add", json: ["provider": "gemini", "token": Self.secret]), .badRequest),
            (Self.request("/accounts/add", json: ["provider": "claude", "token": Self.secret]), .badRequest),
            (Self.request("/accounts/add", json: ["provider": "openrouter", "token": "   "]), .badRequest),
            (Self.request("/accounts/add", json: [
                "provider": "openrouter", "token": Self.secret, "label": String(repeating: "x", count: 101),
            ]), .badRequest),
            // The token in a body the decoder rejects (a number label, broken JSON).
            (
                Self.request("/accounts/add", json: ["provider": "openrouter", "token": Self.secret, "label": 7]),
                .badRequest),
            (
                Self.request("/accounts/add", rawBody: #"{"provider":"openrouter","token":"\#(Self.secret)""#),
                .badRequest),
            (Self.request(
                "/accounts/add",
                json: ["provider": "openrouter", "token": Self.secret],
                contentType: "text/plain"), .badRequest),
            (Self.request(
                "/accounts/add",
                json: ["provider": "openrouter", "token": Self.secret],
                contentType: nil), .badRequest),
            (Self.request(
                "/accounts/add",
                json: ["provider": "openrouter", "token": Self.secret],
                extraHeaders: ["Origin: http://127.0.0.1:8080"]), .forbidden),
        ]
        for (request, status) in cases {
            let response = try await Self.send(request, runtime)
            #expect(response.status == status)
            #expect(!Self.leaks(response.body))
            #expect((try? Self.object(response)["error"] as? String)?.isEmpty == false)
        }
        // Nothing was written.
        #expect(try Self.accounts(runtime)?.accounts.map(\.label) == ["Personal", "Work"])
    }

    @Test
    func `non loopback binds need the dashboard token for every account route`() async throws {
        let runtime = try Self.runtime(config: Self.config(Self.twoAccounts), bindHost: "0.0.0.0", token: "secret")
        for request in try [
            Self.request("/accounts/kinds", method: "GET"),
            Self.request("/accounts/add", json: ["provider": "openrouter", "token": Self.secret]),
            Self.request("/accounts/rename", json: [
                "provider": "openrouter", "accountId": Self.workAccountID, "label": "Job",
            ]),
            Self.request("/accounts/remove", json: ["provider": "openrouter", "accountId": Self.workAccountID]),
        ] {
            #expect(try await Self.send(request, runtime).status == .unauthorized)
        }
        let authorized = try await Self.send(Self.request(
            "/accounts/rename",
            json: ["provider": "openrouter", "accountId": Self.workAccountID, "label": "Job"],
            extraHeaders: ["Authorization: Bearer secret"]), runtime)
        #expect(authorized.status == .ok)
        #expect(try Self.accounts(runtime)?.accounts.map(\.label) == ["Personal", "Job"])
    }

    // MARK: Rename and remove

    @Test
    func `rename changes only the targeted account`() async throws {
        let third = Self.account(UUID(), "Spare")
        let runtime = try Self.runtime(config: Self.config(Self.twoAccounts + [third], activeIndex: 1))
        let before = try #require(try Self.accounts(runtime))
        let response = try await Self.send(Self.request("/accounts/rename", json: [
            "provider": "openrouter", "accountId": Self.personalAccountID, "label": " Home ",
        ]), runtime)
        #expect(response.status == .ok)
        let object = try Self.object(response)
        #expect(object["accountId"] as? String == Self.personalAccountID)
        #expect(object["accountLabel"] as? String == "Home")
        #expect(object["active"] as? Bool == false)

        let after = try #require(try Self.accounts(runtime))
        #expect(after.accounts.map(\.label) == ["Home", "Work", "Spare"])
        #expect(after.accounts.map(\.id) == before.accounts.map(\.id))
        #expect(after.accounts.map(\.token) == before.accounts.map(\.token))
        #expect(after.accounts.map(\.addedAt) == before.accounts.map(\.addedAt))
        #expect(after.activeIndex == 1)
    }

    @Test
    func `remove deletes only the targeted account and keeps the active one`() async throws {
        let third = Self.account(UUID(), "Spare")
        let runtime = try Self.runtime(config: Self.config(Self.twoAccounts + [third], activeIndex: 1))
        let response = try await Self.send(Self.request("/accounts/remove", json: [
            "provider": "openrouter", "accountId": Self.personalAccountID,
        ]), runtime)
        #expect(response.status == .ok)
        let object = try Self.object(response)
        #expect(object["accountId"] as? String == Self.personalAccountID)
        #expect(object["removed"] as? Bool == true)

        let after = try #require(try Self.accounts(runtime))
        #expect(after.accounts.map(\.id) == [Self.workID, third.id])
        #expect(after.accounts.map(\.token) == ["fake-Work", "fake-Spare"])
        // Work was active and still is, now at index 0.
        #expect(after.activeIndex == 0)
    }

    @Test
    func `removing the active account activates its neighbour and the last one clears the store`() async throws {
        let runtime = try Self.runtime(config: Self.config(Self.twoAccounts, activeIndex: 1))
        _ = try await Self.send(Self.request("/accounts/remove", json: [
            "provider": "openrouter", "accountId": Self.workAccountID,
        ]), runtime)
        let after = try #require(try Self.accounts(runtime))
        #expect(after.accounts.map(\.label) == ["Personal"])
        #expect(after.activeIndex == 0)

        _ = try await Self.send(Self.request("/accounts/remove", json: [
            "provider": "openrouter", "accountId": Self.personalAccountID,
        ]), runtime)
        #expect(try Self.accounts(runtime) == nil)
    }

    @Test
    func `rename and remove reject unknown ids`() async throws {
        let config = Self.config(Self.twoAccounts)
        let runtime = try Self.runtime(config: config)
        let unknown = [
            "token:\(UUID().uuidString.lowercased())",
            "token:not-a-uuid",
            "6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f",
            "codex-home:6f0c2a9e-1b4d-4c8a-9e2f-0a1b2c3d4e5f",
            "",
        ]
        for accountID in unknown {
            let rename = try await Self.send(Self.request("/accounts/rename", json: [
                "provider": "openrouter", "accountId": accountID, "label": "X",
            ]), runtime)
            #expect(rename.status == .notFound, "\(accountID)")
            let remove = try await Self.send(Self.request("/accounts/remove", json: [
                "provider": "openrouter", "accountId": accountID,
            ]), runtime)
            #expect(remove.status == .notFound, "\(accountID)")
        }
        // A real id under another provider is unknown there.
        let elsewhere = try await Self.send(Self.request("/accounts/remove", json: [
            "provider": "copilot", "accountId": Self.workAccountID,
        ]), runtime)
        #expect(elsewhere.status == .notFound)
        let blank = try await Self.send(Self.request("/accounts/rename", json: [
            "provider": "openrouter", "accountId": Self.workAccountID, "label": "  ",
        ]), runtime)
        #expect(blank.status == .badRequest)
        #expect(try Self.accounts(runtime)?.accounts.map(\.label) == ["Personal", "Work"])
    }

    @Test
    func `health advertises each account action`() async throws {
        let response = try await CodexBarCLI.handleServeRequest(
            Self.request("/health", method: "GET"),
            runtime: Self.runtime())
        let object = try Self.object(response)
        let capabilities = try #require(object["capabilities"] as? [String])
        for name in [
            "providerAccountKinds",
            "providerAccountAddKey",
            "providerAccountRename",
            "providerAccountRemove",
        ] {
            #expect(capabilities.contains(name), "\(name)")
        }
    }

    // MARK: Editor

    @Test
    func `the editor names blank labels Account N and makes each new account active`() throws {
        var config = CodexBarConfig(providers: [ProviderConfig(id: UsageProvider.openrouter.instanceID)])
        let first = ProviderTokenAccountEditor.add(
            to: &config, provider: .openrouter, label: nil, token: "fake-a", addedAt: 1)
        let second = ProviderTokenAccountEditor.add(
            to: &config, provider: .openrouter, label: nil, token: "fake-b", addedAt: 2)
        #expect(first.label == "Account 1")
        #expect(second.label == "Account 2")
        let data = try #require(config.providerConfig(for: UsageProvider.openrouter.instanceID)?.tokenAccounts)
        #expect(second.accountID == "token:\(data.accounts[1].id.uuidString.lowercased())")
        #expect(data.activeIndex == 1)
        #expect(data.accounts.map(\.addedAt) == [1, 2])

        // Copilot's token accounts replace its single API key, as in the app.
        var copilot = CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.copilot.instanceID,
            apiKey: "fake-copilot-key")])
        _ = ProviderTokenAccountEditor.add(to: &copilot, provider: .copilot, label: "Work", token: "fake-c", addedAt: 3)
        #expect(copilot.providerConfig(for: UsageProvider.copilot.instanceID)?.apiKey == nil)
    }
}

// Request bodies through upstream's socket server: the head's `Content-Length` decides how much body serve reads.
#if canImport(Glibc)
@Suite(.serialized)
struct CLILocalHTTPServerBodyLinuxTests {
    /// Echoes the body length and content type, so the test sees what the handler got.
    private static func withServer(_ body: (UInt16) async throws -> Void) async throws {
        let listening = DispatchSemaphore(value: 0)
        let server = CLILocalHTTPServer(host: "127.0.0.1", port: 0, allowedHosts: .loopbackOnly) { request in
            let echo = [
                "bytes": "\(request.body.count)",
                "json": request.forkFields.contentType == "application/json" ? "yes" : "no",
            ]
            let data = try? JSONSerialization.data(withJSONObject: echo)
            return CLILocalHTTPResponse(status: .ok, body: data ?? Data())
        }
        let task = Task { try await server.run { listening.signal() } }
        defer {
            server.stop()
            task.cancel()
        }
        let didListen = await Self.onBackgroundThread { listening.wait(timeout: .now() + 60) == .success }
        try #require(didListen)
        try await body(#require(server.listeningPort))
    }

    private static func onBackgroundThread<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async
        -> Value
    {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: operation()) }
        }
    }

    /// Sends `parts` one after another (with a pause between them) and reads the response to EOF.
    private static func exchange(port: UInt16, _ parts: [String]) async -> String {
        await self.onBackgroundThread {
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            guard fd >= 0 else { return "" }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return "" }
            for (index, part) in parts.enumerated() {
                if index > 0 { usleep(200_000) }
                let bytes = Array(part.utf8)
                _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    @Test
    func `a body that arrives after the head is read in full`() async throws {
        let body = #"{"provider":"openrouter","token":"fake"}"#
        try await Self.withServer { port in
            let response = await Self.exchange(port: port, [
                "POST /accounts/add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n" +
                    "Content-Length: \(body.utf8.count)\r\n\r\n",
                body,
            ])
            #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(response.contains(#""bytes":"\#(body.utf8.count)""#))
            #expect(response.contains(#""json":"yes""#))
        }
    }

    @Test
    func `requests without a body and with an oversized one`() async throws {
        try await Self.withServer { port in
            let plain = await Self.exchange(port: port, ["GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"])
            #expect(plain.hasPrefix("HTTP/1.1 200 OK\r\n"))
            #expect(plain.contains(#""bytes":"0""#))

            let tooLarge = CLILocalHTTPRequestForkFields.maximumBodyBytes + 1
            let oversized = await Self.exchange(port: port, [
                "POST /accounts/add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(tooLarge)\r\n\r\n",
            ])
            #expect(oversized.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))

            let conflicting = await Self.exchange(port: port, [
                "POST /accounts/add HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
            ])
            #expect(conflicting.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        }
    }
}
#endif
