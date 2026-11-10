import Crypto
import Foundation

// MARK: - UsageBar action token for serve's mutating fork routes

/// The shared secret that gates every fork route that changes state on this Machine (today `/accounts/add`,
/// `/accounts/rename` and `/accounts/remove`; later the managed-account and claude-swap routes).
///
/// Whoever starts `codexbar serve` (the GNOME extension's serve supervisor) generates a fresh random token per
/// spawn and passes it in `USAGEBAR_SERVE_ACTION_TOKEN`. A mutating request must send it back in the
/// `X-UsageBar-Action-Token` header. Loopback serve has no other auth, so without this any local process (or another
/// user on the same Machine) could add or remove accounts. It is separate from the dashboard bearer, which guards
/// data routes on non-loopback binds and is checked as well.
///
/// Fails closed: a serve started without the variable refuses every mutating route (403) and `/health` leaves the
/// action capabilities out, so clients don't offer actions that can't work. Comparison is constant-time over SHA-256
/// digests. The token is never logged or echoed.
///
/// Every mutating fork route, now and later (managed Codex accounts #169, switching #171, claude-swap #172), must
/// call `refuseUnlessMutatingForkRequestAllowed` before it reads its body; it is the only gate. `/sync/push` predates
/// the guard and stays outside it, since the tray and CLI users call it without a token.
///
/// Provider fetches get an environment without the token (`scrubbingServeSecrets`, applied where the CLI builds
/// each provider's environment), so provider CLIs that serve runs don't inherit it.
struct CLIServeActionGuard: Sendable {
    static let environmentKey = "USAGEBAR_SERVE_ACTION_TOKEN"
    static let headerName = "X-UsageBar-Action-Token"

    /// Tests set this instead of the process environment.
    @TaskLocal static var override: CLIServeActionGuard?

    /// The guard this serve process uses: the override, else the token serve was started with.
    static var current: CLIServeActionGuard {
        self.override ?? self.fromEnvironment
    }

    private static let fromEnvironment = CLIServeActionGuard(
        token: ProcessInfo.processInfo.environment[CLIServeActionGuard.environmentKey])

    private let expectedDigest: [UInt8]?

    init(token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.expectedDigest = trimmed.isEmpty ? nil : Array(SHA256.hash(data: Data(trimmed.utf8)))
    }

    /// False when serve was started without a token: every mutating route is then refused.
    var isConfigured: Bool {
        self.expectedDigest != nil
    }

    func authorize(_ request: CLILocalHTTPRequest) -> Bool {
        guard let expectedDigest,
              let presented = request.forkFields.actionToken,
              !presented.isEmpty
        else { return false }
        let digest = Array(SHA256.hash(data: Data(presented.utf8)))
        return CLIServeDashboardAuth.constantTimeEquals(digest, expectedDigest)
    }
}

extension CLIServeActionGuard {
    /// `environment` without serve's secrets, for a provider fetch and the processes it starts.
    static func scrubbingServeSecrets(_ environment: [String: String]) -> [String: String] {
        var scrubbed = environment
        scrubbed.removeValue(forKey: self.environmentKey)
        return scrubbed
    }
}

extension CodexBarCLI {
    /// The checks every mutating fork route runs before it reads its body, in order: the data-route bearer on
    /// non-loopback binds (401), the action token (403), and no `Origin` header (403; browsers send one on every
    /// POST, UsageBar's own clients never do). nil when the request may go on.
    static func refuseUnlessMutatingForkRequestAllowed(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime,
        actionGuard: CLIServeActionGuard = .current) -> CLILocalHTTPResponse?
    {
        guard !runtime.dataRoutesRequireAuth || runtime.dashboardAuth.authorize(request) else {
            return self.serveUnauthorizedResponse()
        }
        guard actionGuard.authorize(request) else {
            return self.addingNoStore(self.forkServeError(status: .forbidden, message: "missing or wrong action token"))
        }
        guard request.forkFields.origin == nil else {
            return self.addingNoStore(self.forkServeError(status: .forbidden, message: "forbidden origin"))
        }
        return nil
    }
}
