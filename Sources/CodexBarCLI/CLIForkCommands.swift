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
        [self.syncCommandDescriptor()]
    }

    static func runForkCommand(path: [String], values: ParsedValues, output: CLIOutputPreferences) async {
        guard path.first == "sync" else {
            self.exit(code: .failure, message: "Unknown command", output: output, kind: .args)
        }
        await self.runSync(path: path, values: values)
    }

    static func forkHelp(for command: String?, version: String) -> String? {
        switch command {
        case "sync":
            self.syncHelp(version: version)
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
        codexbar --version --json
        """
            .replacingOccurrences(of: "\n", with: "\n  ")
    }
}
