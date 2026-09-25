import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func runSync(path: [String], values: ParsedValues) async {
        switch path {
        case ["sync", "create"]:
            await self.runSyncCreate(values)
        default:
            await self.runSyncPush(values)
        }
    }

    static func runSyncCreate(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        guard let server = values.options["server"]?.last else {
            Self.exit(code: .failure, message: "Missing --server <url>.", output: output, kind: .args)
        }
        // Checked against a throwaway key so the warning comes before any request.
        if let preview = try? MachineSyncPairingLink(serverURL: server, rootKey: .generate()),
           preview.cleartextWarning
        {
            Self.writeStderr(Self.syncCleartextWarning(host: preview.host))
        }

        let result: MachineSyncCreateResult
        do {
            result = try await MachineSyncGroupCreator.create(
                serverURL: server,
                enrollmentToken: values.options["token"]?.last,
                displayName: values.options["name"]?.last,
                environment: Self.syncEnvironment())
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }

        // The group exists and the link is saved; a failed first push is retried by the next `sync push`.
        var pushError: String?
        do {
            _ = try await MachineSyncPusher.push(environment: Self.syncEnvironment())
        } catch {
            pushError = Self.syncErrorMessage(error)
        }

        switch output.format {
        case .text:
            print(Self.syncCreateText(result, pushError: pushError))
        case .json:
            Self.printJSON(
                SyncCreatePayload(
                    pairingLink: result.link.link,
                    machineId: result.settings.machineID,
                    displayName: result.settings.displayName,
                    server: result.link.baseURL,
                    pushError: pushError),
                pretty: output.pretty)
        }
        Self.exit(code: .success, output: output)
    }

    static func runSyncPush(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let outcome: MachineSyncPushOutcome
        do {
            outcome = try await MachineSyncPusher.push(environment: Self.syncEnvironment())
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }
        switch output.format {
        case .text:
            print(Self.syncPushText(outcome))
        case .json:
            Self.printJSON(SyncPushPayload(outcome), pretty: output.pretty)
        }
        Self.exit(code: .success, output: output)
    }

    private static func syncEnvironment() -> MachineSyncEnvironment {
        MachineSyncEnvironment(clientVersion: currentVersion() ?? "unknown")
    }

    static func syncErrorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func syncCleartextWarning(host: String) -> String {
        "Warning: http:// sends this Sync Group's credential to \(host) unencrypted. "
            + "Spend stays end-to-end encrypted, but anyone on the network path could write to the group. "
            + "Use https:// unless \(host) is on a private network you trust.\n"
    }

    static func syncCreateText(_ result: MachineSyncCreateResult, pushError: String?) -> String {
        var lines = [
            "Created a Sync Group on \(result.link.baseURL).",
            "This Machine is \"\(result.settings.displayName ?? result.settings.machineID)\".",
        ]
        if let pushError {
            lines.append("The first push failed and will be retried by `codexbar sync push`: \(pushError)")
        }
        lines += [
            "",
            "Pairing Link:",
            "  \(result.link.link)",
            "",
            "Store this link somewhere safe, such as a password manager. It is the only way to recover this",
            "Sync Group, and anyone who has it can read and change the Spend of every Machine in it.",
        ]
        return lines.joined(separator: "\n")
    }

    static func syncPushText(_ outcome: MachineSyncPushOutcome) -> String {
        switch outcome {
        case let .pushed(uploaded, _) where uploaded.isEmpty:
            "Nothing new to push."
        case let .pushed(uploaded, _):
            "Pushed \(uploaded.joined(separator: ", "))."
        case .skippedLocked:
            "Another push is already running on this Machine; skipped."
        case let .backingOff(until):
            "Waiting after a sync error; next attempt after \(ISO8601DateFormatter().string(from: until))."
        }
    }
}

private struct SyncCreatePayload: Encodable {
    let pairingLink: String
    let machineId: String
    let displayName: String?
    let server: String
    let pushError: String?
}

private struct SyncPushPayload: Encodable {
    let status: String
    let uploaded: [String]
    let unchanged: Int
    let nextAttemptAt: String?

    init(_ outcome: MachineSyncPushOutcome) {
        switch outcome {
        case let .pushed(uploaded, unchanged):
            self.status = "pushed"
            self.uploaded = uploaded
            self.unchanged = unchanged
            self.nextAttemptAt = nil
        case .skippedLocked:
            self.status = "locked"
            self.uploaded = []
            self.unchanged = 0
            self.nextAttemptAt = nil
        case let .backingOff(until):
            self.status = "backing_off"
            self.uploaded = []
            self.unchanged = 0
            self.nextAttemptAt = ISO8601DateFormatter().string(from: until)
        }
    }
}

struct SyncCreateOptions: CommanderParsable {
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

    @Option(name: .long("server"), help: "Sync Server URL (https://...)")
    var server: String?

    @Option(name: .long("token"), help: "Enrollment Token, when the server requires one")
    var token: String?

    @Option(name: .long("name"), help: "Display name for this Machine (default: hostname)")
    var name: String?
}

struct SyncPushOptions: CommanderParsable {
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
