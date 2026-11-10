import CodexBarCore
import Commander
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - UsageBar: `codexbar codex-accounts add` (#169)

/// Adds a managed Codex account from a terminal, the CLI counterpart of the macOS app's "Add account"
/// (`ManagedCodexAccountService.authenticateManagedAccount`): a fresh home from upstream's managed-home factory,
/// Codex's own `codex login` with `CODEX_HOME` pointed at it, then the account in the managed-account store.
///
/// The GNOME extension opens it in a terminal for the `cli-login` kind. It runs the login with a fixed argument
/// array and no shell, never reads or writes the system Codex home, and on any failure removes the home it made.
/// The macOS app's workspace chooser and its network workspace lookup are left out: the account keeps the
/// workspace its login names, which is what the app stores when that lookup finds nothing. Like the app's
/// `CodexLoginRunner`, the login gets the login shell's PATH ahead of the caller's, so an npm or nvm `codex`
/// (`#!/usr/bin/env node`) finds its `node` even from GNOME Shell's short PATH. It also runs on the macOS CLI.
extension CodexBarCLI {
    /// The `add` entry under `codex-accounts`, appended to upstream's subcommands.
    static func forkCodexAccountsSubcommandDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                name: "add",
                abstract: "Sign in to another Codex account in a home UsageBar manages",
                discussion: nil,
                signature: CommandSignature.describe(ConfigOptions()).flattened()),
        ]
    }

    /// Hook at the top of `runCodexAccounts`: runs the subcommands UsageBar adds and returns true, or false for
    /// upstream's own.
    @MainActor
    static func forkRunCodexAccounts(path: [String], values _: ParsedValues, output: CLIOutputPreferences) async
        -> Bool
    {
        guard path == ["codex-accounts", "add"] else { return false }
        let environment = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.currentOrCapture()
        let adder = CodexAccountAdder(
            store: FileManagedCodexAccountStore(),
            homeFactory: CLICodexManagedHomeFactory(),
            baseEnvironment: environment,
            loginPATH: loginPATH,
            // Provider-specific by design: this helper drives Codex's own CLI, found as the app finds it.
            resolveCodex: { BinaryLocator.resolveCodexBinary(env: $0, loginPATH: loginPATH) })
        print("Adding a Codex account. Codex opens its sign-in page in your browser.")
        print("Your everyday Codex login is not changed.")
        print("")
        // Closing the terminal hangs up the whole foreground group. Survive it until the new home is cleaned up;
        // `codex login` still gets the default action (a handled signal resets on exec), and writes to the gone
        // terminal just fail.
        let restore = CodexAccountAddSignals.surviveHangup()
        let result: Result<ManagedCodexAccount, Error>
        do {
            result = try await .success(adder.add())
        } catch {
            result = .failure(error)
        }
        restore()
        switch result {
        case let .success(account):
            print("")
            print("Done. Added \(account.email) to UsageBar.")
        case let .failure(error as CodexAccountAddError):
            if case let .loginInterrupted(signal) = error {
                // 128 + signal, like a shell, so the terminal wrapper reports Ctrl-C as 130 (cancelled).
                Self.writeStderr("\nFailed: \(error.step)\n")
                Self.platformExit(128 + signal)
            }
            Self.exit(code: .failure, message: "\nFailed: \(error.step)", output: output, kind: .runtime)
        case .failure:
            Self.exit(code: .failure, message: "\nFailed: couldn't add the account.", output: output, kind: .runtime)
        }
        return true
    }
}

/// The step `codex-accounts add` stopped at. Its text is what the terminal shows; it never carries a token.
enum CodexAccountAddError: Error, Equatable {
    case codexNotFound
    case createHome
    case startLogin
    case login(status: Int32)
    case loginInterrupted(signal: Int32)
    case readLogin
    case missingEmail
    case saveAccount

    var step: String {
        switch self {
        case .codexNotFound:
            "couldn't find the codex CLI. Install Codex, or set CODEX_CLI_PATH to it."
        case .createHome:
            "couldn't create a home for the new account."
        case .startLogin:
            "couldn't start `codex login`."
        case let .login(status):
            "`codex login` exited with status \(status). No account was added."
        case let .loginInterrupted(signal):
            // The runner reports a signal as 128 + its number, which a plain exit status can also be.
            "`codex login` was interrupted (status \(128 + signal)). No account was added."
        case .readLogin:
            "`codex login` finished, but its login couldn't be read. No account was added."
        case .missingEmail:
            "`codex login` finished, but the login has no email. No account was added."
        case .saveAccount:
            "couldn't save the account to UsageBar's account list. No account was added."
        }
    }
}

/// One `codex-accounts add`. Every outside effect is injected, so tests run it against a synthetic store, a
/// synthetic home root and a fake `codex`.
struct CodexAccountAdder {
    /// Runs `executable` with `arguments` (argv[0] excluded) and `environment`, attached to this terminal, and
    /// returns its wait status. nil when it couldn't start.
    typealias Launch = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String])
        async -> CodexLoginExit?

    /// Codex's own login subcommand; the macOS app runs the same (`CLILoginRunner`).
    static let loginArguments = ["login"]

    let store: any ManagedCodexAccountStoring
    let homeFactory: any ManagedCodexHomeProducing
    @ProcessEnvironment var baseEnvironment: [String: String]
    /// The login shell's PATH (`LoginShellPathCache`), or nil when it couldn't be read.
    var loginPATH: [String]?
    let resolveCodex: @Sendable ([String: String]) -> String?
    var launch: Launch = { await CodexLoginProcess.run(executable: $0, arguments: $1, environment: $2) }
    var fileManager: FileManager = .default
    var now: @Sendable () -> Date = { Date() }

    /// The environment `codex login` runs with, as the app's `CodexLoginRunner` builds it: the caller's, with the
    /// login shell's PATH entries ahead of the caller's own, and `CODEX_HOME` set to the new home (replacing any
    /// `CODEX_HOME` the caller had, so the system home is never the target).
    static func loginEnvironment(base: [String: String], home: URL, loginPATH: [String]?) -> [String: String] {
        var environment = base
        environment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: base,
            loginPATH: loginPATH)
        return CodexHomeScope.scopedEnvironment(base: environment, codexHome: home.path)
    }

    @MainActor
    func add() async throws -> ManagedCodexAccount {
        guard let codex = self.resolveCodex(self.baseEnvironment) else { throw CodexAccountAddError.codexNotFound }
        let home = self.homeFactory.makeHomeURL()
        do {
            try self.fileManager.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw CodexAccountAddError.createHome
        }
        let account: ManagedCodexAccount
        let replacedHomes: [String]
        do {
            let environment = Self.loginEnvironment(base: self.baseEnvironment, home: home, loginPATH: self.loginPATH)
            switch await self.launch(codex, Self.loginArguments, environment) {
            case nil:
                throw CodexAccountAddError.startLogin
            case .exited(0):
                break
            case let .exited(status):
                throw CodexAccountAddError.login(status: status)
            case let .signalled(signal):
                throw CodexAccountAddError.loginInterrupted(signal: signal)
            }
            (account, replacedHomes) = try self.record(home: home)
        } catch {
            self.removeHome(home)
            throw error
        }
        // A re-login of an account already in the store replaces it; its old home goes once nothing points at it.
        // As in the macOS app, a serve fetch that read the old account just before may still refresh that home's
        // OAuth token while it is removed; its next fetch reads the new home.
        try? ManagedCodexAccountLock.withLock(at: self.store.lockURL) {
            let referenced = try Set(self.store.loadAccounts().accounts.map(\.managedHomePath))
            for path in replacedHomes where path != home.path && !referenced.contains(path) {
                self.removeHome(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        return account
    }

    /// Reads the new login's identity and stores it, replacing an account with the same email and workspace the
    /// way the macOS app does. Returns the account and the homes of the accounts it replaced.
    @MainActor
    private func record(home: URL) throws -> (ManagedCodexAccount, [String]) {
        let identity: CodexAuthBackedAccount
        do {
            guard let data = try DefaultCodexAuthMaterialReader().readAuthData(homeURL: home) else {
                throw CodexAccountAddError.readLogin
            }
            identity = try PreparedPromotionContextBuilder.runtimeAccount(from: data)
        } catch {
            throw CodexAccountAddError.readLogin
        }
        guard let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw CodexAccountAddError.missingEmail
        }
        let providerAccountID: String? = switch identity.identity {
        case let .providerAccount(id): ManagedCodexAccount.normalizeWorkspaceAccountID(id)
        case .emailOnly, .unresolved: nil
        }
        do {
            return try self.withStoreLock {
                let snapshot = try self.store.loadAccounts()
                let existing = snapshot.account(email: email, providerAccountID: providerAccountID)
                let sameWorkspace = existing?.effectiveWorkspaceAccountID == providerAccountID
                let timestamp = self.now().timeIntervalSince1970
                let account = ManagedCodexAccount(
                    id: existing?.id ?? UUID(),
                    email: email,
                    providerAccountID: providerAccountID ?? existing?.providerAccountID,
                    workspaceLabel: sameWorkspace ? existing?.workspaceLabel : nil,
                    workspaceAccountID: providerAccountID ?? existing?.effectiveWorkspaceAccountID,
                    authFingerprint: CodexAuthFingerprint.fingerprint(
                        homePath: home.path,
                        fileManager: self.fileManager),
                    managedHomePath: home.path,
                    createdAt: existing?.createdAt ?? timestamp,
                    updatedAt: timestamp,
                    lastAuthenticatedAt: timestamp)
                // Same-email accounts without a workspace are legacy duplicates once the login names one.
                let replaced = snapshot.accounts.filter { candidate in
                    candidate.id == existing?.id || (providerAccountID != nil
                        && candidate.effectiveWorkspaceAccountID == nil
                        && candidate.email == account.email)
                }
                let replacedIDs = Set(replaced.map(\.id))
                try self.store.storeAccounts(ManagedCodexAccountSet(
                    version: snapshot.version,
                    accounts: snapshot.accounts.filter { !replacedIDs.contains($0.id) } + [account]))
                return (account, replaced.map(\.managedHomePath))
            }
        } catch {
            throw CodexAccountAddError.saveAccount
        }
    }

    /// The store's lock, retried for up to two seconds while another writer holds it, so a concurrent add or
    /// promote doesn't throw away a login that already succeeded.
    @MainActor
    private func withStoreLock<T>(_ operation: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            do {
                return try ManagedCodexAccountLock.withLock(at: self.store.lockURL, operation: operation)
            } catch ManagedCodexAccountLockError.busy where attempt < 20 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Removes a home only when upstream's factory says it is one of its managed homes.
    private func removeHome(_ home: URL) {
        guard (try? self.homeFactory.validateManagedHomeForDeletion(home)) != nil,
              self.fileManager.fileExists(atPath: home.path)
        else { return }
        try? self.fileManager.removeItem(at: home)
    }
}

/// How `codex login` ended.
enum CodexLoginExit: Equatable, Sendable {
    case exited(Int32)
    case signalled(Int32)
}

/// Runs `codex login` with the shared foreground runner (CLIForegroundProcess.swift): `posix_spawn` with an argument
/// array (no shell), the terminal's stdin, stdout and stderr, and this process group, so the browser flow, raw-mode
/// input and Ctrl-C reach Codex while this process waits to clean up. Off the main actor, since it blocks.
enum CodexLoginProcess {
    static func run(executable: String, arguments: [String], environment: [String: String]) async
        -> CodexLoginExit?
    {
        await Task.detached {
            guard let code = try? CLIForegroundProcess.run(executable, arguments, environment: environment) else {
                return nil
            }
            // The runner reports a signal as 128 + its number; an exit status above 128 reads the same.
            return code > 128 ? .signalled(code - 128) : .exited(code)
        }.value
    }
}

/// SIGHUP and SIGTERM while `codex-accounts add` runs: a no-op handler (not `SIG_IGN`, which `codex login` would
/// inherit), so the helper outlives a closed terminal long enough to remove the new home, while `codex login`
/// gets the default action back on exec and stops. The shared runner (CLIForegroundProcess.swift) handles
/// SIGINT and SIGQUIT itself.
enum CodexAccountAddSignals {
    private static let hangups: [Int32] = [SIGHUP, SIGTERM]

    /// Installs the handlers and returns what restores the previous ones.
    static func surviveHangup() -> () -> Void {
        let previous = self.hangups.map { number in (number, signal(number) { _ in }) }
        return {
            for (number, handler) in previous {
                signal(number, handler)
            }
        }
    }
}
