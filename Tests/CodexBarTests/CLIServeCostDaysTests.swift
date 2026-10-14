import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIServeCostDaysTests {
    @Test
    func `routes cost with an optional days window`() throws {
        #expect(try CLIServeRouter.route(method: "GET", path: "/cost", queryItems: [:]) == .cost(
            provider: nil,
            days: nil))
        #expect(
            try CLIServeRouter.route(
                method: "GET",
                path: "/cost",
                queryItems: ["provider": "codex", "days": "90"]) == .cost(provider: "codex", days: 90))
    }

    @Test
    func `cost days query is clamped and ignores non integers`() throws {
        func days(_ raw: String) throws -> Int? {
            guard case let .cost(_, days) = try CLIServeRouter.route(
                method: "GET",
                path: "/cost",
                queryItems: ["days": raw])
            else {
                Issue.record("Expected cost route")
                return nil
            }
            return days
        }
        #expect(try days("7") == 7)
        #expect(try days(" 30 ") == 30)
        #expect(try days("0") == 1)
        #expect(try days("-5") == 1)
        #expect(try days("1000") == 365)
        #expect(try days("abc") == nil)
        #expect(try days("") == nil)
    }

    @Test
    func `cost operation key separates reporting periods and keeps the cost prefix`() throws {
        let week = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 7), provider: "codex")
        let quarter = try CodexBarCLI.serveCostOperationKey(period: .rolling(days: 90), provider: "codex")
        let monthToDate = try CodexBarCLI.serveCostOperationKey(period: .monthToDate, provider: nil)
        #expect(week != quarter)
        #expect(try week == (CodexBarCLI.serveCostOperationKey(period: .rolling(days: 7), provider: "codex")))
        #expect([week, quarter, monthToDate].allSatisfy { $0.hasPrefix("cost:") })
    }

    @Test
    func `concurrent cost requests with different days do not share an in-flight result`() async throws {
        let cache = CLIServeResponseCache()
        let counter = CostDaysCallCounter()
        let windows = [7, 30, 90]
        let keys = try windows.map {
            try CodexBarCLI.serveCostOperationKey(period: .rolling(days: $0), provider: "codex")
        }

        let responses = await withTaskGroup(of: (Int, CLILocalHTTPResponse).self) { group in
            for (days, key) in zip(windows, keys) {
                for _ in 0..<2 {
                    group.addTask {
                        let response = await CodexBarCLI.cachedServeResponse(
                            key: key,
                            cache: cache,
                            refreshInterval: 60,
                            requestTimeout: 5,
                            configFingerprint: "rolling:\(days)")
                        {
                            _ = await counter.increment()
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            return Self.jsonResponse("[{\"provider\":\"codex\",\"days\":\(days)}]")
                        }
                        return (days, response)
                    }
                }
            }
            var responses: [(Int, CLILocalHTTPResponse)] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        #expect(await counter.current() == windows.count)
        #expect(responses.count == windows.count * 2)
        for (days, response) in responses {
            #expect(response.status == .ok)
            #expect(try Self.jsonRows(response).first?["days"] as? Int == days)
        }
    }

    private static func jsonResponse(_ body: String) -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(status: .ok, body: Data(body.utf8))
    }

    private static func jsonRows(_ response: CLILocalHTTPResponse) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }
}

private actor CostDaysCallCounter {
    private var value = 0

    func increment() -> Int {
        self.value += 1
        return self.value
    }

    func current() -> Int {
        self.value
    }
}
