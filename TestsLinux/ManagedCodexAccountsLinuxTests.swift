#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Managed Codex accounts on Linux (#167): `codex-accounts list` and the existing per-account Codex home scoping,
/// against a synthetic store and synthetic Codex homes. Every token below is a fake string; nothing reads the real
/// `~/.codex` or a Keychain.
@Suite(.serialized)
@MainActor
struct ManagedCodexAccountsLinuxTests {
    // MARK: - Listing

    @Test
    func `list rows carry the system marker and no credential contents`() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let matching = try fixture.addAccount(email: "system@example.com", accountID: "acct-system")
        let other = try fixture.addAccount(email: "Other@Example.com", accountID: "acct-other")
        let broken = try fixture.addAccount(email: "broken@example.com", accountID: "acct-broken")
        try Data("not json".utf8).write(to: fixture.authURL(home: broken.managedHomePath))
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")

        let rows = try fixture.scoped {
            try CodexBarCLI.codexAccountRows(
                accounts: FileManagedCodexAccountStore(fileURL: fixture.storeURL).loadAccounts().accounts,
                liveHome: fixture.liveHome,
                reader: DefaultCodexAuthMaterialReader())
        }

        #expect(rows.map(\.id) == [matching.id, other.id, broken.id].map(\.uuidString))
        #expect(rows.map(\.email) == ["system@example.com", "other@example.com", "broken@example.com"])
        #expect(rows.map(\.isSystemAccount) == [true, false, false])
        let json = try #require(String(bytes: JSONEncoder().encode(rows), encoding: .utf8))
        for secret in [
            "synthetic-access",
            "synthetic-refresh",
            "managedHomePath",
            "authFingerprint",
            fixture.root.path,
            "tokens",
        ] {
            #expect(!json.contains(secret), "listing leaked \(secret)")
        }
    }

    // MARK: - Usage home

    @Test
    func `managed account fetch environment uses the managed home and never the system home`() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let account = try fixture.addAccount(
            email: "managed@example.com", accountID: "acct-managed", workspaceID: "WS-Managed")
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")
        let base = ["HOME": fixture.root.path, "CODEX_HOME": fixture.liveHome.path]

        try fixture.scoped {
            let context = try TokenAccountCLIContext(
                selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
                config: CodexBarConfig.makeDefault(),
                verbose: false,
                baseEnvironment: base,
                managedCodexAccountStoreURL: fixture.storeURL)
            let source = CodexActiveSource.managedAccount(id: account.id)
            let env = context.environment(
                base: base, provider: .codex, account: nil, codexActiveSourceOverride: source)
            #expect(env["CODEX_HOME"] == account.managedHomePath)
            let fetcher = context.fetcher(base: UsageFetcher(environment: base), provider: .codex, env: env)
            #expect(fetcher.loadAuthBackedCodexAccount().email == "managed@example.com")
            let settings = context.settingsSnapshot(for: .codex, account: nil, codexActiveSourceOverride: source)
            #expect(settings?.codex?.managedWorkspaceAccountID == "ws-managed")
        }
    }

    // MARK: - CLI

    @Test
    func `promote reports that it is unavailable on Linux while list is allowed`() {
        #expect(CodexBarCLI.codexAccountsUnsupportedPlatformMessage(path: ["codex-accounts", "list"]) == nil)
        let message = CodexBarCLI.codexAccountsUnsupportedPlatformMessage(path: ["codex-accounts", "promote"])
        #expect(message?.contains("only available on macOS") == true)
        #expect(CodexBarCLI.codexAccountsHelp(version: "synthetic").contains("Promote (macOS only)"))
    }

    @Test
    func `codex-accounts list --json runs against a synthetic store and home`() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let binary = try Self.cliBinary()
        // The CLI resolves its store under XDG_DATA_HOME (Foundation's Application Support on Linux).
        let dataHome = fixture.root.appendingPathComponent("data", isDirectory: true)
        let storeURL = dataHome.appendingPathComponent("CodexBar/managed-codex-accounts.json")
        let first = try fixture.addAccount(email: "system@example.com", accountID: "acct-system", storeURL: storeURL)
        let second = try fixture.addAccount(email: "second@example.com", accountID: "acct-second", storeURL: storeURL)
        try fixture.writeLiveAuth(email: "system@example.com", accountID: "acct-system")
        let environment = try fixture.childEnvironment(dataHome: dataHome)

        let list = try Self.run(binary, ["codex-accounts", "list", "--json"], environment: environment)
        #expect(list.status == 0, "stderr: \(list.stderr)")
        let rows = try #require(JSONSerialization.jsonObject(with: Data(list.stdout.utf8)) as? [[String: Any]])
        #expect(rows.compactMap { $0["id"] as? String } == [first.id.uuidString, second.id.uuidString])
        #expect(rows.compactMap { $0["email"] as? String } == ["system@example.com", "second@example.com"])
        #expect(rows.compactMap { $0["isSystemAccount"] as? Bool } == [true, false])
        for secret in ["synthetic-access", "synthetic-refresh", "managedHomePath", fixture.root.path] {
            #expect(!list.stdout.contains(secret), "list leaked \(secret)")
        }

        let promote = try Self.run(
            binary, ["codex-accounts", "promote", first.id.uuidString], environment: environment)
        #expect(promote.status != 0)
        #expect(promote.stderr.contains("only available on macOS"))
        #expect(try fixture.liveAuthData() == fixture.liveAuthSnapshot)
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

/// A synthetic layout: `root/store.json`, `root/homes/<uuid>/auth.json` and `root/live/auth.json`.
private final class Fixture {
    let root: URL
    let storeURL: URL
    let liveHome: URL
    private(set) var liveAuthSnapshot: Data?

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedCodexAccountsLinuxTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        self.storeURL = self.root.appendingPathComponent("managed-codex-accounts.json")
        self.liveHome = self.root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: self.liveHome, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
    }

    var scope: CodexCredentialFileAccess.FixtureScope {
        CodexCredentialFileAccess.FixtureScope(roots: [self.root])
    }

    func scoped<T>(_ operation: () throws -> T) throws -> T {
        try CodexCredentialFileAccess.withFixtureScope(self.scope, operation: operation)
    }

    func authURL(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
    }

    @discardableResult
    func addAccount(
        email: String,
        accountID: String,
        workspaceID: String? = nil,
        workspaceLabel: String? = nil,
        home: String? = nil,
        storeURL: URL? = nil) throws -> ManagedCodexAccount
    {
        let id = UUID()
        let homePath = home ?? self.root.appendingPathComponent("homes/\(id.uuidString)", isDirectory: true).path
        if home == nil {
            try FileManager.default.createDirectory(atPath: homePath, withIntermediateDirectories: true)
            try Self.authData(email: email, accountID: accountID).write(to: self.authURL(home: homePath))
        }
        let account = ManagedCodexAccount(
            id: id,
            email: email,
            providerAccountID: accountID,
            workspaceLabel: workspaceLabel,
            workspaceAccountID: workspaceID,
            managedHomePath: homePath,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)
        let store = FileManagedCodexAccountStore(fileURL: storeURL ?? self.storeURL)
        let existing = try self.scoped { try store.loadAccountMetadata().accounts }
        try self.scoped {
            try store.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: existing + [account]))
        }
        return account
    }

    func writeLiveAuth(email: String, accountID: String) throws {
        let data = Self.authData(email: email, accountID: accountID)
        try data.write(to: self.authURL(home: self.liveHome.path))
        self.liveAuthSnapshot = data
    }

    func liveAuthData() throws -> Data? {
        try Data(contentsOf: self.authURL(home: self.liveHome.path))
    }

    /// A clean child environment: no test-runner variables, synthetic homes, and this fixture's file grants.
    func childEnvironment(dataHome: URL) throws -> [String: String] {
        try self.scope.childEnvironment(base: [
            "PATH": "/usr/bin:/bin",
            "HOME": self.root.path,
            "XDG_DATA_HOME": dataHome.path,
            "XDG_CONFIG_HOME": self.root.appendingPathComponent("config", isDirectory: true).path,
            "CODEX_HOME": self.liveHome.path,
        ])
    }

    static func authData(email: String, accountID: String) -> Data {
        let claims: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": "plus"],
        ]
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
