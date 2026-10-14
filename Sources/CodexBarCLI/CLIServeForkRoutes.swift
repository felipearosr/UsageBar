import Foundation

// MARK: - UsageBar serve route-extension hook

/// Routes UsageBar adds to upstream's `codexbar serve`. Upstream's `handleServeRequest` carries one call into this
/// file, before its own router, so upstream's route and runtime changes rarely conflict with the fork:
/// - `forkServeResponse(_:runtime:)` gets first refusal on every request. It answers a fork route (including the
///   405 for a fork path with the wrong method) or returns `nil`, and upstream's router handles the request as if
///   the fork weren't there.
extension CodexBarCLI {
    static func forkServeResponse(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime) async -> CLILocalHTTPResponse?
    {
        let route: CLIServeSyncRoute?
        do {
            route = try CLIServeSyncRoute.route(
                method: request.method,
                path: request.path,
                queryItems: request.queryItems)
        } catch {
            // Same answer upstream's router gives a wrong method: no auth check, no Cache-Control.
            return self.forkServeError(status: .methodNotAllowed, message: "method not allowed")
        }
        guard let route else { return nil }
        return await self.serveSyncRoute(route, request: request, runtime: runtime)
    }

    /// Upstream's private `serveJSON`, for fork routes: compact JSON with ISO 8601 dates.
    static func forkServeJSON(_ payload: some Encodable, status: CLIHTTPStatus = .ok) -> CLILocalHTTPResponse {
        let json = self.encodeJSON(payload, pretty: false) ?? "{}"
        return CLILocalHTTPResponse(status: status, body: Data(json.utf8))
    }

    /// Upstream's private `serveError`: `{"error": message}`.
    static func forkServeError(status: CLIHTTPStatus, message: String) -> CLILocalHTTPResponse {
        self.forkServeJSON(ForkServeErrorPayload(error: message), status: status)
    }
}

private struct ForkServeErrorPayload: Encodable {
    let error: String
}
