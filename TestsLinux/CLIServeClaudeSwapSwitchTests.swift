import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// serve's `POST /accounts/switch` (#171). A fake `cswap` on disk records every argument array it gets and answers
/// `--list --json` from a file and `--switch-to <slot> --json` as told (delay, fail, wrong schema, wrong slot). No test
/// runs a real `cswap` or `claude`, reads a credential, or touches the Keychain.
struct CLIServeClaudeSwapSwitchTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let actionToken = "fake-action-token-for-switch-tests"

    /// Four slots with `active` on `activeSlot`: 1 ok, 2 ok, 3 with an expired token, 4 disabled (claude-swap keeps
    /// it out of its own rotation, but it stays an explicit switch target).
    private static func list(activeSlot: Int, unavailable: Set<Int> = []) -> String {
        func slot(_ number: Int, _ status: String, disabled: Bool = false) -> String {
            if unavailable.contains(number) {
                return """
                {"number":\(number),"email":"slot\(number)@example.com","organizationName":"",
                 "active":\(number == activeSlot),"usageStatus":"unavailable","disabled":\(disabled)}
                """
            }
            return """
            {"number":\(number),"email":"slot\(number)@example.com","organizationName":"",
             "active":\(number == activeSlot),"usageStatus":"\(status)","disabled":\(disabled),
             "usage":{"fiveHour":{"pct":\(number * 10),"resetsAt":"2026-09-21T18:00:00Z"}},
             "usageFetchedAt":"2026-09-21T14:00:00Z"}
            """
        }
        return """
        {"schemaVersion":1,"activeAccountNumber":\(activeSlot),"accounts":[
        \(slot(1, "ok")),\(slot(2, "ok")),\(slot(3, "token_expired")),\(slot(4, "ok", disabled: true))]}
        """
    }

    // MARK: Fixtures

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool

        init(_ value: Bool) {
            self.stored = value
        }

        var value: Bool {
            get { self.lock.withLock { self.stored } }
            set { self.lock.withLock { self.stored = newValue } }
        }
    }

    /// The fake `cswap`. `<path>.args` gets one line per run (its arguments), `<path>.log` "start N" / "end N"
    /// around each switch. A switch copies `<path>.list.<slot>` (if any) over the list it answers, the way a real
    /// switch changes which slot is active. With `<path>.gate`, a switch waits for `<path>.release` after "start N";
    /// with `<path>.listdelay`, list reads after the first switch take that many seconds.
    private struct FakeCSwap {
        let executable: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CLIServeClaudeSwapSwitchTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.executable = directory.appendingPathComponent("cswap")
            try FakeExecutable.install(#"""
            #!/bin/sh
            base="${0%.sh}"
            printf '%s\n' "$*" >> "$base.args"
            if [ "$#" -eq 2 ] && [ "$1" = "--list" ] && [ "$2" = "--json" ]; then
              if [ -f "$base.log" ] && [ -f "$base.listdelay" ]; then sleep "$(cat "$base.listdelay")"; fi
              exec /bin/cat "$base.list"
            fi
            if [ "$#" -eq 3 ] && [ "$1" = "--switch-to" ] && [ "$3" = "--json" ]; then
              slot="$2"
              echo "start $slot" >> "$base.log"
              if [ -f "$base.gate" ]; then
                while [ ! -f "$base.release" ]; do sleep 0.05; done
              fi
              if [ -f "$base.delay" ]; then sleep "$(cat "$base.delay")"; fi
              mode=ok
              if [ -f "$base.mode" ]; then mode="$(cat "$base.mode")"; fi
              echo "end $slot" >> "$base.log"
              case "$mode" in
                ok)
                  if [ -f "$base.list.$slot" ]; then /bin/cp "$base.list.$slot" "$base.list"; fi
                  printf '{"schemaVersion":1,"switched":true,"from":{"number":2},'
                  printf '"to":{"number":%s},"reason":"switched"}\n' "$slot"
                  ;;
                fail)
                  echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"store locked"}}'
                  exit 1
                  ;;
                schema)
                  printf '{"schemaVersion":2,"switched":true,"to":{"number":%s},"reason":"switched"}\n' "$slot"
                  ;;
                wrongslot)
                  if [ -f "$base.list.$slot" ]; then /bin/cp "$base.list.$slot" "$base.list"; fi
                  echo '{"schemaVersion":1,"switched":true,"from":{"number":2},"to":{"number":3},"reason":"switched"}'
                  ;;
              esac
              exit 0
            fi
            exit 64
            """#, at: self.executable)
            try self.write(Self.listText(activeSlot: 2), "list")
            for slot in 1...4 {
                try self.write(Self.listText(activeSlot: slot), "list.\(slot)")
            }
        }

        private static func listText(activeSlot: Int) -> String {
            CLIServeClaudeSwapSwitchTests.list(activeSlot: activeSlot)
        }

        func write(_ text: String, _ suffix: String) throws {
            try Data(text.utf8).write(to: self.executable.appendingPathExtension(suffix))
        }

        private func lines(_ suffix: String) -> [String] {
            let text = (try? String(contentsOf: self.executable.appendingPathExtension(suffix), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }

        /// Every argument array the fake ran with, one string each.
        var invocations: [String] {
            self.lines("args")
        }

        var switchInvocations: [String] {
            self.invocations.filter { $0.hasPrefix("--switch-to") }
        }

        var switchLog: [String] {
            self.lines("log")
        }
    }

    private static func source(_ cswap: FakeCSwap, state: ClaudeSwapServeState = ClaudeSwapServeState())
        -> ClaudeSwapServeSource
    {
        ClaudeSwapServeSource(
            executablePath: cswap.executable.path,
            state: state,
            loadClaudeCode: { _ in nil },
            now: { Self.now })
    }

    private static func runtime(cache: CLIServeResponseCache = CLIServeResponseCache()) throws -> ServeRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIServeClaudeSwapSwitchTests-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try store.save(CodexBarConfig(providers: [ProviderConfig(id: UsageProvider.claude.instanceID, enabled: true)]))
        return ServeRuntime(
            configStore: store,
            cache: cache,
            providerOperations: CLIServeOperationCoordinator(),
            costOperations: CLIServeOperationCoordinator(),
            refreshInterval: 60,
            requestTimeout: 30,
            healthVersion: nil,
            dashboardAuth: CLIServeDashboardAuth(bearer: nil),
            bindHost: "127.0.0.1")
    }

    private static func request(
        accountId: String,
        provider: String = "claude",
        method: String = "POST",
        token: String? = actionToken) throws -> CLILocalHTTPRequest
    {
        let json = try JSONSerialization.data(withJSONObject: ["provider": provider, "accountId": accountId])
        let body = try #require(String(bytes: json, encoding: .utf8))
        var head = "\(method) /accounts/switch HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        if let token { head += "X-UsageBar-Action-Token: \(token)\r\n" }
        return try CLILocalHTTPRequest.parse(Data((head + "\r\n" + body).utf8)).get()
    }

    /// The request through the switch route, with serve holding the action token and `source` as claude-swap. The
    /// route answers once the command exits; with `drain`, this also waits for the refresh queued after it.
    private static func send(
        _ request: CLILocalHTTPRequest,
        runtime: ServeRuntime,
        source: ClaudeSwapServeSource?,
        queue: ClaudeSwapSwitchQueue = ClaudeSwapSwitchQueue(),
        generation: ClaudeSwapSwitchGeneration = ClaudeSwapSwitchGeneration(),
        drain: Bool = true) async -> CLILocalHTTPResponse
    {
        let response = await CLIServeActionGuard.$override.withValue(CLIServeActionGuard(token: self.actionToken)) {
            await CodexBarCLI.serveClaudeSwapSwitchRoute(
                request,
                runtime: runtime,
                resolveSource: { _ in source },
                queue: queue,
                generation: generation)
        }
        if drain { await queue.drain() }
        return response
    }

    /// `GET /usage?accounts=all&provider=claude` through serve's route, with `source` as claude-swap.
    private static func accountRows(
        runtime: ServeRuntime,
        source: ClaudeSwapServeSource,
        generation: ClaudeSwapSwitchGeneration) async throws -> [[String: Any]]
    {
        let request = try CLILocalHTTPRequest.parse(Data(
            "GET /usage?accounts=all&provider=claude HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)).get()
        let response = await CodexBarCLI.serveProviderAccountUsageRoute(
            request,
            runtime: runtime,
            fetch: { _, _ in UsageCommandOutput() },
            claudeSwap: source,
            switchGeneration: generation)
        #expect(response.status == .ok)
        return try #require(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
    }

    private static func activeIDs(_ rows: [[String: Any]]) -> [String] {
        rows.filter { $0["active"] as? Bool == true }.compactMap { $0["accountId"] as? String }.sorted()
    }

    private static func object(_ response: CLILocalHTTPResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private static func rows(_ source: ClaudeSwapServeSource) async -> [String: ProviderAccountRowFields] {
        let rows = await source.state.lastGoodRows(for: source.executablePath, now: Self.now, maxAge: 3600)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.account.fields.accountID, $0.account.fields) })
    }

    // MARK: Exact command

    @Test
    func `switch runs exactly cswap --switch-to slot --json and the refreshed list sets active`() async throws {
        let cswap = try FakeCSwap()
        let source = Self.source(cswap)
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: Self.runtime(),
            source: source)

        #expect(response.status == .ok)
        #expect(response.extraHeaders.contains { $0 == ("Cache-Control", "no-store") })
        let body = try Self.object(response)
        #expect(body["accountId"] as? String == "claude-swap:1")
        #expect(body["switched"] as? Bool == true)
        #expect(Set(body.keys) == ["provider", "accountId", "switched"])
        // Validate (list), switch, refresh (list): nothing else, and the slot exactly as the list issued it.
        #expect(cswap.invocations == ["--list --json", "--switch-to 1 --json", "--list --json"])
        #expect(response.body.range(of: Data("example.com".utf8)) == nil)
        // The active flag comes from the refreshed list.
        let rows = await Self.rows(source)
        #expect(rows["claude-swap:1"]?.active == true)
        #expect(rows["claude-swap:2"]?.active == false)
    }

    // MARK: Refused slots never exec

    @Test
    func `slots outside the current list or not switchable never run a switch`() async throws {
        let cswap = try FakeCSwap()
        let source = Self.source(cswap)
        let runtime = try Self.runtime()
        let cases: [(String, CLIHTTPStatus)] = [
            ("claude-swap:9", .notFound), // not in the list
            ("claude-swap:2", .conflict), // already active
            ("claude-swap:3", .conflict), // expired token
            ("claude-swap:01", .notFound), // not how serve writes a slot
            ("claude-swap:-1", .notFound),
            ("claude-swap:1 --purge", .notFound),
            ("claude-swap:", .notFound),
            ("token:1", .notFound),
        ]
        for (accountID, status) in cases {
            let response = try await Self.send(Self.request(accountId: accountID), runtime: runtime, source: source)
            #expect(response.status == status, "\(accountID)")
        }
        let otherProvider = try await Self.send(
            Self.request(accountId: "claude-swap:1", provider: "codex"),
            runtime: runtime,
            source: source)
        #expect(otherProvider.status == .badRequest)
        #expect(cswap.switchInvocations.isEmpty)
        #expect(cswap.switchLog.isEmpty)
    }

    @Test
    func `a list without switching support or a failed list read refuses before any switch`() async throws {
        let cswap = try FakeCSwap()
        try cswap.write(
            Self.list(activeSlot: 2).replacingOccurrences(
                of: "\"activeAccountNumber\":2,",
                with: "\"activeAccountNumber\":2,\"supportsAccountSwitching\":false,"),
            "list")
        let runtime = try Self.runtime()
        let unsupported = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: runtime,
            source: Self.source(cswap))
        #expect(unsupported.status == .conflict)

        try cswap.write(#"{"schemaVersion":7,"accounts":[]}"#, "list")
        let unreadable = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: runtime,
            source: Self.source(cswap))
        #expect(unreadable.status == .badGateway)
        #expect(cswap.switchInvocations.isEmpty)
    }

    @Test
    func `disabled slots stay explicit switch targets`() async throws {
        let cswap = try FakeCSwap()
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:4"),
            runtime: Self.runtime(),
            source: Self.source(cswap))
        #expect(response.status == .ok)
        #expect(cswap.switchInvocations == ["--switch-to 4 --json"])
    }

    @Test
    func `the route needs the action token and claude-swap and POST`() async throws {
        let cswap = try FakeCSwap()
        let runtime = try Self.runtime()
        let noToken = try await Self.send(
            Self.request(accountId: "claude-swap:1", token: nil),
            runtime: runtime,
            source: Self.source(cswap))
        #expect(noToken.status == .forbidden)
        let wrongToken = try await Self.send(
            Self.request(accountId: "claude-swap:1", token: "nope"),
            runtime: runtime,
            source: Self.source(cswap))
        #expect(wrongToken.status == .forbidden)
        let disabled = try await Self.send(Self.request(accountId: "claude-swap:1"), runtime: runtime, source: nil)
        #expect(disabled.status == .conflict)
        let get = try await CodexBarCLI.forkServeResponse(
            Self.request(accountId: "claude-swap:1", method: "GET"),
            runtime: runtime)
        #expect(get?.status == .methodNotAllowed)
        // No token on serve: the live route refuses before it reads the config or claude-swap.
        let unarmed = try await CLIServeActionGuard.$override.withValue(CLIServeActionGuard(token: nil)) {
            try await CodexBarCLI.forkServeResponse(Self.request(accountId: "claude-swap:1"), runtime: runtime)
        }
        #expect(unarmed?.status == .forbidden)
        #expect(cswap.invocations.isEmpty)
    }

    // MARK: Bad results

    @Test(arguments: ["fail", "schema", "wrongslot"])
    func `a failed or malformed switch result is an error and the last good rows stay`(mode: String) async throws {
        let cswap = try FakeCSwap()
        try cswap.write(mode, "mode")
        let source = Self.source(cswap)
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: Self.runtime(),
            source: source)

        #expect(response.status == .badGateway)
        let message = try #require(Self.object(response)["error"] as? String)
        #expect(message.hasPrefix("Account switch failed: "))
        if mode == "wrongslot" { #expect(message.contains("slot 3")) }
        if mode == "schema" { #expect(message.contains("schema version 2")) }
        // The rows come from list reads only, never the switch output: every slot is still there, unstale, with the
        // active flag the refreshed list gives (it moved for wrongslot, where the fake still switched).
        let rows = await Self.rows(source)
        #expect(rows.count == 4)
        #expect(rows.values.allSatisfy { !$0.stale })
        #expect(rows["claude-swap:1"]?.active == (mode == "wrongslot"))
        #expect(cswap.invocations.last == "--list --json")
    }

    @Test
    func `a failed refresh after the switch keeps the last good rows marked stale`() async throws {
        let cswap = try FakeCSwap()
        // After the switch the list turns unreadable.
        try cswap.write("not json", "list.1")
        let source = Self.source(cswap)
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: Self.runtime(),
            source: source)

        #expect(response.status == .ok)
        let stale = await source.fetch()
        #expect(stale.rows.count == 4)
        let allStale = stale.rows.allSatisfy(\.account.fields.stale)
        #expect(allStale)
        #expect(stale.rows.allSatisfy { !$0.account.fields.canSwitch })
    }

    // MARK: Serialization

    @Test
    func `two concurrent switches run one after the other`() async throws {
        let cswap = try FakeCSwap()
        try cswap.write("", "gate")
        let source = Self.source(cswap)
        let runtime = try Self.runtime()
        let queue = ClaudeSwapSwitchQueue()
        let firstRequest = try Self.request(accountId: "claude-swap:1")
        let secondRequest = try Self.request(accountId: "claude-swap:4")
        let first = Task { await Self.send(firstRequest, runtime: runtime, source: source, queue: queue) }
        let second = Task { await Self.send(secondRequest, runtime: runtime, source: source, queue: queue) }
        // One switch is held at the gate; the other must not start until it is released.
        for _ in 0..<250 where cswap.switchLog.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(cswap.switchLog.count == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(cswap.switchLog.count == 1)
        try cswap.write("", "release")
        let responses = await [first.value, second.value]

        #expect(responses.allSatisfy { $0.status == .ok })
        let log = cswap.switchLog
        #expect(log.count == 4)
        // Strictly start, end, start, end: never two switches at once.
        #expect(log.enumerated().allSatisfy { index, line in
            line.hasPrefix(index.isMultiple(of: 2) ? "start " : "end ")
        })
        #expect(log[0].dropFirst(6) == log[1].dropFirst(4))
        #expect(log[2].dropFirst(6) == log[3].dropFirst(4))
        // Each switch's validation read comes after the previous transaction's refresh.
        #expect(cswap.invocations.count == 6)
    }

    @Test
    func `a started switch is not cancelled when its caller goes away`() async throws {
        let cswap = try FakeCSwap()
        try cswap.write("0.5", "delay")
        let source = Self.source(cswap)
        let runtime = try Self.runtime()
        let queue = ClaudeSwapSwitchQueue()
        let request = try Self.request(accountId: "claude-swap:1")
        let caller = Task {
            await Self.send(request, runtime: runtime, source: source, queue: queue)
        }
        // Wait for the switch to start, then drop the caller.
        for _ in 0..<250 where cswap.switchLog.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!cswap.switchLog.isEmpty)
        caller.cancel()
        // The next transaction waits for the cancelled one, which still ran to its end.
        let next = try await Self.send(
            Self.request(accountId: "claude-swap:4"),
            runtime: runtime,
            source: source,
            queue: queue)
        #expect(next.status == .ok)
        #expect(cswap.switchLog == ["start 1", "end 1", "start 4", "end 4"])
        let rows = await Self.rows(source)
        #expect(rows["claude-swap:4"]?.active == true)
    }

    // MARK: Response cache

    @Test
    func `a switch drops serve's cached Claude responses and keeps the rest`() async throws {
        let cache = CLIServeResponseCache()
        let runtime = try Self.runtime(cache: cache)
        let keys = [
            "usage:default:abc",
            "usage:claude:abc",
            "usage:claude,codex:accounts:abc",
            "dashboard-full-used:default:abc",
            "usage:codex:abc",
            "cost:claude:30d:abc",
        ]
        let policy = CLIServeResponseCache.CachePolicy(ttl: 600, staleTTL: 600)
        for key in keys {
            _ = await cache.completeFetch(
                CLILocalHTTPResponse(status: .ok, body: Data("[]".utf8)),
                for: key,
                policy: policy,
                now: Date(),
                shouldCache: true)
        }
        let cswap = try FakeCSwap()
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: runtime,
            source: Self.source(cswap))
        #expect(response.status == .ok)
        var kept: [String] = []
        for key in keys where await cache.cachedResponse(for: key, now: Date()) != nil {
            kept.append(key)
        }
        #expect(kept == ["usage:codex:abc", "cost:claude:30d:abc"])
    }

    // MARK: Answer before refresh

    @Test(arguments: ["ok", "fail"])
    func `the answer goes out when the command exits, before the refresh`(mode: String) async throws {
        let cswap = try FakeCSwap()
        try cswap.write(mode, "mode")
        try cswap.write("1.5", "listdelay")
        let source = Self.source(cswap)
        let queue = ClaudeSwapSwitchQueue()
        let started = ContinuousClock.now
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: Self.runtime(),
            source: source,
            queue: queue,
            drain: false)
        #expect(ContinuousClock.now - started < .milliseconds(1200))
        #expect(response.status == (mode == "ok" ? .ok : .badGateway))
        // The refresh hasn't landed: the rows still have the old active slot.
        #expect(await Self.rows(source)["claude-swap:2"]?.active == true)
        await queue.drain()
        #expect(cswap.invocations.last == "--list --json")
        #expect(await Self.rows(source)["claude-swap:1"]?.active == (mode == "ok"))
    }

    @Test
    func `the refresh is dropped when claude-swap's configuration changed meanwhile`() async throws {
        let cswap = try FakeCSwap()
        let source = Self.source(cswap)
        let enabled = Flag(true)
        let queue = ClaudeSwapSwitchQueue()
        let result = await CodexBarCLI.runClaudeSwapSwitch(
            ClaudeSwapSwitchJob(
                slot: 1,
                currentSource: {
                    enabled.value ? .success(source) : .failure(.notEnabled)
                },
                switcher: { path, slot in
                    // claude-swap is turned off while its switch runs.
                    defer { enabled.value = false }
                    return try await ClaudeSwapAccountReader.switchAccount(executablePath: path, accountNumber: slot)
                },
                generation: ClaudeSwapSwitchGeneration(),
                invalidate: {}),
            queue: queue)
        await queue.drain()
        #expect((try? result.get())?.switched == true)
        // Validation read and switch only: no refresh against a configuration that is gone.
        #expect(cswap.invocations == ["--list --json", "--switch-to 1 --json"])
    }

    // MARK: Accounts after a switch

    @Test
    func `after a switch only the new account is active even when the old one errors`() async throws {
        let cswap = try FakeCSwap()
        try cswap.write(Self.list(activeSlot: 1), "list")
        // After switching to 2, slot 1 reports unavailable with no usage.
        try cswap.write(Self.list(activeSlot: 2, unavailable: [1]), "list.2")
        let source = Self.source(cswap)
        let runtime = try Self.runtime()
        let generation = ClaudeSwapSwitchGeneration()

        let before = try await Self.accountRows(runtime: runtime, source: source, generation: generation)
        #expect(Self.activeIDs(before) == ["claude-swap:1"])
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:2"),
            runtime: runtime,
            source: source,
            generation: generation)
        #expect(response.status == .ok)
        let after = try await Self.accountRows(runtime: runtime, source: source, generation: generation)
        let slot1 = try #require(after.first { $0["accountId"] as? String == "claude-swap:1" })
        #expect(slot1["error"] != nil)
        #expect(Self.activeIDs(after) == ["claude-swap:2"])
    }

    @Test
    func `a fetch from before the switch that commits late never answers after it`() async throws {
        let cswap = try FakeCSwap()
        let source = Self.source(cswap)
        let runtime = try Self.runtime()
        let generation = ClaudeSwapSwitchGeneration()
        let token = try CodexBarCLI.loadServeConfigSnapshot(configStore: runtime.configStore).cacheToken
        let oldKey = "usage:claude:accounts:\(generation.fingerprint(token, providers: [.claude]))"

        let before = try await Self.accountRows(runtime: runtime, source: source, generation: generation)
        #expect(Self.activeIDs(before) == ["claude-swap:2"])
        let response = try await Self.send(
            Self.request(accountId: "claude-swap:1"),
            runtime: runtime,
            source: source,
            generation: generation)
        #expect(response.status == .ok)
        // A fetch that started before the switch lands now, with the old rows.
        let stale = try JSONSerialization.data(withJSONObject: before)
        _ = await runtime.cache.completeFetch(
            CLILocalHTTPResponse(status: .ok, body: stale),
            for: oldKey,
            policy: CLIServeResponseCache.CachePolicy(ttl: 600, staleTTL: 600),
            now: Date(),
            shouldCache: true)
        #expect(await runtime.cache.cachedResponse(for: oldKey, now: Date()) != nil)
        let after = try await Self.accountRows(runtime: runtime, source: source, generation: generation)
        #expect(Self.activeIDs(after) == ["claude-swap:1"])
    }

    @Test
    func `the switch generation keys only requests that include Claude`() {
        let generation = ClaudeSwapSwitchGeneration()
        let before = generation.fingerprint("abc", providers: [.codex, .claude])
        generation.advance()
        #expect(generation.fingerprint("abc", providers: [.codex, .claude]) != before)
        #expect(generation.fingerprint("abc", providers: [.codex]) == "abc")
        #expect(generation.fingerprint("abc", providers: nil) == "abc")
    }

    // MARK: Rows

    @Test
    func `only inactive slots claude-swap can activate carry canSwitch`() async throws {
        let cswap = try FakeCSwap()
        let source = Self.source(cswap)
        let result = await source.fetch()
        let byID = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.account.fields.accountID, $0) })
        #expect(byID["claude-swap:1"]?.account.fields.canSwitch == true)
        #expect(byID["claude-swap:2"]?.account.fields.canSwitch == false) // active
        #expect(byID["claude-swap:3"]?.account.fields.canSwitch == false) // expired
        #expect(byID["claude-swap:4"]?.account.fields.canSwitch == true) // disabled, still explicit
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.rows.map {
            ProviderAccountRowPayload(row: $0.payload, account: $0.account.fields)
        })) as? [[String: Any]]
        let flags = Dictionary(uniqueKeysWithValues: (encoded ?? []).compactMap { row -> (String, Bool)? in
            guard let id = row["accountId"] as? String else { return nil }
            return (id, row["canSwitch"] as? Bool ?? false)
        })
        #expect(flags == ["claude-swap:1": true, "claude-swap:2": false, "claude-swap:3": false, "claude-swap:4": true])
    }

    @Test
    func `slot ids parse only as serve writes them`() {
        #expect(CodexBarCLI.claudeSwapSlot(fromAccountID: "claude-swap:12") == 12)
        for id in ["claude-swap:0", "claude-swap:+1", "claude-swap:1.0", "claude-swap: 1", "claude-swap:1x", "x:1"] {
            #expect(CodexBarCLI.claudeSwapSlot(fromAccountID: id) == nil, "\(id)")
        }
    }
}
