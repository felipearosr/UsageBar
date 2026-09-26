import CodexBarCore
import Commander
import Foundation

/// `sync info` (what a Sync Server asks for before creating a group) and `sync settings` (this Machine's local
/// Machine Sync settings, including the Reporting Day). Both exist so surfaces such as the GNOME preferences can
/// drive Machine Sync through the CLI without reading `sync.json`, which holds the Pairing Link.
extension CodexBarCLI {
    static func runSyncInfo(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        guard let server = values.options["server"]?.last else {
            Self.exit(code: .failure, message: "Missing --server <url>.", output: output, kind: .args)
        }
        let result: MachineSyncServerInfo
        do {
            result = try await MachineSyncServerProbe.info(serverURL: server, environment: Self.syncEnvironment())
        } catch {
            Self.syncFail(error, output: output)
        }
        switch output.format {
        case .text:
            print(Self.syncInfoText(result))
        case .json:
            Self.printJSON(SyncInfoPayload(result), pretty: output.pretty)
        }
        Self.exit(code: .success, output: output)
    }

    static func runSyncSettings(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        let environment = Self.syncEnvironment()
        do {
            var settings = try environment.store.loadSettings()
            if let reportingDay = try Self.syncReportingDayChange(values, current: settings?.reportingDay) {
                settings = try MachineSyncManager.setReportingDay(reportingDay.value, environment: environment)
            }
            let payload = try SyncSettingsPayload(settings)
            switch output.format {
            case .text:
                print(Self.syncSettingsText(payload))
            case .json:
                Self.printJSON(payload, pretty: output.pretty)
            }
        } catch let error as SyncSettingsArgumentError {
            Self.exit(code: .failure, message: error.message, output: output, kind: .args)
        } catch {
            Self.syncFail(error, output: output)
        }
        Self.exit(code: .success, output: output)
    }

    /// The Reporting Day `values` asks for, or `nil` when they don't change it. `--reset-reporting-day` and
    /// `--timezone system` go back to the system timezone; an option left out keeps its current value.
    static func syncReportingDayChange(
        _ values: ParsedValues,
        current: MachineSyncReportingDay?) throws -> SyncSettingChange<MachineSyncReportingDay?>?
    {
        if values.flags.contains("resetReportingDay") {
            return SyncSettingChange(value: nil)
        }
        let timeZone = values.options["timezone"]?.last?.trimmingCharacters(in: .whitespaces)
        let rawHour = values.options["dayStart"]?.last
        guard timeZone != nil || rawHour != nil else { return nil }

        var reportingDay = current ?? MachineSyncReportingDay()
        if let timeZone {
            reportingDay.timeZone = timeZone.isEmpty || timeZone.lowercased() == "system" ? nil : timeZone
        }
        if let rawHour {
            guard let hour = Int(rawHour.trimmingCharacters(in: .whitespaces)) else {
                throw SyncSettingsArgumentError(message: "--day-start takes an hour from 0 to 23.")
            }
            reportingDay.startHour = hour
        }
        return SyncSettingChange(value: reportingDay)
    }

    static func syncInfoText(_ result: MachineSyncServerInfo) -> String {
        var lines = ["Sync Server \(result.baseURL)"]
        if let name = result.info.operatorName, !name.isEmpty {
            lines.append("Operator: \(name)")
        }
        if !result.supported {
            lines.append(MachineSyncError.unsupportedServer.errorDescription ?? "")
        }
        let enrollment = switch result.info.enrollment {
        case "required": "an Enrollment Token is required to create a Sync Group"
        case "optional": "an Enrollment Token is optional"
        default: "open, no Enrollment Token needed"
        }
        lines.append("Enrollment: \(enrollment)")
        if let days = result.info.retentionDays {
            lines.append("Retention: \(days) days")
        }
        if result.cleartextWarning {
            lines.append(Self.syncCleartextWarning(host: result.host).trimmingCharacters(in: .newlines))
        }
        return lines.joined(separator: "\n")
    }

    static func syncSettingsText(_ payload: SyncSettingsPayload) -> String {
        var lines: [String] = []
        if let server = payload.server {
            lines.append("In a Sync Group on \(server).")
        } else {
            lines.append("Not in a Sync Group.")
        }
        if let machineId = payload.machineId {
            lines.append("This Machine is \"\(payload.displayName ?? machineId)\" (\(machineId)).")
        }
        let day = payload.reportingDay
        let zone = day.timeZone ?? "system timezone, \(day.effectiveTimeZone)"
        lines.append("Reporting Day: \(zone), days start at \(String(format: "%02d:00", day.startHour)).")
        return lines.joined(separator: "\n")
    }
}

/// A requested change; `value` itself may be `nil` ("reset").
struct SyncSettingChange<Value> {
    let value: Value
}

private struct SyncSettingsArgumentError: Error {
    let message: String
}

struct SyncInfoPayload: Encodable {
    let server: String
    let host: String
    let protocols: [Int]
    let supported: Bool
    /// `none`, `optional`, or `required` (§6.2).
    let enrollment: String
    /// Display text chosen by the server operator; show it as-is.
    let `operator`: String?
    let retentionDays: Int?
    let cleartextWarning: Bool

    init(_ result: MachineSyncServerInfo) {
        self.server = result.baseURL
        self.host = result.host
        self.protocols = result.info.protocols
        self.supported = result.supported
        self.enrollment = result.info.enrollment
        self.operator = result.info.operatorName
        self.retentionDays = result.info.retentionDays
        self.cleartextWarning = result.cleartextWarning
    }
}

/// Local Machine Sync settings without the Pairing Link.
struct SyncSettingsPayload: Encodable {
    struct ReportingDay: Encodable {
        /// IANA identifier as saved; `nil` follows the system timezone.
        let timeZone: String?
        let startHour: Int
        /// The timezone days are grouped in right now.
        let effectiveTimeZone: String
    }

    let paired: Bool
    let machineId: String?
    let displayName: String?
    /// The Sync Server's address (never the key).
    let server: String?
    let reportingDay: ReportingDay

    init(_ settings: MachineSyncSettings?) throws {
        self.paired = settings?.pairingLink != nil
        self.machineId = settings?.machineID
        self.displayName = settings?.displayName
        self.server = try settings?.pairingLink.map { try MachineSyncPairingLink(parsing: $0).baseURL }
        let day = settings?.reportingDay ?? MachineSyncReportingDay()
        self.reportingDay = ReportingDay(
            timeZone: day.timeZone,
            startHour: day.startHour,
            effectiveTimeZone: day.resolvedTimeZone.identifier)
    }
}

struct SyncInfoOptions: CommanderParsable {
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
}

struct SyncSettingsOptions: CommanderParsable {
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

    @Option(name: .long("timezone"), help: "Save the Reporting Day timezone (IANA, e.g. Europe/Berlin, or system)")
    var timezone: String?

    @Option(name: .long("day-start"), help: "Save the hour (0-23) at which a Reporting Day starts")
    var dayStart: String?

    @Flag(name: .long("reset-reporting-day"), help: "Go back to the system timezone with days starting at 00:00")
    var resetReportingDay: Bool = false
}
