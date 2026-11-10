import CodexBarCore
import Foundation

// MARK: - claude-swap detect on serve (#172)

/// `POST /accounts/claude-swap/detect`: finds claude-swap's `cswap` (`ClaudeSwapExecutableDetector`) and, when it is
/// there, saves its absolute path as the Claude provider's `claudeSwapExecutablePath` and turns `claudeSwapEnabled`
/// on, so serve's Claude rows come from claude-swap (#170). The GNOME extension calls it before **Add account…** on
/// Claude (to choose between the install offer and the add helper) and again after the install terminal exits.
///
/// It changes the config, so it goes through `refuseUnlessMutatingForkRequestAllowed` and writes under the config
/// file's lock with the same `editingConfig` the account actions use. It reads no body, runs nothing, and never
/// touches claude-swap's or Claude Code's storage. A configured path that still resolves wins over detection. With no
/// binary it answers `installed: false` and leaves the config alone.
enum CLIServeClaudeSwapSetupRoute: Equatable {
    case detect

    static let detectPath = "/accounts/claude-swap/detect"

    /// nil for another path; throws for this path with the wrong method.
    static func route(method: String, path: String) throws -> CLIServeClaudeSwapSetupRoute? {
        guard path == self.detectPath else { return nil }
        guard method.uppercased() == "POST" else { throw CLIServeRouteError.methodNotAllowed }
        return .detect
    }
}

struct ClaudeSwapDetectPayload: Encodable, Equatable {
    static let notInstalledMessage = "claude-swap is not installed."

    let installed: Bool
    /// The absolute `cswap` path now in the config; absent when not installed.
    let executablePath: String?
    /// `claudeSwapEnabled` after this call.
    let enabled: Bool
    let message: String?
}

/// What detection looks at: the process environment and home, unless a test overrides them.
struct ClaudeSwapDetectEnvironment: Sendable {
    @ProcessEnvironment var environment: [String: String]
    let home: String

    @TaskLocal static var override: ClaudeSwapDetectEnvironment?

    static var current: ClaudeSwapDetectEnvironment {
        self.override ?? ClaudeSwapDetectEnvironment(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory())
    }
}

extension CodexBarCLI {
    static func serveClaudeSwapSetupRoute(
        _ route: CLIServeClaudeSwapSetupRoute,
        request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse
    {
        if let refusal = self.refuseUnlessMutatingForkRequestAllowed(request, runtime: runtime) {
            return refusal
        }
        switch route {
        case .detect:
            let context = ClaudeSwapDetectEnvironment.current
            do {
                let payload = try await self.detectClaudeSwap(
                    store: runtime.configStore,
                    environment: context.environment,
                    home: context.home)
                return self.addingNoStore(self.forkServeJSON(payload))
            } catch let error as ProviderAccountActionError {
                return self.addingNoStore(self.forkServeError(status: error.status, message: error.message))
            } catch {
                let error = ProviderAccountActionError.storeFailed
                return self.addingNoStore(self.forkServeError(status: error.status, message: error.message))
            }
        }
    }

    /// Detects `cswap` and saves its path and the enabled flag. Writes only when either changes.
    static func detectClaudeSwap(
        store: CodexBarConfigStore,
        environment: [String: String],
        home: String) async throws -> ClaudeSwapDetectPayload
    {
        let provider = ClaudeSwapServeSource.provider
        let current: CodexBarConfig?
        do {
            current = try store.load()
        } catch {
            throw ProviderAccountActionError.storeFailed
        }
        let entry = current?.providerConfig(for: provider.instanceID)
        guard let path = ClaudeSwapExecutableDetector.configuredOrDetected(
            configured: entry?.claudeSwapExecutablePath,
            environment: environment,
            home: home)
        else {
            return ClaudeSwapDetectPayload(
                installed: false,
                executablePath: nil,
                enabled: entry?.claudeSwapEnabled == true,
                message: ClaudeSwapDetectPayload.notInstalledMessage)
        }
        let unchanged = entry?.claudeSwapEnabled == true && entry?.sanitizedClaudeSwapExecutablePath == path
        guard !unchanged else {
            return ClaudeSwapDetectPayload(installed: true, executablePath: path, enabled: true, message: nil)
        }
        // Decide again under the lock: another writer may have set a path since the read above, and a configured
        // path that still resolves wins over the one detected here.
        let (saved, _): (String?, Int) = try await self.editingConfig(
            store: store,
            provider: provider,
            createIfMissing: true)
        { config in
            var entry = config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
            guard let path = ClaudeSwapExecutableDetector.configuredOrDetected(
                configured: entry.claudeSwapExecutablePath,
                environment: environment,
                home: home)
            else { return nil }
            if entry.claudeSwapEnabled != true || entry.sanitizedClaudeSwapExecutablePath != path {
                entry.claudeSwapExecutablePath = path
                entry.claudeSwapEnabled = true
                config.setProviderConfig(entry)
            }
            return path
        }
        guard let saved else {
            return ClaudeSwapDetectPayload(
                installed: false,
                executablePath: nil,
                enabled: false,
                message: ClaudeSwapDetectPayload.notInstalledMessage)
        }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "claude-swap detected and enabled",
            metadata: ["provider": provider.rawValue])
        return ClaudeSwapDetectPayload(installed: true, executablePath: saved, enabled: true, message: nil)
    }
}
