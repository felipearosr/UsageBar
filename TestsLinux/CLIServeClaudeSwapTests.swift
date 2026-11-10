import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// serve's Claude rows with claude-swap enabled (#170). A fake `cswap` (or an in-memory list read through the real
/// schema-v1 parser) stands in for claude-swap, a stub for upstream's Claude fetch, and statusLine captures and
/// Claude Code configs live in temporary directories: no test runs a real `cswap` or `claude`, or reads a credential.
struct CLIServeClaudeSwapTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    private static let personalID = "claude-swap:1"
    private static let workID = "claude-swap:2"

    /// Two schema-v1 slots; slot 2 is active. The extra fields stand for what raw stdout may carry beyond the
    /// projection; none of them may reach a response.
    private static let twoAccounts = """
    {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
     {"number":1,"email":"personal@example.com","organizationName":"","active":false,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":10,"resetsAt":"2026-09-21T18:00:00Z"},
               "sevenDay":{"pct":20,"resetsAt":"2026-09-25T00:00:00Z"}},
      "usageFetchedAt":"2026-09-21T14:00:00Z",
      "accessToken":"sk-ant-oat01-fixture-secret","refreshToken":"fixture-refresh-secret"},
     {"number":2,"email":"work@example.com","organizationName":"Example Org","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":30,"resetsAt":"2026-09-21T18:00:00Z"},
               "sevenDay":{"pct":40,"resetsAt":"2026-09-25T00:00:00Z"}},
      "usageFetchedAt":"2026-09-21T14:10:00Z","credentialEmail":"hidden-extra@example.com"}]}
    """

    private static let rawOnlyMarkers = ["sk-ant-oat01-fixture-secret", "fixture-refresh-secret", "hidden-extra"]

    // MARK: Fixtures

    /// A fake `cswap` on disk: it appends its arguments to `<path>.args` and prints `<path>.json`.
    private struct FakeCSwap {
        let directory: URL
        let executable: URL

        init() throws {
            self.directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIServeClaudeSwapTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            self.executable = self.directory.appendingPathComponent("cswap")
            // The trampoline runs this body as `<path>.sh`.
            try FakeExecutable.install(#"""
            #!/bin/sh
            base="${0%.sh}"
            printf '%s\n' "$@" >> "$base.args"
            if [ "$#" -ne 2 ] || [ "$1" != "--list" ] || [ "$2" != "--json" ]; then
              exit 64
            fi
            exec /bin/cat "$base.json"
            """#, at: self.executable)
        }

        func respond(_ json: String) throws {
            try Data(json.utf8).write(to: self.executable.appendingPathExtension("json"))
        }

        var invocations: [String] {
            let text = (try? String(contentsOf: self.executable.appendingPathExtension("args"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    private static func config(swapEnabled: Bool?, path: String?, statusLineFeed: Bool = false) -> CodexBarConfig {
        var claude = ProviderConfig(id: UsageProvider.claude.instanceID, enabled: true)
        claude.claudeSwapEnabled = swapEnabled
        claude.claudeSwapExecutablePath = path
        if statusLineFeed {
            claude.setExtensionValue(true, forKey: ClaudeStatusLineFeed.configKey)
        }
        return CodexBarConfig(providers: [claude])
    }

    private static func source(
        _ cswap: FakeCSwap,
        state: ClaudeSwapServeState = ClaudeSwapServeState(),
        capture: ClaudeSwapStatusLineCapture? = nil) -> ClaudeSwapServeSource
    {
        ClaudeSwapServeSource(
            executablePath: cswap.executable.path,
            state: state,
            loadCapture: { _ in capture },
            now: { Self.now })
    }

    /// A source whose list read parses `json` with the real schema-v1 parser, without a subprocess.
    private static func source(
        json: @escaping @Sendable () -> String,
        state: ClaudeSwapServeState = ClaudeSwapServeState(),
        capture: ClaudeSwapStatusLineCapture? = nil) -> ClaudeSwapServeSource
    {
        ClaudeSwapServeSource(
            executablePath: "/fake/cswap",
            state: state,
            readList: { _, _ in try ClaudeSwapListParser.parse(Data(json().utf8)) },
            loadCapture: { _ in capture },
            now: { Self.now })
    }

    actor CallLog {
        private(set) var calls: [String] = []
        func record(_ call: String) {
            self.calls.append(call)
        }
    }

    /// Upstream's Claude fetch: one ambient row, and a record of the call.
    private static func ambientFetch(_ calls: CallLog) -> CodexBarCLI.ProviderAccountUsageFetch {
        { provider, selector in
            await calls.record("\(provider.rawValue):\(selector.map { "\($0)" } ?? "default")")
            var output = UsageCommandOutput()
            output.payload = [ProviderPayload(
                provider: provider,
                account: nil,
                version: nil,
                source: "oauth",
                status: nil,
                usage: UsageSnapshot(
                    primary: RateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Self.now),
                credits: nil,
                antigravityPlanInfo: nil,
                openaiDashboard: nil,
                error: nil)]
            return output
        }
    }

    private static func serve(
        _ config: CodexBarConfig,
        fetch: @escaping CodexBarCLI.ProviderAccountUsageFetch,
        claudeSwap: ClaudeSwapServeSource? = nil,
        deadline: ContinuousClock.Instant? = nil) async -> CLILocalHTTPResponse
    {
        await CodexBarCLI.serveProviderAccountUsage(
            provider: "claude",
            context: ServeUsageContext(
                config: config,
                configFingerprint: "test",
                refreshInterval: 60,
                providerTimeout: nil,
                providerDeadline: deadline,
                providerOperations: CLIServeOperationCoordinator()),
            fetch: fetch,
            claudeSwap: claudeSwap)
    }

    private static func rows(_ response: CLILocalHTTPResponse) throws -> [[String: Any]] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }

    private static func primaryPercent(_ row: [String: Any]) -> Double? {
        ((row["usage"] as? [String: Any])?["primary"] as? [String: Any])?["usedPercent"] as? Double
    }

    private static func errorMessage(_ row: [String: Any]) -> String? {
        (row["error"] as? [String: Any])?["message"] as? String
    }

    private static func sameJSON(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let lhs = try? JSONSerialization.jsonObject(with: lhs) as? NSArray,
              let rhs = try? JSONSerialization.jsonObject(with: rhs) as? NSArray
        else { return false }
        return lhs.isEqual(rhs)
    }

    private static func capture(
        email: String,
        organization: String,
        capturedAt: Date = Self.now.addingTimeInterval(-60),
        fiveHour: Double = 77) -> ClaudeSwapStatusLineCapture
    {
        ClaudeSwapStatusLineCapture(
            account: ClaudeCodeSignedInAccount(accountUuid: "uuid-1", email: email, organizationName: organization),
            limits: ClaudeStatusLineRateLimits(
                profileID: "profile",
                accountID: "account-hash",
                capturedAt: capturedAt,
                fiveHour: ClaudeStatusLineWindow(
                    usedPercent: fiveHour,
                    resetsAt: Date(timeIntervalSince1970: 1_790_020_000)),
                sevenDay: nil))
    }

    // MARK: Rows

    @Test
    func `two schema-v1 accounts become two tagged Claude rows from one exact list read`() async throws {
        let cswap = try FakeCSwap()
        try cswap.respond(Self.twoAccounts)
        let calls = CallLog()
        let response = await Self.serve(
            Self.config(swapEnabled: true, path: cswap.executable.path),
            fetch: Self.ambientFetch(calls),
            claudeSwap: Self.source(cswap))
        #expect(response.status == .ok)
        let rows = try Self.rows(response)
        // The projection lists the active slot first.
        #expect(rows.map { $0["accountId"] as? String } == [Self.workID, Self.personalID])
        #expect(rows.map { $0["accountSource"] as? String } == ["claude-swap", "claude-swap"])
        #expect(rows.map { $0["accountLabel"] as? String } == ["work@example.com", "personal@example.com"])
        #expect(rows.map { $0["active"] as? Bool } == [true, false])
        // updatedAt is claude-swap's usageFetchedAt, not the time of this read.
        #expect(rows.map { $0["updatedAt"] as? String } == ["2026-09-21T14:10:00Z", "2026-09-21T14:00:00Z"])
        #expect(rows.map { Self.primaryPercent($0) } == [30, 10])
        #expect(rows.allSatisfy { $0["provider"] as? String == "claude" && $0["source"] as? String == "claude-swap" })
        #expect(rows.allSatisfy { $0["error"] == nil && $0["stale"] == nil })
        #expect(response.usageCacheKeys == [Self.workID, Self.personalID])
        // Exactly `cswap --list --json`, once, and no separate Claude fetch.
        #expect(cswap.invocations == ["--list", "--json"])
        #expect(await calls.calls.isEmpty)
        // Only projected fields: nothing raw stdout carried beyond them, and no adapter name posing as a plan.
        let body = try #require(String(bytes: response.body, encoding: .utf8))
        for marker in Self.rawOnlyMarkers {
            #expect(!body.contains(marker))
        }
        #expect(!body.contains("\"loginMethod\""))
    }

    @Test
    func `plain usage gets the active slot's row untagged without an ambient fetch`() async throws {
        let cswap = try FakeCSwap()
        try cswap.respond(Self.twoAccounts)
        let calls = CallLog()
        let ambient = Self.ambientFetch(calls)
        let output = await CodexBarCLI.serveClaudeSwapOrFetch(provider: .claude, claudeSwap: Self.source(cswap)) {
            await ambient(.claude, nil)
        }
        #expect(output.payload.count == 1)
        let row = try #require(output.payload.first)
        #expect(row.provider == "claude")
        #expect(row.account == nil)
        #expect(row.cacheAccountKey == Self.workID)
        #expect(row.usage?.primary?.usedPercent == 30)
        #expect(row.usage?.identity?.accountEmail == "work@example.com")
        #expect(await calls.calls.isEmpty)
        #expect(cswap.invocations == ["--list", "--json"])
        // Encoded like any plain row: no Provider Account keys.
        let json = try #require(String(bytes: JSONEncoder().encode(row), encoding: .utf8))
        #expect(!json.contains("accountId"))
    }

    @Test
    func `plain usage keeps the ambient fetch when no slot is active`() async {
        let noActive = Self.twoAccounts
            .replacingOccurrences(of: #""activeAccountNumber":2"#, with: #""activeAccountNumber":null"#)
            .replacingOccurrences(of: #""active":true"#, with: #""active":false"#)
        let calls = CallLog()
        let ambient = Self.ambientFetch(calls)
        let output = await CodexBarCLI.serveClaudeSwapOrFetch(
            provider: .claude,
            claudeSwap: Self.source(json: { noActive }))
        {
            await ambient(.claude, nil)
        }
        #expect(await calls.calls == ["claude:default"])
        #expect(output.payload.map(\.source) == ["oauth"])
    }

    @Test
    func `an empty claude-swap list keeps upstream's single Claude row`() async throws {
        let empty = #"{"schemaVersion":1,"activeAccountNumber":null,"accounts":[]}"#
        let calls = CallLog()
        let rows = try await Self.rows(Self.serve(
            Self.config(swapEnabled: true, path: "/fake/cswap"),
            fetch: Self.ambientFetch(calls),
            claudeSwap: Self.source(json: { empty })))
        #expect(rows.count == 1)
        #expect(rows.first?["accountId"] == nil)
        #expect(await calls.calls == ["claude:default"])
    }

    @Test
    func `made-up labels carry accountLabelIsDefault and real ones don't`() async throws {
        let json = """
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
         {"number":1,"email":"same@example.com","organizationName":"","active":true,"usageStatus":"no_credentials"},
         {"number":2,"email":"same@example.com","organizationName":"","active":false,"usageStatus":"no_credentials"},
         {"number":3,"email":"","organizationName":"","active":false,"usageStatus":"no_credentials"},
         {"number":4,"email":"same@example.com","organizationName":"","alias":"Side project","active":false,
          "usageStatus":"no_credentials"},
         {"number":5,"email":"solo@example.com","organizationName":"","active":false,"usageStatus":"no_credentials"}]}
        """
        let rows = try await Self.rows(Self.serve(
            Self.config(swapEnabled: true, path: "/fake/cswap"),
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: Self.source(json: { json })))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["accountId"] as? String ?? "", $0) })
        func flag(_ slot: Int) -> Bool? {
            byID["claude-swap:\(slot)"]?["accountLabelIsDefault"] as? Bool
        }
        #expect(byID["claude-swap:1"]?["accountLabel"] as? String == "same@example.com · Account 1")
        #expect(byID["claude-swap:3"]?["accountLabel"] as? String == "Account 3")
        #expect(flag(1) == true)
        #expect(flag(2) == true)
        #expect(flag(3) == true)
        #expect(flag(4) == nil)
        #expect(flag(5) == nil)
    }

    // MARK: statusLine

    @Test
    func `a fresher statusLine capture overrides only the identity matched row`() async throws {
        let capture = Self.capture(email: "WORK@example.com", organization: "example org")
        let rows = try await Self.rows(Self.serve(
            Self.config(swapEnabled: true, path: "/fake/cswap"),
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: Self.source(json: { Self.twoAccounts }, capture: capture)))
        let work = try #require(rows.first { $0["accountId"] as? String == Self.workID })
        let personal = try #require(rows.first { $0["accountId"] as? String == Self.personalID })
        #expect(Self.primaryPercent(work) == 77)
        #expect(work["source"] as? String == "statusline")
        #expect(work["updatedAt"] as? String == "2026-09-21T14:12:20Z")
        // The capture has no weekly window, so claude-swap's stays.
        let secondary = (work["usage"] as? [String: Any])?["secondary"] as? [String: Any]
        #expect(secondary?["usedPercent"] as? Double == 40)
        #expect(Self.primaryPercent(personal) == 10)
        #expect(personal["source"] as? String == "claude-swap")
        #expect(personal["updatedAt"] as? String == "2026-09-21T14:00:00Z")
    }

    @Test
    func `an unmatched, ambiguous or older capture changes nothing`() async throws {
        let config = Self.config(swapEnabled: true, path: "/fake/cswap")
        let baseline = await Self.serve(
            config,
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: Self.source(json: { Self.twoAccounts }))
        // Same email, other organization: a different account. Never matched by position either.
        let otherOrg = Self.capture(email: "work@example.com", organization: "Other Org")
        // Older than slot 2's usageFetchedAt (14:10).
        let older = Self.capture(
            email: "work@example.com",
            organization: "Example Org",
            capturedAt: Date(timeIntervalSince1970: 1_789_999_000))
        for capture in [otherOrg, older] {
            let response = await Self.serve(
                config,
                fetch: Self.ambientFetch(CallLog()),
                claudeSwap: Self.source(json: { Self.twoAccounts }, capture: capture))
            #expect(Self.sameJSON(response.body, baseline.body))
        }

        // Two slots with the same email and organization: ambiguous, so neither is overridden.
        let duplicate = Self.twoAccounts.replacingOccurrences(of: "personal@example.com", with: "work@example.com")
            .replacingOccurrences(of: #""organizationName":"","#, with: #""organizationName":"Example Org","#)
        let match = Self.capture(email: "work@example.com", organization: "Example Org")
        let ambiguous = try await Self.rows(Self.serve(
            config,
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: Self.source(json: { duplicate }, capture: match)))
        #expect(ambiguous.count == 2)
        #expect(ambiguous.allSatisfy { $0["source"] as? String == "claude-swap" })
        #expect(ambiguous.map { Self.primaryPercent($0) } == [30, 10])
    }

    @Test
    func `the capture and its identity come from Claude Code's account config file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeClaudeSwapTests-capture-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("claude", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try Data(#"""
        {"oauthAccount":{"accountUuid":"UUID-A","emailAddress":" work@example.com ",
         "organizationName":"Example Org","organizationUuid":"org-uuid"}}
        """#.utf8).write(to: configDir.appendingPathComponent(".claude.json"))
        let environment = [ClaudeConfigPaths.configDirectoryEnvironmentKey: configDir.path]
        let account = try #require(ClaudeCodeSignedInAccount.load(environment: environment))
        #expect(account == ClaudeCodeSignedInAccount(
            accountUuid: "UUID-A",
            email: "work@example.com",
            organizationName: "Example Org"))

        let limits = ClaudeStatusLineRateLimits(
            profileID: ClaudeStatusLineProfile.identifier(environment: environment),
            accountID: ClaudeStatusLineProfile.accountID(accountUuid: "uuid-a"),
            capturedAt: Self.now.addingTimeInterval(-60),
            fiveHour: ClaudeStatusLineWindow(usedPercent: 12, resetsAt: nil),
            sevenDay: nil)
        try ClaudeStatusLineDropStore.write(limits, applicationSupport: support)
        let loaded = ClaudeSwapStatusLineOverride.loadCapture(
            environment: environment,
            applicationSupport: support,
            now: Self.now)
        #expect(loaded == ClaudeSwapStatusLineCapture(account: account, limits: limits))

        // A capture from another account is not this account's.
        let other = ClaudeStatusLineRateLimits(
            profileID: limits.profileID,
            accountID: ClaudeStatusLineProfile.accountID(accountUuid: "uuid-b"),
            capturedAt: limits.capturedAt,
            fiveHour: limits.fiveHour,
            sevenDay: nil)
        try ClaudeStatusLineDropStore.write(other, applicationSupport: support)
        #expect(ClaudeSwapStatusLineOverride.loadCapture(
            environment: environment,
            applicationSupport: support,
            now: Self.now) == nil)
        #expect(ClaudeCodeSignedInAccount.parse(Data(#"{"oauthAccount":{"accountUuid":"A"}}"#.utf8)) == nil)
    }

    @Test
    func `the statusLine capture is read only with the feed turned on`() throws {
        let cswap = try FakeCSwap()
        let off = try #require(ClaudeSwapServeSource.live(
            config: Self.config(swapEnabled: true, path: cswap.executable.path),
            providerTimeout: nil,
            weeklyWorkDays: nil,
            state: ClaudeSwapServeState(),
            environment: [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/nonexistent-claude-config"]))
        #expect(off.loadCapture(Self.now) == nil)
        #expect(ClaudeSwapStatusLineOverride.isFeedEnabled(
            in: Self.config(swapEnabled: true, path: "x", statusLineFeed: true).providerConfig(for: .claude)))
    }

    // MARK: Adapter errors

    @Test
    func `an unknown schemaVersion or a malformed list keeps the last good rows marked stale`() async throws {
        let cswap = try FakeCSwap()
        let config = Self.config(swapEnabled: true, path: cswap.executable.path)
        let state = ClaudeSwapServeState()
        try cswap.respond(Self.twoAccounts)
        _ = await Self.serve(config, fetch: Self.ambientFetch(CallLog()), claudeSwap: Self.source(cswap, state: state))

        let unknownVersion = Self.twoAccounts.replacingOccurrences(
            of: #""schemaVersion":1"#,
            with: #""schemaVersion":2"#)
        let truncated = #"{"schemaVersion":1,"activeAccountNumber":2,"accounts":"#
        let noAccounts = #"{"schemaVersion":1,"activeAccountNumber":2}"#
        let cases = [
            (unknownVersion, "schema version 2"),
            (truncated, "not a JSON object"),
            (noAccounts, "missing accounts array"),
        ]
        for (json, reason) in cases {
            try cswap.respond(json)
            let calls = CallLog()
            let response = await Self.serve(
                config,
                fetch: Self.ambientFetch(calls),
                claudeSwap: Self.source(cswap, state: state))
            let rows = try Self.rows(response)
            #expect(rows.map { $0["accountId"] as? String } == [Self.workID, Self.personalID])
            #expect(rows.map { $0["active"] as? Bool } == [true, false])
            #expect(rows.allSatisfy { $0["stale"] as? Bool == true })
            #expect(rows.allSatisfy { $0["source"] as? String == "claude-swap-stale" })
            #expect(rows.allSatisfy { Self.errorMessage($0)?.contains(reason) == true })
            #expect(rows.allSatisfy {
                Self.errorMessage($0)?.hasPrefix("Showing the last successful update:") == true
            })
            // The last good Quota and its time stay.
            #expect(rows.map { Self.primaryPercent($0) } == [30, 10])
            #expect(rows.map { $0["updatedAt"] as? String } == ["2026-09-21T14:10:00Z", "2026-09-21T14:00:00Z"])
            // No cache key: serve's last-good merge must not swap them for copies without the error.
            #expect(response.usageCacheKeys == [nil, nil])
            #expect(await calls.calls.isEmpty)
        }
        #expect(cswap.invocations == Array(repeating: ["--list", "--json"], count: 4).flatMap(\.self))
    }

    @Test
    func `a failed first read is one Claude error row`() async throws {
        let rows = try await Self.rows(Self.serve(
            Self.config(swapEnabled: true, path: "/fake/cswap"),
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: Self.source(json: { #"{"schemaVersion":7}"# })))
        #expect(rows.count == 1)
        #expect(rows.first?["accountId"] == nil)
        #expect(rows.first?["provider"] as? String == "claude")
        #expect(rows.first.flatMap(Self.errorMessage)?.contains("schema version 7") == true)
    }

    @Test
    func `plain usage serves the active slot's last good row with the adapter error`() async throws {
        let state = ClaudeSwapServeState()
        let good = Self.source(json: { Self.twoAccounts }, state: state)
        _ = await good.fetch()
        let failing = Self.source(json: { "not json" }, state: state)
        let output = await CodexBarCLI.serveClaudeSwapOrFetch(provider: .claude, claudeSwap: failing) {
            Issue.record("no ambient fetch while claude-swap is enabled")
            return UsageCommandOutput()
        }
        let row = try #require(output.payload.first)
        #expect(output.payload.count == 1)
        #expect(row.source == "claude-swap-stale")
        #expect(row.usage?.primary?.usedPercent == 30)
        #expect(row.error?.message.contains("not a JSON object") == true)
        #expect(row.cacheAccountKey == nil)
    }

    @Test
    func `a timed out list read gets one error row per last good account`() async throws {
        let state = ClaudeSwapServeState()
        _ = await Self.source(json: { Self.twoAccounts }, state: state).fetch()
        let hanging = ClaudeSwapServeSource(
            executablePath: "/fake/cswap",
            state: state,
            readList: { _, _ in
                try await Task.sleep(for: .seconds(3))
                throw CancellationError()
            },
            now: { Self.now })
        let rows = try await Self.rows(Self.serve(
            Self.config(swapEnabled: true, path: "/fake/cswap"),
            fetch: Self.ambientFetch(CallLog()),
            claudeSwap: hanging,
            deadline: ContinuousClock().now.advanced(by: .milliseconds(200))))
        #expect(rows.map { $0["accountId"] as? String } == [Self.workID, Self.personalID])
        #expect(rows.allSatisfy { $0["error"] != nil })
    }

    // MARK: Disabled or missing

    @Test
    func `with claude-swap disabled or missing the Claude output is today's`() async throws {
        let cswap = try FakeCSwap()
        try cswap.respond(Self.twoAccounts)
        let todayCalls = CallLog()
        let today = await Self.serve(Self.config(swapEnabled: nil, path: nil), fetch: Self.ambientFetch(todayCalls))
        #expect(await todayCalls.calls == ["claude:default"])
        let todayRows = try Self.rows(today)
        #expect(todayRows.count == 1)
        #expect(todayRows.first?["accountId"] == nil)

        let variants = [
            Self.config(swapEnabled: false, path: cswap.executable.path),
            Self.config(swapEnabled: true, path: cswap.directory.appendingPathComponent("missing").path),
            Self.config(swapEnabled: true, path: nil),
        ]
        for config in variants {
            #expect(ClaudeSwapServeSource.live(config: config, providerTimeout: nil, weeklyWorkDays: nil) == nil)
            let calls = CallLog()
            let response = await Self.serve(config, fetch: Self.ambientFetch(calls))
            #expect(Self.sameJSON(response.body, today.body))
            #expect(response.usageCacheKeys == today.usageCacheKeys)
            #expect(await calls.calls == ["claude:default"])
        }
        #expect(cswap.invocations.isEmpty)

        // Plain /usage: no source, upstream's fetch.
        let calls = CallLog()
        let ambient = Self.ambientFetch(calls)
        let plain = await CodexBarCLI.serveClaudeSwapOrFetch(provider: .claude, claudeSwap: nil) {
            await ambient(.claude, nil)
        }
        #expect(plain.payload.map(\.source) == ["oauth"])
        #expect(await calls.calls == ["claude:default"])
    }

    @Test
    func `a bare executable name resolves on PATH`() throws {
        let cswap = try FakeCSwap()
        #expect(ClaudeSwapServeSource.resolvedExecutable(
            "cswap",
            environment: ["PATH": "/nonexistent:\(cswap.directory.path)"]) == cswap.executable.path)
        #expect(ClaudeSwapServeSource.resolvedExecutable("cswap", environment: ["PATH": "/nonexistent"]) == nil)
        #expect(ClaudeSwapServeSource.resolvedExecutable("  ", environment: [:]) == nil)
    }
}
