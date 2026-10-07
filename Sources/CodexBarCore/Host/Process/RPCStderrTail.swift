import Foundation

/// How a JSON-RPC child process ended, as reported by Foundation `Process`.
enum RPCChildTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    init?(process: Process) {
        guard !process.isRunning else { return nil }
        switch process.terminationReason {
        case .exit:
            self = .exited(process.terminationStatus)
        case .uncaughtSignal:
            self = .signaled(process.terminationStatus)
        @unknown default:
            self = .exited(process.terminationStatus)
        }
    }

    var summary: String {
        switch self {
        case let .exited(status):
            "status \(status)"
        case let .signaled(signal):
            "signal \(signal)"
        }
    }
}

/// Bounded, thread-safe tail of a child process's stderr, kept so an unexpected RPC exit can explain itself.
final class RPCStderrTail: @unchecked Sendable {
    static let defaultMaxBytes = 4096
    static let defaultMaxLineCharacters = 240

    /// Trailer lines runtimes print after the real error; they never explain the failure on their own.
    private static let noiseLinePrefixes = [
        "note: run with `rust_backtrace",
        "node.js v",
        "at ",
    ]

    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()
    private var closed = false

    init(maxBytes: Int = RPCStderrTail.defaultMaxBytes) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.buffer.append(data)
        let overflow = self.buffer.count - self.maxBytes
        if overflow > 0 {
            self.buffer.removeFirst(overflow)
            // Don't start mid-way through a multi-byte UTF-8 character.
            while let first = self.buffer.first, first & 0xC0 == 0x80 {
                self.buffer.removeFirst()
            }
        }
    }

    func markClosed() {
        self.lock.lock()
        self.closed = true
        self.lock.unlock()
    }

    var isClosed: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.closed
    }

    var text: String {
        self.lock.lock()
        let data = self.buffer
        self.lock.unlock()
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    func lastMeaningfulLine() -> String? {
        Self.lastMeaningfulLine(in: self.text)
    }

    /// Returns the last non-empty, non-trailer stderr line with ANSI/control characters removed,
    /// truncated to `maxCharacters` (an ellipsis marks truncation).
    static func lastMeaningfulLine(
        in text: String,
        maxCharacters: Int = RPCStderrTail.defaultMaxLineCharacters) -> String?
    {
        let stripped = TextParsing.stripANSICodes(text)
        var fallback: String?
        for rawLine in stripped.split(whereSeparator: \.isNewline).reversed() {
            let line = Self.sanitize(rawLine)
            guard !line.isEmpty else { continue }
            if Self.isNoise(line) {
                fallback = fallback ?? line
                continue
            }
            return Self.truncate(line, maxCharacters: maxCharacters)
        }
        return fallback.map { Self.truncate($0, maxCharacters: maxCharacters) }
    }

    private static func sanitize(_ line: Substring) -> String {
        let scalars = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private static func isNoise(_ line: String) -> Bool {
        let lower = line.lowercased()
        return self.noiseLinePrefixes.contains { lower.hasPrefix($0) }
    }

    private static func truncate(_ line: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, line.count > maxCharacters else { return line }
        return String(line.prefix(max(0, maxCharacters - 1))) + "…"
    }
}
