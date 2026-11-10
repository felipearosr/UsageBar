import CodexBarCore
import Foundation

// MARK: - Add a Claude account through claude-swap (#172)

/// Where claude-swap's `cswap` lives on this Machine. Only absolute paths count: a relative `PATH` entry or a relative
/// override is skipped, as `ClaudeSwapServeSource.resolvedExecutable` does (#170), so the working directory can never
/// pick the binary. The candidates, in order:
///
/// 1. the absolute entries of `PATH`;
/// 2. uv's tool bin directory: `UV_TOOL_BIN_DIR`, then `XDG_BIN_HOME`, then `~/.local/bin` (also pipx's default
///    `PIPX_BIN_DIR`);
/// 3. the tool's own environment: uv's `UV_TOOL_DIR` (default `$XDG_DATA_HOME/uv/tools`, else
///    `~/.local/share/uv/tools`) and pipx's `PIPX_HOME` (default `~/.local/share/pipx`), each under
///    `claude-swap/bin/cswap`.
///
/// Nothing is executed and nothing is read beyond file metadata.
enum ClaudeSwapExecutableDetector {
    static let executableName = "cswap"
    static let packageName = "claude-swap"

    static func candidates(environment: [String: String], home: String) -> [String] {
        var directories: [String] = []
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let localBin = "\(home)/.local/bin"
        directories += [
            environment["UV_TOOL_BIN_DIR"],
            environment["XDG_BIN_HOME"],
            localBin,
            environment["PIPX_BIN_DIR"],
        ].compactMap(\.self)
        let dataHome = Self.absolute(environment["XDG_DATA_HOME"]) ?? "\(home)/.local/share"
        let uvTools = Self.absolute(environment["UV_TOOL_DIR"]) ?? "\(dataHome)/uv/tools"
        let pipxHome = Self.absolute(environment["PIPX_HOME"]) ?? "\(dataHome)/pipx"
        directories += ["\(uvTools)/\(Self.packageName)/bin", "\(pipxHome)/venvs/\(Self.packageName)/bin"]

        var seen = Set<String>()
        return directories.compactMap { directory -> String? in
            guard let directory = Self.absolute(directory) else { return nil }
            let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            let candidate = "\(trimmed)/\(Self.executableName)"
            return seen.insert(candidate).inserted ? candidate : nil
        }
    }

    /// The first candidate that is an executable file, or nil ("not installed").
    static func detect(
        environment: [String: String],
        home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String?
    {
        self.candidates(environment: environment, home: home).first(where: isExecutable)
    }

    /// The configured path when it resolves to an executable (#170's rules), else a detected one.
    static func configuredOrDetected(
        configured: String?,
        environment: [String: String],
        home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String?
    {
        if let configured = SettingsValue.cleaned(configured),
           let resolved = ClaudeSwapServeSource.resolvedExecutable(configured, environment: environment),
           isExecutable(resolved)
        {
            return resolved
        }
        return self.detect(environment: environment, home: home, isExecutable: isExecutable)
    }

    private static func absolute(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
        return path
    }
}

/// Claude Code's CLI for the add flow's sign-in step: `CLAUDE_CLI_PATH` when absolute, the absolute `PATH` entries,
/// then Anthropic's installer locations. No login shell is started to find it.
enum ClaudeCodeExecutableDetector {
    static func detect(
        environment: [String: String],
        home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String?
    {
        if let override = environment["CLAUDE_CLI_PATH"], override.hasPrefix("/"), isExecutable(override) {
            return override
        }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { "\($0.hasSuffix("/") ? String($0.dropLast()) : $0)/claude" }
        let wellKnown = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "/usr/local/bin/claude",
        ]
        return (pathEntries + wellKnown).first(where: isExecutable)
    }
}

/// `codexbar claude add-account`, the helper the GNOME extension opens in a terminal for **Add account…** on Claude.
///
/// It runs exactly three fixed argument vectors, in order, with the terminal's stdin and stdout, and no shell:
///
/// 1. `cswap add`: claude-swap saves the login Claude Code holds now;
/// 2. `claude auth login`: the user signs in to the other account in the browser;
/// 3. `cswap add`: claude-swap saves that one too.
///
/// It stops at the first step that can't start or exits non-zero and says which one. It never runs a logout:
/// claude-swap's README warns that logging out first may revoke the refresh token of the account being left, and its
/// documented add flow is exactly "log in with another account, then `cswap add`".
struct ClaudeSwapAddAccountFlow {
    struct Step: Equatable {
        let title: String
        let executable: String
        let arguments: [String]

        var commandLine: String {
            ([URL(fileURLWithPath: self.executable).lastPathComponent] + self.arguments).joined(separator: " ")
        }
    }

    enum Outcome: Equatable {
        case done
        /// `index` is 1-based.
        case failed(index: Int, step: Step, reason: String)
    }

    /// Runs one step to completion and returns its exit status; throws when it can't start.
    typealias Runner = (_ executable: String, _ arguments: [String]) throws -> Int32

    let steps: [Step]

    init(cswapPath: String, claudePath: String) {
        self.steps = [
            Step(title: "Save the current Claude login", executable: cswapPath, arguments: ["add"]),
            Step(title: "Sign in to the other Claude account", executable: claudePath, arguments: ["auth", "login"]),
            Step(title: "Save the new Claude login", executable: cswapPath, arguments: ["add"]),
        ]
    }

    func run(announce: (String) -> Void = { _ in }, runner: Runner = Self.runInheritingTerminal) -> Outcome {
        for (offset, step) in self.steps.enumerated() {
            let index = offset + 1
            announce("Step \(index) of \(self.steps.count): \(step.title) (\(step.commandLine))")
            let status: Int32
            do {
                status = try runner(step.executable, step.arguments)
            } catch {
                return .failed(index: index, step: step, reason: "it could not start")
            }
            guard status == 0 else {
                return .failed(index: index, step: step, reason: "it exited with status \(status)")
            }
        }
        return .done
    }

    static func message(for outcome: Outcome, total: Int = 3) -> String {
        switch outcome {
        case .done:
            "done"
        case let .failed(index, step, reason):
            "Step \(index) of \(total) failed: `\(step.commandLine)` (\(step.title.lowercased())): \(reason)."
        }
    }

    /// The child shares this process's stdin, stdout and stderr, so the steps' prompts and the browser link reach
    /// the terminal. No shell is involved.
    static func runInheritingTerminal(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension CodexBarCLI {
    static func claudeAddAccountHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar claude add-account

        Description:
          Adds another Claude subscription to claude-swap, in a terminal. Runs, in order and without a shell:
            1. cswap add           saves the login Claude Code holds now
            2. claude auth login   sign in to the other account in the browser
            3. cswap add           saves the new login
          Stops at the first step that fails and names it; prints "done" otherwise. It never logs out.
          Uses the claude provider's claudeSwapExecutablePath from config.json when it resolves, else finds cswap
          on PATH, in ~/.local/bin, or in uv's or pipx's tool directory.
        """
    }

    static func runClaudeAddAccount(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        configStore: CodexBarConfigStore = CodexBarConfigStore()) -> Never
    {
        let configured = (try? configStore.load())?.providerConfig(for: ClaudeSwapServeSource.provider.instanceID)?
            .claudeSwapExecutablePath
        guard let cswap = ClaudeSwapExecutableDetector.configuredOrDetected(
            configured: configured,
            environment: environment,
            home: home)
        else {
            self.writeUnbuffered(
                "claude-swap is not installed. Install it with `uv tool install claude-swap` and try again.\n")
            self.platformExit(ExitCode.binaryNotFound.rawValue)
        }
        guard let claude = ClaudeCodeExecutableDetector.detect(environment: environment, home: home) else {
            self.writeUnbuffered("Claude Code (`claude`) was not found. Install it and try again.\n")
            self.platformExit(ExitCode.binaryNotFound.rawValue)
        }
        let flow = ClaudeSwapAddAccountFlow(cswapPath: cswap, claudePath: claude)
        let outcome = flow.run(announce: { line in self.writeUnbuffered("\n\(line)\n") })
        self.writeUnbuffered("\n" + ClaudeSwapAddAccountFlow.message(for: outcome, total: flow.steps.count) + "\n")
        self.platformExit(outcome == .done ? 0 : ExitCode.failure.rawValue)
    }

    /// Straight to the terminal, so the step lines never land after the children's own output.
    private static func writeUnbuffered(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
