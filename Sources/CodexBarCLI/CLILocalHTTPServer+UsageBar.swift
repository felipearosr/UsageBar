import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - UsageBar request bodies for serve's fork routes

/// What fork POST routes need from a request beyond upstream's fields: its body, `Content-Type`, `Origin` and
/// `X-UsageBar-Action-Token` (CLIServeActionGuard.swift).
/// Upstream's server reads only a request's head; its `readRequest` and `parse` each carry one hook into this file,
/// so a request with a `Content-Length` arrives here with its body and every other request is unchanged.
struct CLILocalHTTPRequestForkFields: Equatable, Sendable {
    /// The largest body serve reads. Account actions send a label and one key or cookie header.
    static let maximumBodyBytes = 64 * 1024

    var contentType: String?
    /// Browsers send `Origin` on every cross-site POST; fork routes that change state refuse any request with one.
    var origin: String?
    /// The secret mutating fork routes require; never logged.
    var actionToken: String?
    var body = Data()

    init(contentType: String? = nil, origin: String? = nil, actionToken: String? = nil, body: Data = Data()) {
        self.contentType = contentType
        self.origin = origin
        self.actionToken = actionToken
        self.body = body
    }

    /// The fields of a complete request (`data` is its head and, when it declares a `Content-Length`, its body).
    init(parsing data: Data) {
        guard let headEnd = Self.headEnd(of: data) else { return }
        let headers = Self.headers(data[data.startIndex..<headEnd])
        self.contentType = headers.first { $0.name == "content-type" }?.value
        self.origin = headers.first { $0.name == "origin" }?.value
        let actionHeader = CLIServeActionGuard.headerName.lowercased()
        self.actionToken = headers.first { $0.name == actionHeader }?.value
        let length = Self.contentLength(headers) ?? 0
        self.body = Data(data[headEnd...].prefix(length))
    }

    /// The body's length a request head declares: 0 without `Content-Length`, nil when it is malformed, repeated
    /// with different values, or over `maximumBodyBytes`.
    static func declaredBodyLength(head: Data) -> Int? {
        self.contentLength(self.headers(head))
    }

    static func headEnd(of data: Data) -> Data.Index? {
        data.range(of: Data("\r\n\r\n".utf8))?.upperBound
    }

    private static func contentLength(_ headers: [(name: String, value: String)]) -> Int? {
        let values = Set(headers.filter { $0.name == "content-length" }.map(\.value))
        guard let value = values.first else { return 0 }
        guard values.count == 1,
              !value.isEmpty,
              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let length = Int(value),
              length <= self.maximumBodyBytes
        else { return nil }
        return length
    }

    /// Header names lowercased, values trimmed; lines without a colon are skipped (upstream's parse rejects them).
    private static func headers(_ head: Data) -> [(name: String, value: String)] {
        guard let raw = String(data: head, encoding: .utf8) else { return [] }
        return raw.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
    }
}

extension CLILocalHTTPRequest {
    /// `parse`'s hook: this request with the fork fields read from the same bytes.
    func withForkFields(from data: Data) -> CLILocalHTTPRequest {
        var request = self
        request.forkFields = CLILocalHTTPRequestForkFields(parsing: data)
        return request
    }

    var body: Data {
        self.forkFields.body
    }
}

/// `readRequest`'s hook, once the head is in: reads the rest of the body its `Content-Length` declares, within the
/// same overall read deadline as the head. False for a malformed or oversized length, or a body that doesn't arrive
/// in time; the server then answers 400 as it does for a bad head. Without a `Content-Length` it reads nothing.
///
/// This changes upstream's behaviour for any request that declares a `Content-Length`, on every route: upstream
/// answered after the head and ignored the body, while serve now waits for the declared body (within the request's
/// read deadline) and answers 400 for a malformed, conflicting or over-64 KiB length. Requests without one are
/// unchanged.
func forkReadRequestBody(
    _ data: inout Data,
    fd: Int32,
    startedAt: UInt64,
    totalReadTimeoutMilliseconds: Int64) -> Bool
{
    guard let headEnd = CLILocalHTTPRequestForkFields.headEnd(of: data),
          let length = CLILocalHTTPRequestForkFields.declaredBodyLength(head: data[data.startIndex..<headEnd])
    else { return false }
    let expected = headEnd + length
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < expected {
        let elapsedMilliseconds = Int64((DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000)
        let remainingMilliseconds = totalReadTimeoutMilliseconds - elapsedMilliseconds
        guard remainingMilliseconds > 0 else { return false }
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, Int32(min(remainingMilliseconds, 5000)))
        if ready < 0, errno == EINTR { continue }
        guard ready > 0 else { return false }
        let wanted = min(buffer.count, expected - data.count)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            recv(fd, rawBuffer.baseAddress, wanted, 0)
        }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { return false }
        data.append(buffer, count: count)
    }
    return true
}
