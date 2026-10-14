import Foundation

// MARK: - UsageBar CLI capabilities

/// Features this `codexbar` build has, for clients that check before they use one: the GNOME extension's
/// Settings runs `codexbar --version --json`, and anything talking to `codexbar serve` reads `GET /health`.
/// Both come from `CLICapabilitiesPayload`, which lists every case here, so the two can't disagree.
enum CLICapability: String, CaseIterable, Encodable, Sendable {
    /// `codexbar sync` and serve's `/sync/status` and `/sync/push`.
    case machineSync
}

/// The version and capability fields shared by `codexbar --version --json` and serve's `GET /health`.
///
/// `version` is what `codexbar --version` prints (the VERSION file next to the binary). A UsageBar release
/// writes it as `<upstream base>+usagebar.<UsageBar version>` (linux/release/resolve-version.sh), and the two
/// halves are reported on their own. A build whose version isn't in that form (a dev build, upstream's own
/// CLI) reports neither half. Absent values are left out of the JSON, as `/health` always did for `version`.
struct CLICapabilitiesPayload: Encodable, Equatable, Sendable {
    /// Only `/health` sets it, to keep its existing `"status": "ok"`.
    let status: String?
    let version: String?
    let usagebarVersion: String?
    let upstreamBase: String?
    let capabilities: [CLICapability]

    init(version: String?, status: String? = nil) {
        self.status = status
        self.version = version
        let parts = version.flatMap(Self.releaseParts(of:))
        self.upstreamBase = parts?.upstreamBase
        self.usagebarVersion = parts?.usagebarVersion
        self.capabilities = CLICapability.allCases
    }

    static func health(version: String?) -> Self {
        Self(version: version, status: "ok")
    }

    /// Splits `<upstream base>+usagebar.<UsageBar version>`; nil when `version` isn't in that form.
    static func releaseParts(of version: String) -> (upstreamBase: String, usagebarVersion: String)? {
        guard let marker = version.range(of: "+usagebar.") else { return nil }
        let upstreamBase = String(version[..<marker.lowerBound])
        let usagebarVersion = String(version[marker.upperBound...])
        guard !upstreamBase.isEmpty, !usagebarVersion.isEmpty else { return nil }
        return (upstreamBase, usagebarVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case version
        case usagebarVersion
        case upstreamBase
        case capabilities
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.status, forKey: .status)
        try container.encodeIfPresent(self.version, forKey: .version)
        try container.encodeIfPresent(self.usagebarVersion, forKey: .usagebarVersion)
        try container.encodeIfPresent(self.upstreamBase, forKey: .upstreamBase)
        try container.encode(self.capabilities, forKey: .capabilities)
    }
}

extension CodexBarCLI {
    /// `codexbar --version --json` (or `-V --json`): the capabilities payload instead of the version line. Runs
    /// from `main()`'s version fast path, before config, logging, plugins or any provider code, so it reads
    /// nothing but the VERSION file and can't touch accounts, credentials or the network.
    static func forkPrintVersionJSONIfRequested(argv: [String]) {
        guard let json = self.forkVersionJSON(argv: argv, version: self.currentVersion()) else { return }
        print(json)
        self.platformExit(0)
    }

    /// The `--version --json` output for `argv`, or nil when `argv` doesn't ask for JSON.
    static func forkVersionJSON(argv: [String], version: String?) -> String? {
        guard argv.contains("--json") else { return nil }
        return self.encodeJSON(CLICapabilitiesPayload(version: version), pretty: true)
    }
}
