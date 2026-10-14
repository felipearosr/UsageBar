import CodexBarCore
import Foundation

enum CLIErrorKind: String, Encodable, Sendable {
    case args
    case config
    case provider
    case runtime
}

struct ProviderErrorPayload: Encodable, Sendable {
    let code: Int32
    let message: String
    let kind: CLIErrorKind?
    /// Stable, machine-readable name for the failure (for example `timeout`), so clients can explain it
    /// without matching on `message`. Omitted from the encoded payload when nil.
    var reason: String?

    init(code: Int32, message: String, kind: CLIErrorKind?, reason: String? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
        self.reason = reason
    }
}

/// Errors that can name their failure with a stable `reason` string in CLI error payloads.
protocol CLIErrorReasonProviding: Error {
    var cliErrorReason: String { get }
}

extension CodexBarCLI {
    static func makeErrorPayload(_ error: Error, kind: CLIErrorKind? = nil) -> ProviderErrorPayload {
        ProviderErrorPayload(
            code: self.mapError(error).rawValue,
            message: error.localizedDescription,
            kind: kind,
            reason: (error as? any CLIErrorReasonProviding)?.cliErrorReason)
    }

    static func makeErrorPayload(
        code: ExitCode,
        message: String,
        kind: CLIErrorKind? = nil,
        reason: String? = nil) -> ProviderErrorPayload
    {
        ProviderErrorPayload(code: code.rawValue, message: message, kind: kind, reason: reason)
    }

    static func makeCLIErrorProviderPayload(
        message: String,
        code: ExitCode,
        kind: CLIErrorKind,
        reason: String? = nil) -> ProviderPayload
    {
        ProviderPayload(
            providerID: "cli",
            account: nil,
            version: nil,
            source: "cli",
            status: nil,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: ProviderErrorPayload(code: code.rawValue, message: message, kind: kind, reason: reason))
    }

    static func makeCLIErrorPayload(
        message: String,
        code: ExitCode,
        kind: CLIErrorKind,
        reason: String? = nil,
        pretty: Bool) -> String?
    {
        let payload = self.makeCLIErrorProviderPayload(message: message, code: code, kind: kind, reason: reason)
        return self.encodeJSON([payload], pretty: pretty)
    }

    static func makeProviderErrorPayload(
        provider: UsageProvider,
        account: String?,
        cacheAccountKey: String? = nil,
        source: String,
        status: ProviderStatusPayload?,
        error: Error,
        kind: CLIErrorKind = .provider) -> ProviderPayload
    {
        ProviderPayload(
            provider: provider,
            account: account,
            cacheAccountKey: cacheAccountKey,
            version: nil,
            source: source,
            status: status,
            usage: nil,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: self.makeErrorPayload(error, kind: kind))
    }

    static func encodeJSON(_ payload: some Encodable, pretty: Bool) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func printJSON(_ payload: some Encodable, pretty: Bool) {
        if let output = self.encodeJSON(payload, pretty: pretty) {
            print(output)
        }
    }

    /// Renders as TOON when the caller requested `usage --format toon`, JSON otherwise. Error/exit
    /// paths must honor this too, or `--format toon` silently falls back to JSON on any early failure
    /// (invalid arguments, config load errors, provider errors).
    static func renderProviderPayloads(_ payloads: [ProviderPayload], output: CLIOutputPreferences) -> String {
        if output.toonRequested {
            return ToonFormatter.encode(payloads)
        }
        return self.encodeJSON(payloads, pretty: output.pretty) ?? ""
    }

    static func printProviderPayloads(_ payloads: [ProviderPayload], output: CLIOutputPreferences) {
        print(self.renderProviderPayloads(payloads, output: output))
    }

    static func exit(
        code: ExitCode,
        message: String? = nil,
        output: CLIOutputPreferences? = nil,
        kind: CLIErrorKind = .runtime,
        reason: String? = nil) -> Never
    {
        if self.shouldPrintExitError(code: code, message: message) {
            if let output, output.usesJSONOutput {
                self.printProviderPayloads(
                    [self.makeCLIErrorProviderPayload(message: message ?? "", code: code, kind: kind, reason: reason)],
                    output: output)
            } else if let message {
                self.writeStderr("\(message)\n")
            }
        }
        platformExit(code.rawValue)
    }

    static func shouldPrintExitError(code: ExitCode, message: String?) -> Bool {
        code != .success && message != nil
    }
}
