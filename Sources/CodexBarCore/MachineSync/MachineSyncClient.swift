import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MachineSyncError: Error, Equatable, LocalizedError {
    case notPaired
    case alreadyPaired
    case unsupportedServer
    case enrollmentTokenRequired
    /// A `codexbar-sync+http://` link to a host that isn't loopback, used without the user's confirmation.
    case cleartextNotConfirmed(host: String)
    /// The server answered with an error body (§6.8).
    case server(status: Int, code: String?, message: String?, retryAfter: TimeInterval?)
    /// The request never got an HTTP answer.
    case network(String)
    case invalidResponse(status: Int)
    /// No Machine in the Sync Group has this ID or display name.
    case machineNotFound(String)
    /// More than one Machine has this display name; pass the Machine ID instead.
    case ambiguousMachine(name: String, machineIDs: [String])
    /// `retire` and `forget` act on other Machines; this one would push itself back.
    case isThisMachine(command: String)
    /// The group `retired` blob kept changing under us (§5.3).
    case retiredConflict
    /// The group `retired` blob exists but this client can't read it, so rewriting it would lose data.
    case unreadableRetiredBlob
    /// Another process on this Machine holds the push lock.
    case pushInProgress

    public var errorDescription: String? {
        switch self {
        case .notPaired:
            return "Machine Sync is off. Run `codexbar sync create --server <url>` first."
        case .alreadyPaired:
            return "This Machine already belongs to a Sync Group. Leave it before creating or joining another."
        case .unsupportedServer:
            return "This server doesn't speak Machine Sync protocol v1."
        case .enrollmentTokenRequired:
            return "This server requires an Enrollment Token. Pass it with --token."
        case let .cleartextNotConfirmed(host):
            return "This Sync Group would use plain http:// to \(host). Pass --yes to continue anyway."
        case let .network(details):
            return "Couldn't reach the Sync Server: \(details)"
        case let .invalidResponse(status):
            return "The Sync Server sent an unexpected response (HTTP \(status))."
        case let .machineNotFound(query):
            return "No Machine in this Sync Group is called \"\(query)\". Run `codexbar sync status` to list them."
        case let .ambiguousMachine(name, machineIDs):
            return "More than one Machine is called \"\(name)\". Use its Machine ID instead: "
                + machineIDs.joined(separator: ", ") + "."
        case let .isThisMachine(command):
            return "That is this Machine. Run `codexbar sync \(command)` from another Machine, "
                + "or `codexbar sync leave` to unpair this one."
        case .retiredConflict:
            return "Other Machines kept changing the retired list at the same time. Try again."
        case .unreadableRetiredBlob:
            return "The Sync Group's retired list can't be read by this version, so it was left unchanged."
        case .pushInProgress:
            return "A push is running on this Machine right now. Try again in a moment."
        case let .server(status, code, message, _):
            if let text = Self.text(forCode: code) { return text }
            let fallback = message.map { ": \($0)" } ?? ""
            return "The Sync Server returned HTTP \(status)\(fallback)."
        }
    }

    /// Worth retrying later with backoff: rate limits, server outages, and network failures.
    public var isTransient: Bool {
        switch self {
        case .network: true
        case let .server(status, _, _, _): status == 429 || status >= 500
        default: false
        }
    }

    public var retryAfter: TimeInterval? {
        if case let .server(_, _, _, retryAfter) = self { return retryAfter }
        return nil
    }

    private static func text(forCode code: String?) -> String? {
        switch code {
        case "enrollment_required":
            "This server requires an Enrollment Token. Pass it with --token."
        case "enrollment_invalid":
            "The Enrollment Token isn't valid for this server. Check it and try again."
        case "enrollment_expired":
            "The Enrollment Token or Sync Group has expired."
        case "enrollment_used":
            "This Enrollment Token has already created a Sync Group. Each token creates exactly one."
        case "group_exists":
            "A Sync Group with this ID already exists on the server."
        case "group_not_found":
            "The server doesn't know this Sync Group, or the key is wrong."
        case "machine_limit":
            "This Sync Group has reached its Machine limit."
        case "payload_too_large":
            "A blob is larger than the server allows."
        case "rate_limited":
            "The Sync Server is rate limiting requests. Try again later."
        case "precondition_failed":
            "The blob changed on the server while it was being updated."
        default:
            nil
        }
    }
}

/// HTTP client for the Sync Server API (§6).
public struct MachineSyncClient: Sendable {
    public struct ServerInfo: Decodable, Sendable, Equatable {
        public let protocols: [Int]
        public let enrollment: String
        public let maxBlobBytes: Int?
        public let retentionDays: Int?
        public let operatorName: String?

        enum CodingKeys: String, CodingKey {
            case protocols
            case enrollment
            case maxBlobBytes
            case retentionDays
            case operatorName = "operator"
        }
    }

    public struct Limits: Decodable, Sendable, Equatable {
        public let maxMachines: Int?
        public let retentionDays: Int?
        public let expiresAt: String?
    }

    /// One page of `GET /changes` (§6.5).
    public struct ChangesPage: Decodable, Sendable {
        public struct Machine: Decodable, Sendable, Equatable {
            public let machineId: String
            public let lastSeen: String?
        }

        public struct Blob: Decodable, Sendable, Equatable {
            public let machineId: String
            public let name: String
            /// Base64 envelope.
            public let body: String
        }

        public let limits: Limits?
        public let machines: [Machine]
        public let blobs: [Blob]
        public let cursor: String
        public let hasMore: Bool
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
            let message: String?
        }

        let error: Detail
    }

    private struct LimitsBody: Decodable {
        let limits: Limits
    }

    private struct PutBody: Decodable {
        let etag: String?
    }

    public let apiBaseURL: String
    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval

    public init(
        apiBaseURL: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = 30)
    {
        self.apiBaseURL = apiBaseURL
        self.transport = transport
        self.timeout = timeout
    }

    public func info() async throws -> ServerInfo {
        let data = try await self.send(self.request(path: "/info", method: "GET"))
        return try self.decode(ServerInfo.self, from: data, status: 200)
    }

    public func createGroup(keys: MachineSyncKeys, enrollmentToken: String?) async throws -> Limits {
        var request = try self.request(path: "/groups", method: "POST")
        if let enrollmentToken {
            request.setValue("Enrollment \(enrollmentToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "groupId": keys.groupIDBase64URL,
            "authKeyHash": keys.authKeyHashBase64URL,
        ])
        let data = try await self.send(request)
        return try self.decode(LimitsBody.self, from: data, status: 200).limits
    }

    /// PUTs `envelope` and returns the new ETag. With `ifMatch`, the server answers `412 precondition_failed`
    /// unless the stored blob still has that ETag (§6.4).
    @discardableResult
    public func putBlob(
        _ envelope: Data,
        at address: MachineSyncBlobAddress,
        keys: MachineSyncKeys,
        ifMatch: String? = nil) async throws -> String?
    {
        var request = try self.request(path: Self.blobPath(address), method: "PUT")
        request.setValue(keys.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let ifMatch {
            request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        }
        request.httpBody = envelope
        let (data, response) = try await self.sendReturningResponse(request)
        let body = try? JSONDecoder().decode(PutBody.self, from: data)
        return body?.etag ?? response.value(forHTTPHeaderField: "ETag")
    }

    /// One stored envelope and its ETag (§6.6), or `nil` when nothing is stored at `address`.
    public func getBlob(at address: MachineSyncBlobAddress, keys: MachineSyncKeys) async throws
        -> (envelope: Data, etag: String?)?
    {
        var request = try self.request(path: Self.blobPath(address), method: "GET")
        request.setValue(keys.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await self.sendReturningResponse(request)
            return (data, response.value(forHTTPHeaderField: "ETag"))
        } catch let MachineSyncError.server(status, code, _, _) where status == 404 && code == "blob_not_found" {
            return nil
        }
    }

    /// Deletes a Machine and all its blobs (§6.7, "forget this Machine").
    public func deleteMachine(_ machineID: String, keys: MachineSyncKeys) async throws {
        var request = try self.request(
            path: "/groups/\(keys.groupIDBase64URL)/machines/\(machineID)",
            method: "DELETE")
        request.setValue(keys.authorizationHeader, forHTTPHeaderField: "Authorization")
        _ = try await self.send(request)
    }

    private static func blobPath(_ address: MachineSyncBlobAddress) -> String {
        "/groups/\(address.groupID)/machines/\(address.machineID)/blobs/\(address.name)"
    }

    /// Everything written since `cursor`, or everything when `cursor` is `nil`.
    public func changes(keys: MachineSyncKeys, since cursor: String?, limit: Int) async throws -> ChangesPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            query.insert(URLQueryItem(name: "since", value: cursor), at: 0)
        }
        var request = try self.request(path: "/groups/\(keys.groupIDBase64URL)/changes", method: "GET", query: query)
        request.setValue(keys.authorizationHeader, forHTTPHeaderField: "Authorization")
        let data = try await self.send(request)
        return try self.decode(ChangesPage.self, from: data, status: 200)
    }

    private func request(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: self.apiBaseURL + path) else {
            throw MachineSyncError.invalidResponse(status: 0)
        }
        if !query.isEmpty {
            components.queryItems = query
            // The cursor is opaque; `+` would otherwise reach the server as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw MachineSyncError.invalidResponse(status: 0) }
        var request = URLRequest(url: url, timeoutInterval: self.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try await self.sendReturningResponse(request).data
    }

    private func sendReturningResponse(_ request: URLRequest) async throws
        -> (data: Data, response: HTTPURLResponse)
    {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MachineSyncError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MachineSyncError.invalidResponse(status: 0) }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw MachineSyncError.server(
                status: http.statusCode,
                code: body?.error.code,
                message: body?.error.message,
                retryAfter: retryAfter)
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MachineSyncError.invalidResponse(status: status)
        }
    }
}
