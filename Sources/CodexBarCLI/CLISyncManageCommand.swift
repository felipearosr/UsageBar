import CodexBarCore
import Commander
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// `sync link`, `rename`, `retire`, `forget`, and `leave`: the Machine lifecycle (§9).
extension CodexBarCLI {
    static func runSyncManage(_ command: String, values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        do {
            switch command {
            case "link":
                try self.runSyncLink(output: output)
            case "rename":
                try await self.runSyncRename(values, output: output)
            case "retire":
                try await self.runSyncRetire(values, output: output)
            case "forget":
                try await self.runSyncForget(values, output: output)
            default:
                try self.runSyncLeave(values, output: output)
            }
        } catch let error as SyncManageArgumentError {
            Self.exit(code: .failure, message: error.message, output: output, kind: .args)
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }
        Self.exit(code: .success, output: output)
    }

    private static func runSyncLink(output: CLIOutputPreferences) throws {
        let link = try MachineSyncManager.pairingLink(environment: Self.syncEnvironment())
        switch output.format {
        case .text:
            // The warning goes to stderr so `$(codexbar sync link)` captures only the link.
            writeStderr(Self.syncLinkWarning)
            print(link.link)
        case .json:
            Self.printJSON(SyncLinkPayload(pairingLink: link.link, server: link.baseURL), pretty: output.pretty)
        }
    }

    private static func runSyncRename(_ values: ParsedValues, output: CLIOutputPreferences) async throws {
        let name = Self.syncJoinedArgument(values)
        guard !name.isEmpty else { throw SyncManageArgumentError(message: "Missing <display-name>.") }
        let environment = Self.syncEnvironment()
        let settings = try MachineSyncManager.rename(to: name, environment: environment)

        // Push now so other Machines see the new name on their next read; a failed push is retried later.
        var pushError: String?
        if settings.pairingLink != nil {
            do {
                _ = try await MachineSyncPusher.push(environment: environment)
            } catch {
                pushError = Self.syncErrorMessage(error)
            }
        }
        switch output.format {
        case .text:
            print(Self.syncRenameText(settings, pushError: pushError))
        case .json:
            Self.printJSON(
                SyncRenamePayload(
                    machineId: settings.machineID,
                    displayName: settings.displayName,
                    pushError: pushError),
                pretty: output.pretty)
        }
    }

    private static func runSyncRetire(_ values: ParsedValues, output: CLIOutputPreferences) async throws {
        let environment = Self.syncEnvironment()
        let machine = try await Self.syncFindOtherMachine(values, command: "retire", environment: environment)
        let retiredAt = try await MachineSyncManager.retire(machineID: machine.machineID, environment: environment)
        switch output.format {
        case .text:
            print(Self.syncRetireText(machine))
        case .json:
            Self.printJSON(
                SyncMachinePayload(
                    machineId: machine.machineID,
                    displayName: machine.displayName,
                    retiredAt: ISO8601DateFormatter().string(from: retiredAt)),
                pretty: output.pretty)
        }
    }

    private static func runSyncForget(_ values: ParsedValues, output: CLIOutputPreferences) async throws {
        let environment = Self.syncEnvironment()
        let machine = try await Self.syncFindOtherMachine(values, command: "forget", environment: environment)
        guard Self.confirmSyncAction(
            Self.syncForgetPrompt(machine),
            values: values,
            output: output)
        else {
            throw SyncManageArgumentError(message: "Not forgotten. Pass --yes to forget without asking.")
        }
        try await MachineSyncManager.forget(machineID: machine.machineID, environment: environment)
        switch output.format {
        case .text:
            print("Forgot \"\(machine.label)\" (\(machine.machineID)). Its Spend is gone from the Sync Server.")
        case .json:
            Self.printJSON(
                SyncMachinePayload(machineId: machine.machineID, displayName: machine.displayName, retiredAt: nil),
                pretty: output.pretty)
        }
    }

    private static func runSyncLeave(_ values: ParsedValues, output: CLIOutputPreferences) throws {
        let environment = Self.syncEnvironment()
        guard try environment.store.loadSettings()?.pairingLink != nil else { throw MachineSyncError.notPaired }
        guard Self.confirmSyncAction(Self.syncLeavePrompt, values: values, output: output) else {
            throw SyncManageArgumentError(message: "Still paired. Pass --yes to leave without asking.")
        }
        let settings = try MachineSyncManager.leave(environment: environment)
        switch output.format {
        case .text:
            print(Self.syncLeaveText(settings))
        case .json:
            Self.printJSON(
                SyncMachinePayload(machineId: settings.machineID, displayName: settings.displayName, retiredAt: nil),
                pretty: output.pretty)
        }
    }

    private static func syncFindOtherMachine(
        _ values: ParsedValues,
        command: String,
        environment: MachineSyncEnvironment) async throws -> MachineSyncMachineRef
    {
        let query = Self.syncJoinedArgument(values)
        guard !query.isEmpty else { throw SyncManageArgumentError(message: "Missing <machine-id-or-name>.") }
        let machine = try await MachineSyncManager.findMachine(query, environment: environment)
        guard !machine.isThisMachine else { throw MachineSyncError.isThisMachine(command: command) }
        return machine
    }

    /// Positional words joined, so `codexbar sync rename my laptop` works without quotes.
    private static func syncJoinedArgument(_ values: ParsedValues) -> String {
        values.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func confirmSyncAction(
        _ prompt: String,
        values: ParsedValues,
        output: CLIOutputPreferences) -> Bool
    {
        self.confirmSyncAction(
            prompt,
            yes: values.flags.contains("yes"),
            jsonOutput: output.usesJSONOutput,
            isTerminal: isatty(STDIN_FILENO) == 1,
            ask: { question in
                writeStderr("\(question) [y/N] ")
                return readLine()
            })
    }

    /// `true` with `--yes`, or when the user answers yes at a terminal. JSON output and runs without a terminal
    /// never prompt, so they need `--yes`.
    static func confirmSyncAction(
        _ prompt: String,
        yes: Bool,
        jsonOutput: Bool,
        isTerminal: Bool,
        ask: (String) -> String?) -> Bool
    {
        if yes { return true }
        guard !jsonOutput, isTerminal else { return false }
        let answer = ask(prompt)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["y", "yes"].contains(answer)
    }

    static let syncLinkWarning =
        "Warning: this Pairing Link is the Sync Group's key. Anyone who has it can read and change the Spend of "
            + "every Machine in the group. Share it only with your own Machines and keep it somewhere safe.\n"

    static let syncLeavePrompt =
        "Leave the Sync Group? This Machine stops syncing and forgets the Pairing Link. Its Spend stays on the "
            + "server. To rejoin later you need the Pairing Link from another Machine or your notes."

    static func syncForgetPrompt(_ machine: MachineSyncMachineRef) -> String {
        "Forget \"\(machine.label)\" (\(machine.machineID))? This deletes all of its Spend from the Sync Server "
            + "for every Machine. It can't be undone."
    }

    static func syncRenameText(_ settings: MachineSyncSettings, pushError: String?) -> String {
        var lines = ["This Machine is now \"\(settings.displayName ?? settings.machineID)\"."]
        if settings.pairingLink == nil {
            lines.append("It isn't in a Sync Group; the name is used when it pairs.")
        } else if let pushError {
            lines.append("The push failed and will be retried by `codexbar sync push`: \(pushError)")
        }
        return lines.joined(separator: "\n")
    }

    static func syncRetireText(_ machine: MachineSyncMachineRef) -> String {
        [
            "Retired \"\(machine.label)\" (\(machine.machineID)).",
            "Its Spend still counts toward totals, but it no longer shows as active.",
            "If it pushes again, it shows as active again.",
        ].joined(separator: "\n")
    }

    static func syncLeaveText(_ settings: MachineSyncSettings) -> String {
        [
            "This Machine left the Sync Group. Its Spend stays on the server.",
            "Pair again with the Pairing Link to rejoin as the same Machine (\(settings.machineID)).",
        ].joined(separator: "\n")
    }
}

private struct SyncManageArgumentError: Error {
    let message: String
}

private struct SyncLinkPayload: Encodable {
    let pairingLink: String
    let server: String
}

private struct SyncRenamePayload: Encodable {
    let machineId: String
    let displayName: String?
    let pushError: String?
}

private struct SyncMachinePayload: Encodable {
    let machineId: String
    let displayName: String?
    let retiredAt: String?
}

struct SyncLinkOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false
}

struct SyncRenameOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Argument(help: "New display name for this Machine")
    var name: String = ""
}

/// Shared by `retire` and `forget`.
struct SyncMachineOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Argument(help: "Machine ID or display name")
    var machine: String = ""

    @Flag(names: [.short("y"), .long("yes")], help: "Don't ask for confirmation (forget only)")
    var yes: Bool = false
}

struct SyncLeaveOptions: CommanderParsable {
    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level (trace|verbose|debug|info|warning|error|critical)")
    var logLevel: String?

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(name: .long("json"), help: "")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only (suppress non-JSON output)")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Flag(names: [.short("y"), .long("yes")], help: "Leave without asking for confirmation")
    var yes: Bool = false
}
