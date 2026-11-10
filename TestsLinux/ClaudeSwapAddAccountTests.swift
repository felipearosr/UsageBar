import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Adding a Claude account through claude-swap (#172): the `codexbar claude add-account` flow, `cswap` detection, and
/// serve's `POST /accounts/claude-swap/detect`. Fake `cswap` and `claude` executables in a synthetic home record their
/// arguments to one shared log; no test runs a real `cswap`, `claude`, `uv` or `pipx`, or reads a credential.
struct ClaudeSwapAddAccountTests {
    private static let actionToken = "fake-action-token-for-tests"

    /// A synthetic home with an empty `~/.local/bin`, plus a log every fake appends `<name> <args…>` to.
    private struct SyntheticHome {
        let root: URL
        let log: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeSwapAddAccountTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: self.root.appendingPathComponent(".local/bin"),
                withIntermediateDirectories: true)
            self.log = self.root.appendingPathComponent("argv.log")
        }

        var home: String {
            self.root.path
        }

        /// A fake named `name` at `relativePath` (under the home) that logs its argv and exits with `status`.
        @discardableResult
        func installFake(_ name: String, at relativePath: String, exitStatus: Int32 = 0) throws -> String {
            let url = self.root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FakeExecutable.install("""
            #!/bin/sh
            printf '%s\\n' "\(name) $*" >> '\(self.log.path)'
            exit \(exitStatus)
            """, at: url)
            return url.path
        }

        var invocations: [String] {
            guard let text = try? String(contentsOf: self.log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        }
    }

    // MARK: Add flow

    @Test
    func `add runs cswap add then claude auth login then cswap add`() throws {
        let home = try SyntheticHome()
        let cswap = try home.installFake("cswap", at: ".local/bin/cswap")
        let claude = try home.installFake("claude", at: ".local/bin/claude")
        let flow = ClaudeSwapAddAccountFlow(cswapPath: cswap, claudePath: claude)
        #expect(flow.steps.map { [$0.executable] + $0.arguments } == [
            [cswap, "add"],
            [claude, "auth", "login"],
            [cswap, "add"],
        ])

        let outcome = flow.run(runner: ClaudeSwapAddAccountFlow.runInheritingTerminal)
        #expect(outcome == .done)
        #expect(ClaudeSwapAddAccountFlow.message(for: outcome) == "done")
        #expect(home.invocations == ["cswap add", "claude auth login", "cswap add"])
    }

    @Test
    func `add stops at the first failing step and names it`() throws {
        let home = try SyntheticHome()
        let cswap = try home.installFake("cswap", at: ".local/bin/cswap")
        let claude = try home.installFake("claude", at: ".local/bin/claude", exitStatus: 3)
        let flow = ClaudeSwapAddAccountFlow(cswapPath: cswap, claudePath: claude)

        let outcome = flow.run(runner: ClaudeSwapAddAccountFlow.runInheritingTerminal)
        guard case let .failed(index, step, reason) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(index == 2)
        #expect(step.arguments == ["auth", "login"])
        #expect(reason.contains("status 3"))
        let message = ClaudeSwapAddAccountFlow.message(for: outcome)
        #expect(message.hasPrefix("Step 2 of 3 failed"))
        #expect(message.contains("`claude auth login`"))
        // The second `cswap add` never ran.
        #expect(home.invocations == ["cswap add", "claude auth login"])
    }

    @Test
    func `add stops before signing in when the first cswap add fails`() throws {
        let home = try SyntheticHome()
        let cswap = try home.installFake("cswap", at: ".local/bin/cswap", exitStatus: 1)
        let claude = try home.installFake("claude", at: ".local/bin/claude")
        let outcome = ClaudeSwapAddAccountFlow(cswapPath: cswap, claudePath: claude)
            .run(runner: ClaudeSwapAddAccountFlow.runInheritingTerminal)
        #expect(ClaudeSwapAddAccountFlow.message(for: outcome).hasPrefix("Step 1 of 3 failed: `cswap add`"))
        #expect(home.invocations == ["cswap add"])
    }

    @Test
    func `a step that cannot start fails without running the rest`() throws {
        let home = try SyntheticHome()
        let claude = try home.installFake("claude", at: ".local/bin/claude")
        let missing = home.root.appendingPathComponent("missing/cswap").path
        let outcome = ClaudeSwapAddAccountFlow(cswapPath: missing, claudePath: claude)
            .run(runner: ClaudeSwapAddAccountFlow.runInheritingTerminal)
        #expect(ClaudeSwapAddAccountFlow.message(for: outcome).contains("could not start"))
        #expect(home.invocations.isEmpty)
    }

    @Test
    func `add never runs a logout command`() {
        var seen: [[String]] = []
        let flow = ClaudeSwapAddAccountFlow(cswapPath: "/fake/cswap", claudePath: "/fake/claude")
        _ = flow.run(runner: { executable, arguments in
            seen.append([executable] + arguments)
            return 0
        })
        #expect(seen.count == 3)
        for argv in seen + flow.steps.map({ [$0.executable] + $0.arguments }) {
            #expect(!argv.contains { $0.lowercased().contains("logout") }, "\(argv)")
            #expect(!argv.contains("/logout"))
        }
    }

    // MARK: Detect

    @Test
    func `detect finds cswap in the synthetic home's local bin and skips relative PATH entries`() throws {
        let home = try SyntheticHome()
        let path = try home.installFake("cswap", at: ".local/bin/cswap")
        // A relative PATH entry that would match from the right working directory is never used.
        let relative = try home.installFake("cswap", at: "relative/cswap")
        let environment = ["PATH": "relative:/nonexistent-usagebar-test"]
        #expect(!ClaudeSwapExecutableDetector.candidates(environment: environment, home: home.home)
            .contains { !$0.hasPrefix("/") })
        let found = ClaudeSwapExecutableDetector.detect(environment: environment, home: home.home)
        #expect(found == path)
        #expect(found != relative)
    }

    @Test
    func `detect finds cswap in uv's tool directory`() throws {
        let home = try SyntheticHome()
        let path = try home.installFake("cswap", at: ".local/share/uv/tools/claude-swap/bin/cswap")
        #expect(ClaudeSwapExecutableDetector.detect(environment: [:], home: home.home) == path)

        let custom = try home.installFake("cswap", at: "custom-tools/claude-swap/bin/cswap")
        let environment = ["UV_TOOL_DIR": home.root.appendingPathComponent("custom-tools").path]
        #expect(ClaudeSwapExecutableDetector.detect(environment: environment, home: home.home) == custom)
    }

    @Test
    func `detect reports nothing without a binary`() throws {
        let home = try SyntheticHome()
        #expect(ClaudeSwapExecutableDetector.detect(
            environment: ["PATH": "/nonexistent-usagebar-test"],
            home: home.home) == nil)
    }

    @Test
    func `detect saves the path and turns claude-swap on, then leaves the config alone`() async throws {
        let home = try SyntheticHome()
        let path = try home.installFake("cswap", at: ".local/bin/cswap")
        let store = CodexBarConfigStore(fileURL: home.root.appendingPathComponent("config/config.json"))

        let payload = try await CodexBarCLI.detectClaudeSwap(store: store, environment: [:], home: home.home)
        #expect(payload == ClaudeSwapDetectPayload(installed: true, executablePath: path, enabled: true, message: nil))
        let claude = try #require(try store.load()?.providerConfig(for: .claude))
        #expect(claude.claudeSwapEnabled == true)
        #expect(claude.claudeSwapExecutablePath == path)

        // A second detect finds the same binary and doesn't rewrite the file.
        let before = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(20))
        _ = try await CodexBarCLI.detectClaudeSwap(store: store, environment: [:], home: home.home)
        let after = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(home.invocations.isEmpty)
    }

    @Test
    func `detect without a binary reports not installed and writes nothing`() async throws {
        let home = try SyntheticHome()
        let store = CodexBarConfigStore(fileURL: home.root.appendingPathComponent("config/config.json"))
        let payload = try await CodexBarCLI.detectClaudeSwap(
            store: store,
            environment: ["PATH": "/nonexistent-usagebar-test"],
            home: home.home)
        #expect(!payload.installed)
        #expect(payload.executablePath == nil)
        #expect(payload.message == "claude-swap is not installed.")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test
    func `detect keeps a configured path that still resolves`() async throws {
        let home = try SyntheticHome()
        try home.installFake("cswap", at: ".local/bin/cswap")
        let configured = try home.installFake("cswap", at: "opt/cswap")
        let store = CodexBarConfigStore(fileURL: home.root.appendingPathComponent("config.json"))
        var entry = ProviderConfig(id: UsageProvider.claude.instanceID)
        entry.claudeSwapExecutablePath = configured
        try store.save(CodexBarConfig(providers: [entry]))

        let payload = try await CodexBarCLI.detectClaudeSwap(store: store, environment: [:], home: home.home)
        #expect(payload.executablePath == configured)
        #expect(try store.load()?.providerConfig(for: .claude)?.claudeSwapEnabled == true)
    }

    // MARK: Route

    private static func runtime(_ home: SyntheticHome) -> ServeRuntime {
        ServeRuntime(
            configStore: CodexBarConfigStore(fileURL: home.root.appendingPathComponent("config.json")),
            cache: CLIServeResponseCache(),
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: nil,
            dashboardAuth: CLIServeDashboardAuth(bearer: nil),
            bindHost: "127.0.0.1")
    }

    private static func send(
        _ method: String,
        headers: [String],
        home: SyntheticHome,
        runtime: ServeRuntime) async throws -> CLILocalHTTPResponse
    {
        var head = "\(method) /accounts/claude-swap/detect HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for header in headers {
            head += "\(header)\r\n"
        }
        let request = try CLILocalHTTPRequest.parse(Data((head + "\r\n").utf8)).get()
        let response = await CLIServeActionGuard.$override.withValue(CLIServeActionGuard(token: Self.actionToken)) {
            await ClaudeSwapDetectEnvironment.$override.withValue(
                ClaudeSwapDetectEnvironment(environment: [:], home: home.home))
            {
                await CodexBarCLI.forkServeResponse(request, runtime: runtime)
            }
        }
        return try #require(response)
    }

    @Test
    func `the detect route needs the action token and a POST`() async throws {
        let home = try SyntheticHome()
        try home.installFake("cswap", at: ".local/bin/cswap")
        let runtime = Self.runtime(home)

        let missing = try await Self.send("POST", headers: [], home: home, runtime: runtime)
        #expect(missing.status == .forbidden)
        let withOrigin = try await Self.send("POST", headers: [
            "X-UsageBar-Action-Token: \(Self.actionToken)", "Origin: http://example.invalid",
        ], home: home, runtime: runtime)
        #expect(withOrigin.status == .forbidden)
        let get = try await Self.send("GET", headers: [], home: home, runtime: runtime)
        #expect(get.status == .methodNotAllowed)
        #expect(!FileManager.default.fileExists(atPath: runtime.configStore.fileURL.path))

        let allowed = try await Self.send(
            "POST",
            headers: ["X-UsageBar-Action-Token: \(Self.actionToken)"],
            home: home,
            runtime: runtime)
        #expect(allowed.status == .ok)
        let object = try #require(JSONSerialization.jsonObject(with: allowed.body) as? [String: Any])
        #expect(object["installed"] as? Bool == true)
        #expect(object["enabled"] as? Bool == true)
        #expect(try runtime.configStore.load()?.providerConfig(for: .claude)?.claudeSwapEnabled == true)
    }
}
