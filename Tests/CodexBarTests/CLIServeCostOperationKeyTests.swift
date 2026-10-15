import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIServeCostOperationKeyTests {
    @Test
    func `cost operation key separates windows and keeps the cost prefix`() throws {
        let weekKey = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 7), provider: nil)
        let monthKey = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 30), provider: nil)
        let codexKey = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 7), provider: "codex")

        #expect(weekKey != monthKey)
        #expect(weekKey != codexKey)
        #expect([weekKey, monthKey, codexKey].allSatisfy { $0.hasPrefix("cost:") })
    }

    @Test
    func `rolling window cost key keeps last good provider rows`() async throws {
        let key = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 7), provider: nil)
        let (wallClock, cache) = makeServeTestCache()

        _ = await CodexBarCLI.cachedServeResponse(key: key, cache: cache, refreshInterval: 0.01) {
            Self.response(#"[{"provider":"codex","call":1},{"provider":"claude","call":1}]"#)
        }
        wallClock.advance(by: 0.01)

        let partial = await CodexBarCLI.cachedServeResponse(key: key, cache: cache, refreshInterval: 0.01) {
            Self.response("""
            [
              {"provider":"codex","call":2},
              {"provider":"claude","error":{"message":"claude cost refresh timed out"}}
            ]
            """)
        }
        let rows = try #require(JSONSerialization.jsonObject(with: partial.body) as? [[String: Any]])
        #expect(Self.row(rows, provider: "codex")?["call"] as? Int == 2)
        #expect(Self.row(rows, provider: "claude")?["call"] as? Int == 1)
        #expect(rows.allSatisfy { $0["error"] == nil })
    }

    private static func response(_ body: String) -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(status: .ok, body: Data(body.utf8))
    }

    private static func row(_ rows: [[String: Any]], provider: String) -> [String: Any]? {
        rows.first { $0["provider"] as? String == provider }
    }
}
