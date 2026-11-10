import CodexBarCore
import Foundation

// MARK: - UsageBar: how an account helper tells its launcher it finished (#169, #172)

/// The outcome an interactive account helper (`codexbar codex-accounts add`, and claude-swap's add helper) leaves
/// for whoever opened it in a terminal. Terminal launchers that hand the window to a terminal server (gnome-terminal,
/// ptyxis) exit at once, so the launcher can't wait for the helper's process; it passes `--result-file <path>` and
/// watches that file instead (the GNOME extension's helperrun.js).
///
/// The file is written once, when the helper ends, through the private atomic writer (0600, never a partial file):
/// `{"status": "done" | "failed", "message": "<what the terminal printed>"}`. The message never carries a token or
/// an email.
struct AccountHelperResult: Encodable, Equatable {
    enum Status: String, Encodable {
        case done
        case failed
    }

    let status: Status
    let message: String

    /// The `--result-file` option every account helper takes (`@Option(name: .long("result-file")) var resultFile`).
    /// Commander keys parsed options by the property's name.
    static let optionKey = "resultFile"

    /// The path from `--result-file`, when it is absolute; otherwise nil (a relative path is never written).
    static func path(from options: [String: [String]]) -> String? {
        guard let raw = options[self.optionKey]?.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("/")
        else { return nil }
        return raw
    }

    /// Writes the result to `path`, if any. Best effort: the terminal shows the same outcome either way.
    func write(to path: String?) {
        guard let path, let data = try? JSONEncoder().encode(self) else { return }
        try? CredentialFileWriter.writePrivate(data, to: URL(fileURLWithPath: path))
    }
}
