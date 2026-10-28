import CodexBarCore
import Commander
import Foundation

// UsageBar: `codexbar claude statusline capture`, restored from upstream #2769 (removed in #3006).

extension CodexBarCLI {
    static func claudeCommandDescriptor() -> CommandDescriptor {
        // Provider-specific by design: the statusLine payload is a Claude Code integration with no other provider.
        CommandDescriptor(
            name: "claude",
            abstract: "Claude Code integrations",
            discussion: nil,
            signature: CommandSignature(),
            subcommands: [
                CommandDescriptor(
                    name: "statusline",
                    abstract: "Claude Code statusLine integration",
                    discussion: nil,
                    signature: CommandSignature(),
                    subcommands: [
                        CommandDescriptor(
                            name: "capture",
                            abstract: "Capture sanitized Claude Code rate-limit windows from stdin",
                            discussion: nil,
                            signature: CommandSignature()),
                    ],
                    defaultSubcommandName: "capture"),
            ],
            defaultSubcommandName: "statusline")
    }

    static func claudeStatusLineHelp(version: String) -> String {
        """
        CodexBar \(version)

        Usage:
          codexbar claude statusline capture

        Description:
          Reads one bounded Claude Code statusLine JSON object from stdin and stores only the official
          rate_limits.five_hour and rate_limits.seven_day percentages and reset times, tagged with a hash of the
          signed-in Claude account. Stdout is empty so this helper does not add text to Claude Code's status line.
          Invalid input is ignored. Turn the feed on with "statusLineFeed": true on the claude provider in
          config.json.
        """
    }

    static func runClaudeStatusLineCapture(
        input: FileHandle = .standardInput,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupport: URL? = nil,
        now: Date = Date())
    {
        guard let data = try? self.readBoundedInput(input, limit: ClaudeStatusLineFeed.maximumInputBytes),
              let observation = ClaudeStatusLinePayloadParser.parseOfficialPayload(
                  data,
                  capturedAt: now,
                  environment: environment),
              let support = applicationSupport ?? FileManager.default.urls(
                  for: .applicationSupportDirectory,
                  in: .userDomainMask).first
        else { return }
        try? ClaudeStatusLineDropStore.write(observation, applicationSupport: support)
        // Intentionally no stdout: Claude Code renders stdout as the status line.
    }

    static func readBoundedInput(_ input: FileHandle, limit: Int) throws -> Data? {
        var result = Data()
        while let chunk = try input.read(upToCount: min(64 * 1024, limit + 1 - result.count)), !chunk.isEmpty {
            result.append(chunk)
            if result.count > limit {
                return nil
            }
        }
        return result
    }
}
