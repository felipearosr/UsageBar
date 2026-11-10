import Foundation

// MARK: - UsageBar: managed Codex accounts on Linux (#167)

extension CodexBarCLI {
    /// Hook called first in `runCodexAccounts`: exits when this platform can't run the subcommand.
    static func forkRequireCodexAccountsPlatformSupport(path: [String], output: CLIOutputPreferences) {
        if let message = codexAccountsUnsupportedPlatformMessage(path: path) {
            exit(code: .failure, message: message, output: output, kind: .args)
        }
    }

    /// `codex-accounts list` runs everywhere: it only reads the managed account store and each managed home's
    /// `auth.json`. So does `add` (#169), which signs in to a new managed home and never touches the system login.
    /// `promote` replaces the system Codex login and stays macOS-only.
    static func codexAccountsUnsupportedPlatformMessage(path: [String]) -> String? {
        #if os(macOS)
        return nil
        #else
        return path == ["codex-accounts", "list"] || path == ["codex-accounts", "add"]
            ? nil
            : "Promoting a managed Codex account is only available on macOS."
        #endif
    }
}
