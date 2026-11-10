import Commander
import Foundation

// MARK: - UsageBar CLI extension hook

/// Commands UsageBar adds to upstream's CLI. Upstream's files each carry one call into this file, so upstream's
/// changes to CLI entry and help rarely conflict with the fork:
/// - `commandDescriptors()` appends `forkCommandDescriptors()`.
/// - `main()` reaches `runForkCommand` from its `default:` case; anything not handled here is upstream's
///   "Unknown command".
/// - `printHelp(for:)` asks `forkHelp(for:version:)` before falling back to the root help.
/// - `rootHelp(version:)` interpolates `forkRootHelpUsage()` into its usage list.
extension CodexBarCLI {
    static func forkCommandDescriptors() -> [CommandDescriptor] {
        [self.syncCommandDescriptor(), self.claudeCommandDescriptor()]
    }

    static func runForkCommand(path: [String], values: ParsedValues, output: CLIOutputPreferences) async {
        switch path.first {
        case "sync":
            await self.runSync(path: path, values: values)
        // Provider-specific by design: `codexbar claude statusline capture` is Claude Code's statusLine hook.
        // Capture must never print or fail loudly: Claude Code renders its stdout.
        case "claude" where path == ["claude", "statusline", "capture"]:
            self.runClaudeStatusLineCapture()
        // Provider-specific by design: claude-swap's add flow is Claude's only interactive account add (#172).
        case "claude" where path == ["claude", "add-account"]:
            self.runClaudeAddAccount()
        default:
            self.exit(code: .failure, message: "Unknown command", output: output, kind: .args)
        }
    }

    static func forkHelp(for command: String?, version: String) -> String? {
        switch command {
        case "sync":
            self.syncHelp(version: version)
        case "add-account":
            self.claudeAddAccountHelp(version: version)
        // Provider-specific by design: `codexbar claude` holds the statusLine hook and the claude-swap add helper.
        case "claude":
            self.claudeStatusLineHelp(version: version) + "\n\n" + self.claudeAddAccountHelp(version: version)
        case "statusline", "capture":
            self.claudeStatusLineHelp(version: version)
        default:
            nil
        }
    }

    /// Usage lines for the root help, indented to sit inside its `Usage:` list (the first line takes the
    /// indentation of the interpolation site).
    static func forkRootHelpUsage() -> String {
        """
        codexbar sync create --server <url> [--token <enrollment-token>] [--name <display-name>]
        codexbar sync pair <pairing-link> [--name <display-name>] [--yes]
        codexbar sync push
        codexbar sync status [--timezone <iana-id>] [--day-start <hour>] [--json]
        codexbar sync install-timer [--uninstall]
        codexbar sync link | rename <display-name> | retire <machine> | forget <machine> [--yes] | leave [--yes]
        codexbar claude statusline capture
        codexbar claude add-account
        codexbar --version --json
        """
            .replacingOccurrences(of: "\n", with: "\n  ")
    }
}
