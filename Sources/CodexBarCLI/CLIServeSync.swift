import CodexBarCore
import Foundation

/// Runs one Machine Sync refresh and one push at a time for `codexbar serve`. A request that arrives while the
/// same operation is running waits for it and shares its result instead of starting a second one.
actor CLIServeSyncCoordinator {
    private var refreshTask: Task<Result<MachineSyncRefreshResult, any Error>, Never>?
    private var pushTask: Task<Result<MachineSyncPushOutcome, any Error>, Never>?

    func refresh(environment: MachineSyncEnvironment) async -> Result<MachineSyncRefreshResult, any Error> {
        if let running = self.refreshTask { return await running.value }
        let task = Task { await Self.capture { try await MachineSyncReader.refresh(environment: environment) } }
        self.refreshTask = task
        let result = await task.value
        self.refreshTask = nil
        return result
    }

    func push(environment: MachineSyncEnvironment) async -> Result<MachineSyncPushOutcome, any Error> {
        if let running = self.pushTask { return await running.value }
        let task = Task { await Self.capture { try await MachineSyncPusher.push(environment: environment) } }
        self.pushTask = task
        let result = await task.value
        self.pushTask = nil
        return result
    }

    private static func capture<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do {
            return try await .success(body())
        } catch {
            return .failure(error)
        }
    }
}

/// `GET /sync/status`: what the Machines view shows.
struct ServeSyncStatusPayload: Encodable {
    /// `false` hides every Machine Sync surface; the other fields are then absent.
    let paired: Bool
    /// Built from the decrypted cache. After a failed refresh this is the last good data.
    let status: MachineSyncStatus?
    /// When the cache last read the Sync Server successfully.
    let refreshedAt: Date?
    /// Why this request's refresh failed; `status` is then stale.
    let error: String?

    static let notPaired = ServeSyncStatusPayload(paired: false, status: nil, refreshedAt: nil, error: nil)
}

extension CodexBarCLI {
    static func serveSyncEnvironment() -> MachineSyncEnvironment {
        MachineSyncEnvironment(clientVersion: currentVersion() ?? "unknown")
    }

    static func serveSyncStatus(
        refresh: Bool,
        environment: MachineSyncEnvironment,
        coordinator: CLIServeSyncCoordinator) async -> CLILocalHTTPResponse
    {
        do {
            return try await self.serveJSON(self.serveSyncStatusPayload(
                refresh: refresh,
                environment: environment,
                coordinator: coordinator))
        } catch {
            return self.serveError(status: .internalServerError, message: self.syncErrorMessage(error))
        }
    }

    /// Reads only local files unless `refresh` is set, so surfaces can call it on every poll to learn whether this
    /// Machine is paired. A refresh that fails falls back to the cached copy and reports why.
    static func serveSyncStatusPayload(
        refresh: Bool,
        environment: MachineSyncEnvironment,
        coordinator: CLIServeSyncCoordinator) async throws -> ServeSyncStatusPayload
    {
        guard let settings = try environment.store.loadSettings(), let rawLink = settings.pairingLink else {
            return .notPaired
        }
        let groupID = try MachineSyncPairingLink(parsing: rawLink).keys.groupIDBase64URL

        var cache: MachineSyncCache?
        var refreshError: String?
        if refresh {
            switch await coordinator.refresh(environment: environment) {
            case let .success(result):
                cache = result.cache
            case let .failure(error):
                if case MachineSyncError.notPaired = error { return .notPaired }
                refreshError = self.syncErrorMessage(error)
            }
        }
        if cache == nil, let saved = try? environment.store.loadCache(), saved.groupID == groupID {
            cache = saved
        }
        let status = cache.map {
            MachineSyncStatus(
                cache: $0,
                thisMachineID: settings.machineID,
                reportingDay: settings.reportingDay ?? MachineSyncReportingDay(),
                now: environment.now())
        }
        return ServeSyncStatusPayload(
            paired: true,
            status: status,
            refreshedAt: cache?.refreshedAt,
            error: refreshError)
    }

    /// `POST /sync/push`: `409` when this Machine isn't paired, `502` when the push failed.
    static func serveSyncPush(
        environment: MachineSyncEnvironment,
        coordinator: CLIServeSyncCoordinator) async -> CLILocalHTTPResponse
    {
        switch await coordinator.push(environment: environment) {
        case let .success(outcome):
            return self.serveJSON(SyncPushPayload(outcome))
        case let .failure(error):
            if case MachineSyncError.notPaired = error {
                return self.serveError(status: .conflict, message: self.syncErrorMessage(error))
            }
            return self.serveError(status: .badGateway, message: self.syncErrorMessage(error))
        }
    }
}
