import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexRPCProcessExitTests {
    // MARK: - Error description

    @Test
    func `process exit description includes status and stderr line`() {
        let error = RPCWireError.processExited(termination: .exited(1), stderr: "Error: not logged in")

        #expect(error.localizedDescription == "codex app-server exited (status 1): Error: not logged in")
        #expect(!error.localizedDescription.lowercased().contains("returned invalid data"))
    }

    @Test
    func `process exit description keeps signal when stderr is empty`() {
        #expect(
            RPCWireError.processExited(termination: .signaled(9), stderr: nil).localizedDescription
                == "codex app-server exited (signal 9)")
        #expect(
            RPCWireError.processExited(termination: .exited(0), stderr: "").localizedDescription
                == "codex app-server exited (status 0)")
    }

    @Test
    func `still running child reports closed stdout with stderr`() {
        #expect(
            RPCWireError.processExited(termination: nil, stderr: "panic").localizedDescription
                == "codex app-server closed stdout: panic")
        #expect(
            RPCWireError.processExited(termination: nil, stderr: nil).localizedDescription
                == "codex app-server closed stdout")
    }

    // MARK: - Stderr tail

    @Test
    func `last meaningful line strips ANSI codes and trailing blanks`() {
        let text = "starting\n\u{1B}[31mError:\u{1B}[0m token expired\r\n\n   \n"

        #expect(RPCStderrTail.lastMeaningfulLine(in: text) == "Error: token expired")
    }

    @Test
    func `last meaningful line skips runtime trailer lines`() {
        let rust = "thread 'main' panicked at src/main.rs:1:1:\nboom\n"
            + "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n"
        let node = "Error: spawn failed\n    at foo (/tmp/x.js:1:2)\n\nNode.js v22.1.0\n"

        #expect(RPCStderrTail.lastMeaningfulLine(in: rust) == "boom")
        #expect(RPCStderrTail.lastMeaningfulLine(in: node) == "Error: spawn failed")
        #expect(RPCStderrTail.lastMeaningfulLine(in: "Node.js v22.1.0\n") == "Node.js v22.1.0")
    }

    @Test
    func `last meaningful line truncates long lines`() {
        let line = String(repeating: "x", count: 50)

        #expect(RPCStderrTail.lastMeaningfulLine(in: line, maxCharacters: 10) == "xxxxxxxxx…")
        #expect(RPCStderrTail.lastMeaningfulLine(in: " \n\t\n") == nil)
    }

    @Test
    func `stderr tail keeps only the newest bytes`() {
        let tail = RPCStderrTail(maxBytes: 8)
        tail.append(Data("first line\n".utf8))
        tail.append(Data("last\n".utf8))

        #expect(tail.text == "ne\nlast\n")
        #expect(tail.lastMeaningfulLine() == "last")
        #expect(!tail.isClosed)
        tail.markClosed()
        #expect(tail.isClosed)
    }

    // MARK: - Live child

    @Test
    func `codex RPC explains an app-server that exits before replying`() async throws {
        let error = try await self.fetchError(script: """
        #!/bin/sh
        IFS= read -r line
        printf 'booting\\n' >&2
        printf '\\033[31mError:\\033[0m failed to load auth.json\\n' >&2
        exit 3
        """)

        guard let error, case let .processExited(termination, stderr) = error else {
            Issue.record("Expected processExited, got \(String(describing: error))")
            return
        }
        #expect(termination == .exited(3))
        #expect(stderr == "Error: failed to load auth.json")
        #expect(error.localizedDescription == "codex app-server exited (status 3): Error: failed to load auth.json")
    }

    @Test
    func `codex RPC reports the signal when the app-server is killed silently`() async throws {
        let error = try await self.fetchError(script: """
        #!/bin/sh
        IFS= read -r line
        kill -9 $$
        """)

        guard let error, case let .processExited(termination, stderr) = error else {
            Issue.record("Expected processExited, got \(String(describing: error))")
            return
        }
        #expect(termination == .signaled(9))
        #expect(stderr == nil)
        #expect(error.localizedDescription == "codex app-server exited (signal 9)")
    }

    private func fetchError(script: String) async throws -> RPCWireError? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rpc-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let fetcher = UsageFetcher(
            environment: ["CODEX_CLI_PATH": scriptURL.path, "CODEX_HOME": scriptURL.path + ".home"],
            initializeTimeoutSeconds: 5,
            requestTimeoutSeconds: 2,
            codexExecutableResolver: { _, _ in
                CodexExecutableResolution(executable: scriptURL.path, loginPATH: [])
            })

        return await #expect(throws: RPCWireError.self) {
            _ = try await fetcher.loadLatestCLIAccountSnapshot()
        }
    }
}
