import Foundation

/// Temp-dir fixture for Spend Bucket scanner tests. Mirrors the macOS-only `CostUsageTestEnvironment`
/// so these tests also run on Linux.
struct SpendBucketTestEnvironment {
    let root: URL
    let cacheRoot: URL
    let codexSessionsRoot: URL
    let claudeProjectsRoot: URL
    let piSessionsRoot: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-spend-buckets-\(UUID().uuidString)",
            isDirectory: true)
        self.root = root
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.codexSessionsRoot = root.appendingPathComponent("codex-home/sessions", isDirectory: true)
        self.claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        self.piSessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        for dir in [self.cacheRoot, self.codexSessionsRoot, self.claudeProjectsRoot, self.piSessionsRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: comps) else {
            throw NSError(domain: "SpendBucketTestEnvironment", code: 1)
        }
        return date
    }

    static func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    @discardableResult
    func write(root: URL, relativePath: String, lines: [Any]) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { obj in
            let data = try JSONSerialization.data(withJSONObject: obj)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
