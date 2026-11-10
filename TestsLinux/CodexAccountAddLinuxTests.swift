#if os(Linux)
import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// `codexbar codex-accounts add` (#169): a fresh managed home, Codex's own login pointed at it, the account in the
/// managed-account store. A fake `codex` (a shell script behind the checked-in trampoline) stands in for the real
/// CLI and records the argv and `CODEX_HOME` it got. Every home is synthetic, and the synthetic system home's bytes
/// are compared before and after each run. Every token is a fake string.
@Suite(.serialized)
@MainActor
struct CodexAccountAddLinuxTests {
    // MARK: - Login

    @Test
    func `the login runs codex login with CODEX_HOME set to a new managed home`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.signIn(email: "second@example.com", accountID: "acct-second"))

        let account = try await fixture.scoped { try await fixture.adder(codex: codex).add() }

        #expect(account.email == "second@example.com")
        #expect(account.providerAccountID == "acct-second")
        #expect(account.managedHomePath.hasPrefix(fixture.homesRoot.path + "/"))
        // The fake saw exactly one argument, `login`, and the new home.
        #expect(try fixture.recorded("argv") == "1\nlogin\n")
        #expect(try fixture.recorded("codex_home") == account.managedHomePath)
        #expect(FileManager.default.fileExists(atPath: account.managedHomePath + "/auth.json"))
        let stored = try fixture.scoped { try fixture.store.loadAccounts().accounts }
        #expect(stored.map(\.id) == [account.id])
        #expect(stored.first?.managedHomePath == account.managedHomePath)
        #expect(try fixture.systemHomeUnchanged())
    }

    @Test
    func `the login gets fixed arguments and the caller's environment with only CODEX_HOME replaced`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.signIn(email: "second@example.com", accountID: "acct-second"))
        let calls = LaunchLog()
        var adder = fixture.adder(codex: codex)
        adder.launch = { executable, arguments, environment in
            calls.append(executable: executable, arguments: arguments, environment: environment)
            return await CodexLoginProcess.run(executable: executable, arguments: arguments, environment: environment)
        }

        let account = try await fixture.scoped { try await adder.add() }

        let call = try #require(calls.only)
        #expect(call.executable == codex.path)
        #expect(call.arguments == ["login"])
        var expected = fixture.baseEnvironment
        expected["CODEX_HOME"] = account.managedHomePath
        #expect(call.environment == expected)
        #expect(fixture.baseEnvironment["CODEX_HOME"] == fixture.systemCodexHome.path)
    }

    @Test
    func `codex login runs in this process group with no signals blocked`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.recordProcessGroup(email: "pgid@example.com"))

        _ = try await fixture.scoped { try await fixture.adder(codex: codex).add() }

        // A child in a new group (Foundation's Process on Linux) is stopped by SIGTTIN/SIGTTOU in a real terminal.
        let recorded = try fixture.recorded("pgid").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(recorded) == getpgrp())
        // And with nothing blocked, so Ctrl-C reaches it even though Swift's worker threads block signals.
        #expect(try fixture.recorded("sigblk").trimmingCharacters(in: .whitespacesAndNewlines)
            == "SigBlk:0000000000000000")
    }

    // MARK: - Failures

    @Test
    func `a failed login stops, names the step and removes the new home`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.fail(status: 3))

        let error = await fixture.addError(fixture.adder(codex: codex))

        #expect(error == CodexAccountAddError.login(status: 3))
        #expect(CodexAccountAddError.login(status: 3).step.contains("`codex login` exited with status 3"))
        #expect(try fixture.recorded("argv") == "1\nlogin\n")
        #expect(try fixture.managedHomes().isEmpty)
        #expect(try fixture.scoped { try fixture.store.loadAccounts().accounts }.isEmpty)
        #expect(try fixture.systemHomeUnchanged())
    }

    @Test
    func `an interrupted login removes the new home`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.killed)

        let error = await fixture.addError(fixture.adder(codex: codex))

        #expect(error == CodexAccountAddError.loginInterrupted(signal: SIGTERM))
        #expect(try fixture.managedHomes().isEmpty)
        #expect(try fixture.systemHomeUnchanged())
    }

    @Test
    func `a login that leaves no readable account removes the new home`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let silent = try fixture.installCodex(.succeedWithoutAuth)
        let error = await fixture.addError(fixture.adder(codex: silent))
        #expect(error == CodexAccountAddError.readLogin)
        #expect(try fixture.managedHomes().isEmpty)

        let anonymous = try fixture.installCodex(.signIn(email: nil, accountID: "acct-anon"), name: "codex-anon")
        let anonymousError = await fixture.addError(fixture.adder(codex: anonymous))
        #expect(anonymousError == CodexAccountAddError.missingEmail)
        #expect(try fixture.managedHomes().isEmpty)
        #expect(try fixture.scoped { try fixture.store.loadAccounts().accounts }.isEmpty)
        #expect(try fixture.systemHomeUnchanged())
    }

    @Test
    func `a missing codex fails before any home is made`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        var adder = fixture.adder(codex: fixture.root.appendingPathComponent("absent"))
        adder = CodexAccountAdder(
            store: adder.store,
            homeFactory: adder.homeFactory,
            baseEnvironment: adder.baseEnvironment,
            resolveCodex: { _ in nil })

        let error = await fixture.addError(adder)

        #expect(error == CodexAccountAddError.codexNotFound)
        #expect(!FileManager.default.fileExists(atPath: fixture.homesRoot.path))
    }

    // MARK: - Store

    @Test
    func `signing in to an account already in the store replaces it and its old home`() async throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let codex = try fixture.installCodex(.signIn(email: "second@example.com", accountID: "acct-second"))
        let other = try fixture.installCodex(
            .signIn(email: "third@example.com", accountID: "acct-third"),
            name: "codex-third")
        let first = try await fixture.scoped { try await fixture.adder(codex: codex).add() }
        let third = try await fixture.scoped { try await fixture.adder(codex: other).add() }
        let again = try await fixture.scoped { try await fixture.adder(codex: codex).add() }

        #expect(again.id == first.id)
        #expect(again.managedHomePath != first.managedHomePath)
        #expect(!FileManager.default.fileExists(atPath: first.managedHomePath))
        let stored = try fixture.scoped { try fixture.store.loadAccounts().accounts }
        #expect(Set(stored.map(\.id)) == [first.id, third.id])
        #expect(try Set(fixture.managedHomes()) == [third.managedHomePath, again.managedHomePath])
        #expect(try fixture.systemHomeUnchanged())
    }

    @Test
    func `upstream's factory refuses to delete a home outside its root`() throws {
        let factory = CLICodexManagedHomeFactory()
        #expect(throws: CodexAccountCLIError.unsafeHome) {
            try factory.validateManagedHomeForDeletion(URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true))
        }
    }

    // MARK: - CLI

    @Test
    func `codex-accounts add resolves and is allowed on Linux`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        #expect(try program.resolve(argv: ["codex-accounts", "add"]).path == ["codex-accounts", "add"])
        #expect(CodexBarCLI.codexAccountsUnsupportedPlatformMessage(path: ["codex-accounts", "add"]) == nil)
        #expect(CodexBarCLI.codexAccountsHelp(version: "synthetic").contains("codexbar codex-accounts add"))
    }

    @Test
    func `the CLI prints done after a login and the failing step after a failed one`() throws {
        let fixture = try AddFixture()
        defer { fixture.tearDown() }
        let binary = try Self.cliBinary()
        let dataHome = fixture.root.appendingPathComponent("data", isDirectory: true)
        let codex = try fixture.installCodex(.signIn(email: "second@example.com", accountID: "acct-second"))
        var environment = try fixture.childEnvironment(dataHome: dataHome)
        environment["CODEX_CLI_PATH"] = codex.path

        let added = try Self.run(binary, ["codex-accounts", "add"], environment: environment)
        #expect(added.status == 0, "stderr: \(added.stderr)")
        #expect(added.stdout.contains("Done. Added second@example.com"))
        for secret in ["synthetic-access", "synthetic-refresh"] {
            #expect(!added.stdout.contains(secret) && !added.stderr.contains(secret), "add leaked \(secret)")
        }
        let storeURL = dataHome.appendingPathComponent("CodexBar/managed-codex-accounts.json")
        let stored = try fixture.scoped { try FileManagedCodexAccountStore(fileURL: storeURL).loadAccounts() }
        #expect(stored.accounts.map(\.email) == ["second@example.com"])
        let homesRoot = dataHome.appendingPathComponent("CodexBar/managed-codex-homes", isDirectory: true)
        #expect(stored.accounts.first?.managedHomePath.hasPrefix(homesRoot.path + "/") == true)

        let failing = try fixture.installCodex(.fail(status: 7), name: "codex-failing")
        environment["CODEX_CLI_PATH"] = failing.path
        let failed = try Self.run(binary, ["codex-accounts", "add"], environment: environment)
        #expect(failed.status != 0)
        #expect(failed.stderr.contains("Failed: `codex login` exited with status 7"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: homesRoot.path).count == 1)
        #expect(try fixture.systemHomeUnchanged())
    }

    // MARK: - Helpers

    private static func cliBinary() throws -> URL {
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [directory, directory.deletingLastPathComponent()].map {
            $0.appendingPathComponent("CodexBarCLI")
        }
        return try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func run(
        _ binary: URL,
        _ arguments: [String],
        environment: [String: String]) throws -> (status: Int32, stdout: String, stderr: String)
    {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(bytes: out, encoding: .utf8) ?? "",
            String(bytes: err, encoding: .utf8) ?? "")
    }
}

private final class LaunchLog: @unchecked Sendable {
    struct Call {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func append(executable: String, arguments: [String], environment: [String: String]) {
        self.lock.withLock { self.calls.append(Call(
            executable: executable,
            arguments: arguments,
            environment: environment)) }
    }

    var only: Call? {
        self.lock.withLock { self.calls.count == 1 ? self.calls.first : nil }
    }
}

/// A home root a test factory hands out, a store, a synthetic system home with `.codex/auth.json`, and fake
/// `codex` executables, all under one temporary root.
@MainActor
private final class AddFixture {
    enum FakeCodex {
        case signIn(email: String?, accountID: String)
        case succeedWithoutAuth
        case fail(status: Int32)
        case killed
        case recordProcessGroup(email: String)
    }

    struct HomeFactory: ManagedCodexHomeProducing {
        let root: URL

        func makeHomeURL() -> URL {
            self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }

        func validateManagedHomeForDeletion(_ url: URL) throws {
            guard url.standardizedFileURL.path.hasPrefix(self.root.standardizedFileURL.path + "/") else {
                throw CodexAccountCLIError.unsafeHome
            }
        }
    }

    let root: URL
    let homesRoot: URL
    let storeURL: URL
    let systemHome: URL
    let systemCodexHome: URL
    let records: URL
    private let systemAuth: Data

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAccountAddLinuxTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        self.homesRoot = self.root.appendingPathComponent("managed-codex-homes", isDirectory: true)
        self.storeURL = self.root.appendingPathComponent("managed-codex-accounts.json")
        self.systemHome = self.root.appendingPathComponent("home", isDirectory: true)
        self.systemCodexHome = self.systemHome.appendingPathComponent(".codex", isDirectory: true)
        self.records = self.root.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: self.systemCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.records, withIntermediateDirectories: true)
        self.systemAuth = Self.authData(email: "system@example.com", accountID: "acct-system")
        try self.systemAuth.write(to: self.systemCodexHome.appendingPathComponent("auth.json"))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
    }

    var store: FileManagedCodexAccountStore {
        FileManagedCodexAccountStore(fileURL: self.storeURL)
    }

    /// The caller's environment: the system Codex home is both `~/.codex` and an explicit `CODEX_HOME`.
    var baseEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": self.systemHome.path,
            "CODEX_HOME": self.systemCodexHome.path,
            "FAKE_CODEX_RECORDS": self.records.path,
        ]
    }

    func adder(codex: URL) -> CodexAccountAdder {
        CodexAccountAdder(
            store: self.store,
            homeFactory: HomeFactory(root: self.homesRoot),
            baseEnvironment: self.baseEnvironment,
            resolveCodex: { _ in codex.path })
    }

    func scoped<T>(_ operation: () throws -> T) throws -> T {
        try CodexCredentialFileAccess.withFixtureScope(self.scope, operation: operation)
    }

    func scoped<T>(_ operation: () async throws -> T) async throws -> T {
        try await CodexCredentialFileAccess.withFixtureScope(self.scope, operation: operation)
    }

    private var scope: CodexCredentialFileAccess.FixtureScope {
        CodexCredentialFileAccess.FixtureScope(roots: [self.root])
    }

    func childEnvironment(dataHome: URL) throws -> [String: String] {
        var base = self.baseEnvironment
        base["XDG_DATA_HOME"] = dataHome.path
        base["XDG_CONFIG_HOME"] = self.root.appendingPathComponent("config", isDirectory: true).path
        return try self.scope.childEnvironment(base: base)
    }

    /// Installs a fake `codex` that records its argv and `CODEX_HOME`, then acts out `behavior`.
    func installCodex(_ behavior: FakeCodex, name: String = "codex") throws -> URL {
        let url = self.root.appendingPathComponent(name)
        let record = """
        printf '%s\\n' "$#" "$@" > "$FAKE_CODEX_RECORDS/argv"
        printf '%s' "$CODEX_HOME" > "$FAKE_CODEX_RECORDS/codex_home"

        """
        let action: String
        switch behavior {
        case let .signIn(email, accountID):
            let source = self.root.appendingPathComponent("\(name)-auth.json")
            try Self.authData(email: email, accountID: accountID).write(to: source)
            action = "cp '\(source.path)' \"$CODEX_HOME/auth.json\"\nexit 0\n"
        case .succeedWithoutAuth:
            action = "exit 0\n"
        case let .fail(status):
            action = "echo 'fake codex: login failed' >&2\nexit \(status)\n"
        case .killed:
            action = "kill -TERM $$\nsleep 5\n"
        case let .recordProcessGroup(email):
            let source = self.root.appendingPathComponent("\(name)-auth.json")
            try Self.authData(email: email, accountID: "acct-pgid").write(to: source)
            action = """
            { ps -o pgid= -p $$ 2>/dev/null || cut -d' ' -f5 /proc/$$/stat; } > "$FAKE_CODEX_RECORDS/pgid"
            grep '^SigBlk:' /proc/$$/status | tr -d ' \\t' > "$FAKE_CODEX_RECORDS/sigblk"
            cp '\(source.path)' "$CODEX_HOME/auth.json"
            exit 0

            """
        }
        try FakeExecutable.install(record + action, at: url)
        return url
    }

    /// The step `adder.add()` failed at, or nil when it succeeded.
    func addError(_ adder: CodexAccountAdder) async -> CodexAccountAddError? {
        do {
            _ = try await self.scoped { try await adder.add() }
            return nil
        } catch {
            return error as? CodexAccountAddError
        }
    }

    func recorded(_ name: String) throws -> String {
        try String(contentsOf: self.records.appendingPathComponent(name), encoding: .utf8)
    }

    func managedHomes() throws -> [String] {
        guard FileManager.default.fileExists(atPath: self.homesRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: self.homesRoot.path)
            .map { self.homesRoot.appendingPathComponent($0).path }
    }

    /// The synthetic system Codex home holds exactly what it held before: `auth.json` with the same bytes.
    func systemHomeUnchanged() throws -> Bool {
        let entries = try FileManager.default.subpathsOfDirectory(atPath: self.systemCodexHome.path).sorted()
        let auth = try Data(contentsOf: self.systemCodexHome.appendingPathComponent("auth.json"))
        return entries == ["auth.json"] && auth == self.systemAuth
    }

    static func authData(email: String?, accountID: String) -> Data {
        var claims: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "plus"],
        ]
        if let email { claims["email"] = email }
        let auth: [String: Any] = [
            "tokens": [
                "access_token": "synthetic-access",
                "refresh_token": "synthetic-refresh",
                "id_token": Self.jwt(claims),
                "account_id": accountID,
            ],
            "last_refresh": "2026-01-01T00:00:00Z",
        ]
        return (try? JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])) ?? Data()
    }

    private static func jwt(_ claims: [String: Any]) -> String {
        func encode(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(["alg": "none", "typ": "JWT"])).\(encode(claims)).synthetic-signature"
    }
}
#endif
