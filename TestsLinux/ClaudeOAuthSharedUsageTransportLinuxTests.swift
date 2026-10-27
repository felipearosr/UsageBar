#if os(Linux)
import Foundation
import FoundationNetworking
import Testing
@testable import CodexBarCore

struct ClaudeOAuthSharedUsageTransportLinuxTests {
    actor Stub: ProviderHTTPTransport {
        var calls = 0
        let status: Int
        let body: Data
        let retryAfter: String?
        init(status: Int = 200, retryAfter: String? = "900") {
            self.retryAfter = retryAfter
            self.status = status
            self
                .body = Data(
                    #"{"five_hour":{"utilization":42,"resets_at":"2026-10-22T00:00:00Z"},"grant_id":"secret-grant"}"#
                        .utf8)
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.calls += 1
            try await Task.sleep(for: .milliseconds(20))
            return (self.body, HTTPURLResponse(
                url: request.url!,
                statusCode: self.status,
                httpVersion: nil,
                headerFields: self.retryAfter.map { ["Retry-After": $0] })!)
        }
    }

    private func request(_ token: String = "account-a") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test
    func `independent transports coalesce concurrent fetches and isolate credentials`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        let a = ClaudeOAuthSharedUsageTransport(upstream: stub, directory: directory)
        let b = ClaudeOAuthSharedUsageTransport(upstream: stub, directory: directory)
        let request = self.request()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await a.data(for: request) }
            group.addTask { _ = try await b.data(for: request) }
            try await group.waitForAll()
        }
        #expect(await stub.calls == 1)
        let (cached, _) = try await b.data(for: request)
        let text = try #require(String(data: cached, encoding: .utf8))
        #expect(!text.contains("secret-grant"))
        #expect(text.contains("42"))
        _ = try await b.data(for: self.request("account-b"))
        #expect(await stub.calls == 2)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(!file.lastPathComponent.contains("account-a"))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
        }
    }

    @Test
    func `repeated rate limits exponentially back off without a server delay`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = Stub(status: 429, retryAfter: nil)
        var elapsed: TimeInterval = 0
        for expected in [300, 600, 1200, 2400, 3600, 3600] {
            let instant = start.addingTimeInterval(elapsed)
            let transport = ClaudeOAuthSharedUsageTransport(upstream: stub, directory: directory, now: { instant })
            let (_, response) = try await transport.data(for: self.request())
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") == String(expected))
            elapsed += Double(expected) + 1
        }
        #expect(await stub.calls == 6)
    }

    @Test
    func `rate limit cooldown is shared across instances and respects retry after`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = Stub(status: 429)
        let a = ClaudeOAuthSharedUsageTransport(upstream: stub, directory: directory, now: { now })
        let b = ClaudeOAuthSharedUsageTransport(upstream: stub, directory: directory, now: { now })
        _ = try await a.data(for: self.request())
        let (_, response) = try await b.data(for: self.request())
        #expect(await stub.calls == 1)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") == "900")
        let later = ClaudeOAuthSharedUsageTransport(
            upstream: stub,
            directory: directory,
            now: { now.addingTimeInterval(901) })
        _ = try await later.data(for: self.request())
        #expect(await stub.calls == 2)
    }
}
#endif
