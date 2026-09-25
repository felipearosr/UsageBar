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

extension CodexBarCLI {
    static func runSync(path: [String], values: ParsedValues) async {
        switch path {
        case ["sync", "create"]:
            await self.runSyncCreate(values)
        case ["sync", "pair"]:
            await self.runSyncPair(values)
        case ["sync", "status"]:
            await self.runSyncStatus(values)
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
           !Self.confirmCleartext(preview, values: values, output: output)
        {
            let message = MachineSyncError.cleartextNotConfirmed(host: preview.host).errorDescription
            Self.exit(code: .failure, message: message, output: output, kind: .args)
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

    static func runSyncPair(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        guard let rawLink = values.positional.first, !rawLink.isEmpty else {
            Self.exit(code: .failure, message: "Missing <pairing-link>.", output: output, kind: .args)
        }
        // An unparseable link gets its real error from `pair` below.
        let allowCleartext = (try? MachineSyncPairingLink(
            parsing: rawLink.trimmingCharacters(in: .whitespacesAndNewlines)))
            .map { Self.confirmCleartext($0, values: values, output: output) } ?? false

        let result: MachineSyncPairResult
        do {
            result = try await MachineSyncPairer.pair(
                pairingLink: rawLink,
                displayName: values.options["name"]?.last,
                allowCleartext: allowCleartext,
                environment: Self.syncEnvironment())
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }

        // Paired and saved; a failed backfill is finished by the next `sync push`.
        var outcome: MachineSyncPushOutcome?
        var pushError: String?
        do {
            outcome = try await MachineSyncPusher.push(environment: Self.syncEnvironment())
        } catch {
            pushError = Self.syncErrorMessage(error)
        }
        let backfilledDays = Self.uploadedDays(outcome)

        switch output.format {
        case .text:
            print(Self.syncPairText(result, backfilledDays: backfilledDays, pushError: pushError))
        case .json:
            Self.printJSON(
                SyncPairPayload(
                    machineId: result.settings.machineID,
                    displayName: result.settings.displayName,
                    server: result.link.baseURL,
                    backfilledDays: backfilledDays,
                    pushError: pushError),
                pretty: output.pretty)
        }
        Self.exit(code: .success, output: output)
    }

    static func runSyncStatus(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let environment = Self.syncEnvironment()
        let settings: MachineSyncSettings?
        do {
            settings = try environment.store.loadSettings()
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }
        var reportingDay = settings?.reportingDay ?? MachineSyncReportingDay()
        if let timeZone = values.options["timezone"]?.last {
            reportingDay.timeZone = timeZone
        }
        if let rawHour = values.options["dayStart"]?.last {
            guard let hour = Int(rawHour) else {
                Self.exit(
                    code: .failure,
                    message: "--day-start takes an hour from 0 to 23.",
                    output: output,
                    kind: .args)
            }
            reportingDay.startHour = hour
        }
        guard reportingDay.isValid else {
            Self.exit(
                code: .failure,
                message: "Invalid Reporting Day: use an IANA timezone (e.g. Europe/Berlin) and a start hour 0-23.",
                output: output,
                kind: .args)
        }

        let refresh: MachineSyncRefreshResult
        do {
            refresh = try await MachineSyncReader.refresh(environment: environment)
        } catch {
            Self.exit(code: .failure, message: Self.syncErrorMessage(error), output: output, kind: .runtime)
        }
        let status = MachineSyncStatus(
            cache: refresh.cache,
            thisMachineID: settings?.machineID,
            reportingDay: reportingDay,
            now: environment.now())

        switch output.format {
        case .text:
            print(Self.syncStatusText(status))
        case .json:
            Self.printJSON(status, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output)
    }

    /// `true` unless `link` is plain http to a host that isn't loopback and the user didn't pass `--yes` or
    /// answer yes at the prompt (§2). Non-interactive runs without `--yes` are refused.
    private static func confirmCleartext(
        _ link: MachineSyncPairingLink,
        values: ParsedValues,
        output: CLIOutputPreferences) -> Bool
    {
        guard link.cleartextWarning else { return true }
        writeStderr(self.syncCleartextWarning(host: link.host))
        if values.flags.contains("yes") { return true }
        guard !output.usesJSONOutput, isatty(STDIN_FILENO) == 1 else { return false }
        writeStderr("Continue over plain http:// anyway? [y/N] ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return ["y", "yes"].contains(answer)
    }

    private static func uploadedDays(_ outcome: MachineSyncPushOutcome?) -> Int {
        guard case let .pushed(uploaded, _) = outcome else { return 0 }
        return uploaded.count(where: { $0.hasPrefix("day-") })
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

    static func syncPairText(_ result: MachineSyncPairResult, backfilledDays: Int, pushError: String?) -> String {
        var lines = [
            "Joined the Sync Group on \(result.link.baseURL).",
            "This Machine is \"\(result.settings.displayName ?? result.settings.machineID)\".",
        ]
        if let pushError {
            lines.append("The backfill failed and will be finished by `codexbar sync push`: \(pushError)")
        } else {
            lines.append("Backfilled \(backfilledDays) \(backfilledDays == 1 ? "day" : "days") of Spend.")
        }
        lines.append("Run `codexbar sync status` to see every Machine.")
        return lines.joined(separator: "\n")
    }

    static func syncStatusText(_ status: MachineSyncStatus) -> String {
        let boundary = String(format: "%02d:00", status.reportingDay.startHour)
        var lines = [
            "Today is \(status.today) (Reporting Day: \(status.reportingDay.timeZone), days start at \(boundary)).",
        ]
        if status.machines.isEmpty {
            lines.append("")
            lines.append("No Machine has pushed Spend yet.")
        }
        for machine in status.machines {
            var header = machine.displayName
            if machine.isThisMachine { header += " (this Machine)" }
            let state = machine.retired ? "retired" : machine.active ? "active" : "inactive"
            header += " · \(state) · last seen \(Self.syncLastSeenText(machine.lastSeen, now: status.generatedAt))"
            lines += ["", header]
            lines.append("  Today    \(Self.syncSpendText(machine.today))")
            lines.append("  30 days  \(Self.syncSpendText(machine.last30Days))")
            if let coverage = machine.coverage {
                lines.append("  Coverage \(coverage.from) to \(coverage.to)")
            } else {
                lines.append("  Coverage none yet")
            }
            let width = machine.models.map { $0.provider.count + $0.model.count + 1 }.max() ?? 0
            for model in machine.models {
                let label = "\(model.provider) \(model.model)"
                let padding = String(repeating: " ", count: width - label.count)
                lines.append("    \(label)\(padding)  \(Self.syncCostText(model.spend))")
            }
        }
        if status.machines.count > 1 {
            lines += [
                "",
                "All Machines: today \(Self.syncCostText(status.total.today)) · "
                    + "30 days \(Self.syncCostText(status.total.last30Days))",
            ]
        }
        if !status.errors.isEmpty {
            let names = Dictionary(
                status.machines.map { ($0.machineId, $0.displayName) },
                uniquingKeysWith: { first, _ in first })
            lines += ["", "Skipped \(status.errors.count) unreadable \(status.errors.count == 1 ? "blob" : "blobs"):"]
            for error in status.errors {
                lines.append("  \(names[error.machineID] ?? error.machineID) \(error.name): \(error.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func syncCostText(_ spend: MachineSyncStatus.Spend) -> String {
        let cost = UsageFormatter.currencyString(spend.costUSD, currencyCode: "USD")
        return spend.costIncomplete ? "\(cost) + unpriced" : cost
    }

    private static func syncSpendText(_ spend: MachineSyncStatus.Spend) -> String {
        "\(self.syncCostText(spend)) · \(UsageFormatter.tokenCountString(spend.totalTokens)) tokens · "
            + "\(spend.requests) \(spend.requests == 1 ? "request" : "requests")"
    }

    static func syncLastSeenText(_ lastSeen: Date?, now: Date) -> String {
        guard let lastSeen else { return "never" }
        let seconds = Int(now.timeIntervalSince(lastSeen))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
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

private struct SyncPairPayload: Encodable {
    let machineId: String
    let displayName: String?
    let server: String
    let backfilledDays: Int
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

    @Flag(names: [.short("y"), .long("yes")], help: "Use plain http:// to a non-loopback host without asking")
    var yes: Bool = false
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

struct SyncPairOptions: CommanderParsable {
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

    @Argument(help: "Pairing Link (codexbar-sync://...)")
    var link: String = ""

    @Option(name: .long("name"), help: "Display name for this Machine (default: hostname)")
    var name: String?

    @Flag(names: [.short("y"), .long("yes")], help: "Pair over plain http:// to a non-loopback host without asking")
    var yes: Bool = false
}

struct SyncStatusOptions: CommanderParsable {
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

    @Option(name: .long("timezone"), help: "Reporting Day timezone (IANA, e.g. Europe/Berlin; default: system)")
    var timezone: String?

    @Option(name: .long("day-start"), help: "Hour (0-23) at which a Reporting Day starts (default: 0)")
    var dayStart: String?
}
