import Foundation
import SweetCookieKit

public enum OpenCodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple OpenCode Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    /// Auto stays Chrome-only by default, with Dia as the bounded exception for a confirmed reporter need.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .dia]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencode,
            settingsSection: .init(
                OpenCodeProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .opencode)
                    return OpenCodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 2),
            metadata: ProviderMetadata(
                id: .opencode,
                displayName: "OpenCode",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode usage",
                cliName: "opencode",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "OpenCode debug log not yet implemented",
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://opencode.ai/auth",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .opencode),
                iconResourceName: "ProviderIcon-opencode",
                color: ProviderColor(hex: 0x3B82F6),
                confettiPalette: [
                    ProviderColor(hex: 0x211E1E),
                    ProviderColor(hex: 0xCFCECD),
                    ProviderColor(hex: 0xFAB283),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "OpenCode cost summary is not supported." }),
            pace: ProviderPaceCapability(secondary: .weekly),
            presentation: ProviderUsagePresentation(costPresenter: { snapshot in
                // A pay-as-you-go workspace with no configured limit has no percentage to show,
                // so it renders spend and remaining balance instead of the generic budget bar.
                let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                    ? .payAsYouGoSpend
                    : .generic
                return ProviderCostPresentation(menuCardStyle: style)
            }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "opencode",
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    sourceMode == .auto || settings?.opencode?.cookieSource == .manual
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        if context.sourceMode == .web {
            return [OpenCodeUsageFetchStrategy()]
        }
        return [
            OpenCodeUsageFetchStrategy(),
            OpenCodeLocalUsageFetchStrategy(),
        ]
    }
}

struct OpenCodeLocalUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencode.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try OpenCodeLocalUsageReader().fetch()
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "local")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        error is OpenCodeLocalUsageError
    }
}

struct OpenCodeUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencode.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.opencode?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let workspaceOverride = context.settings?.opencode?.workspaceID
            ?? context.env["CODEXBAR_OPENCODE_WORKSPACE_ID"]
        let cookieSource = context.settings?.opencode?.cookieSource ?? .auto
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch OpenCodeUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .opencode)
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await OpenCodeUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride)
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw OpenCodeUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return switch error {
        case OpenCodeSettingsError.missingCookie,
             OpenCodeSettingsError.invalidCookie,
             OpenCodeUsageError.invalidCredentials:
            true
        default:
            false
        }
    }

    private static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencode,
                provider: .opencode,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeSettingsError.invalidCookie,
            missingCookie: OpenCodeSettingsError.missingCookie)
    }
}

enum OpenCodeSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No OpenCode session cookies found in browsers."
        case .invalidCookie:
            "OpenCode cookie header is invalid."
        }
    }
}
