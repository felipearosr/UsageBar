#if os(Linux)
import Foundation
import FoundationNetworking
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Same-user, cross-process coordination for the default OAuth usage transport.
/// Never stores bearer tokens, response headers, or reset-credit grant identifiers.
struct ClaudeOAuthSharedUsageTransport: ProviderHTTPTransport {
    let upstream: any ProviderHTTPTransport
    let directory: URL
    let now: @Sendable () -> Date
    static let freshness: TimeInterval = 300

    init(
        upstream: any ProviderHTTPTransport,
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.upstream = upstream
        let environment = ProcessInfo.processInfo.environment
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        self.directory = directory ?? cache.appendingPathComponent("usagebar/claude-oauth")
        self.now = now
    }

    private struct State: Codable {
        var savedAt: Date?
        var usage: Data?
        var blockedUntil: Date?
        var failures = 0
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              let url = request.url, url.path == "/api/oauth/usage"
        else { return try await self.upstream.data(for: request) }
        let key = ClaudeOAuthCredentialsStore.sha256Hex(Data(authorization.utf8))
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lockPath = self.directory.appendingPathComponent(key + ".lock").path
        #if canImport(Glibc)
        let fd = Glibc.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        #else
        let fd = Musl.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        #endif
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        #if canImport(Glibc)
        defer { _ = Glibc.close(fd) }
        #else
        defer { _ = Musl.close(fd) }
        #endif
        let deadline = ContinuousClock.now.advanced(by: .seconds(95))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw POSIXError(.EIO) }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { _ = flock(fd, LOCK_UN) }
        try Task.checkCancellation()
        let file = self.directory.appendingPathComponent(key + ".json")
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State()
        let now = self.now()
        // Manual refresh must not bypass a shared server-imposed cooldown.
        if let until = state.blockedUntil, until > now {
            return (Data(), HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": String(Int(ceil(until
                        .timeIntervalSince(now))))])!)
        }
        if let saved = state.savedAt, let usage = state.usage,
           now >= saved, now.timeIntervalSince(saved) < Self.freshness
        {
            return (usage, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let (data, response) = try await self.upstream.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, response) }
        switch http.statusCode {
        case 200:
            // Only validated, quota-only data is persisted. The live caller keeps
            // the full response, including optional reset inventory.
            _ = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
            state = try State(savedAt: self.now(), usage: Self.quotaData(data))
        case 429:
            state.failures = min(state.failures + 1, 5)
            let fallback = min(300 * pow(2, Double(state.failures - 1)), 3600)
            let received = self.now()
            state.blockedUntil = max(
                Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: received)
                    ?? received,
                received.addingTimeInterval(fallback))
        case 401:
            // Do not reuse a previously successful response after rejection.
            state = State()
        default:
            return (data, response)
        }
        let encoded = try JSONEncoder().encode(state)
        try encoded.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if http.statusCode == 429, let until = state.blockedUntil {
            return (data, HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": String(Int(ceil(until
                        .timeIntervalSince(self.now()))))])!)
        }
        return (data, response)
    }

    private static func quotaData(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var quota: [String: Any] = [:]
        let windowKeys = [
            "five_hour",
            "seven_day",
            "seven_day_oauth_apps",
            "seven_day_opus",
            "seven_day_sonnet",
            "seven_day_routines",
            "seven_day_claude_routines",
            "claude_routines",
            "routines",
            "routine",
            "seven_day_cowork",
            "cowork",
        ]
        for (key, value) in object where windowKeys.contains(key) {
            guard let window = value as? [String: Any] else { continue }
            var safe: [String: Any] = [:]
            if let utilization = window["utilization"] as? NSNumber { safe["utilization"] = utilization }
            if let resets = window["resets_at"] as? String { safe["resets_at"] = resets }
            quota[key] = safe
        }
        if let extra = object["extra_usage"] as? [String: Any] {
            quota["extra_usage"] = extra.filter { key, value in
                ["is_enabled", "monthly_limit", "used_credits", "utilization"].contains(key)
                    && (value is NSNumber || value is NSNull)
            }
        }
        if let currency = (quota["extra_usage"] as? [String: Any]),
           let value = (object["extra_usage"] as? [String: Any])?["currency"] as? String
        {
            quota["extra_usage"] = currency.merging(["currency": value]) { _, new in new }
        }
        if let limits = object["limits"] as? [[String: Any]] {
            quota["limits"] = limits.map { entry -> [String: Any] in
                var safe: [String: Any] = [:]
                for key in ["kind", "group", "resets_at"] {
                    if let value = entry[key] as? String { safe[key] = value }
                }
                for key in ["percent", "is_active"] {
                    if let value = entry[key] as? NSNumber { safe[key] = value }
                }
                if let scope = entry["scope"] as? [String: Any], let model = scope["model"] as? [String: Any] {
                    safe["scope"] = ["model": model.filter { key, value in
                        ["id", "display_name"].contains(key) && value is String
                    }]
                }
                return safe
            }
        }
        return try JSONSerialization.data(withJSONObject: quota)
    }

    private static func retryAfter(_ raw: String?, now: Date) -> Date? {
        guard let raw else { return nil }
        if let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }
}
#endif
