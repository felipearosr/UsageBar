import Foundation

public enum MachineSyncPairingLinkError: Error, Equatable, LocalizedError {
    case unsupportedScheme
    case unexpectedQuery
    case missingHost
    case invalidHost
    case invalidPort
    case missingRootKey
    case invalidRootKey

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme: "Not a Machine Sync address. Use an https:// or http:// server URL."
        case .unexpectedQuery: "The server address must not contain a query string."
        case .missingHost: "The server address has no host."
        case .invalidHost: "The server host may only contain letters, digits, '.', and '-'."
        case .invalidPort: "The server port must be a number from 1 to 65535."
        case .missingRootKey: "The Pairing Link has no key after '#'."
        case .invalidRootKey: "The Pairing Link key is not valid. Copy the whole link again."
        }
    }
}

/// `codexbar-sync[+http]://<host>[:<port>][/<base-path>]#<root-key>` (§2): the server address and the
/// Sync Group key in one secret string.
public struct MachineSyncPairingLink: Sendable, Equatable {
    public enum Transport: String, Sendable {
        case https
        case http
    }

    public let transport: Transport
    /// Host as written in the link; IPv6 addresses keep their brackets.
    public let host: String
    public let port: Int?
    /// Empty, or starting with `/` and without trailing `/`.
    public let basePath: String
    public let rootKey: MachineSyncRootKey

    public init(parsing link: String) throws {
        guard let schemeEnd = link.range(of: "://") else { throw MachineSyncPairingLinkError.unsupportedScheme }
        let scheme = String(link[..<schemeEnd.lowerBound])
        guard Self.isValidSchemeSyntax(scheme) else { throw MachineSyncPairingLinkError.unsupportedScheme }
        switch scheme.lowercased() {
        case "codexbar-sync": self.transport = .https
        case "codexbar-sync+http": self.transport = .http
        default: throw MachineSyncPairingLinkError.unsupportedScheme
        }

        var rest = Substring(link[schemeEnd.upperBound...])
        var fragment: Substring?
        if let hash = rest.firstIndex(of: "#") {
            fragment = rest[rest.index(after: hash)...]
            rest = rest[..<hash]
        }
        guard !rest.contains("?") else { throw MachineSyncPairingLinkError.unexpectedQuery }
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        (self.host, self.port) = try Self.parseAuthority(rest[..<authorityEnd])

        guard let fragment, !fragment.isEmpty else { throw MachineSyncPairingLinkError.missingRootKey }
        guard let rootKey = MachineSyncRootKey(base64URL: String(fragment)) else {
            throw MachineSyncPairingLinkError.invalidRootKey
        }
        self.rootKey = rootKey

        var basePath = String(rest[authorityEnd...])
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        self.basePath = basePath
    }

    /// Builds a link for a new Sync Group from the `https://` or `http://` server URL the user typed.
    public init(serverURL: String, rootKey: MachineSyncRootKey) throws {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let scheme: String
        let rest: Substring
        if lower.hasPrefix("https://") {
            scheme = "codexbar-sync"
            rest = trimmed.dropFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            scheme = "codexbar-sync+http"
            rest = trimmed.dropFirst("http://".count)
        } else {
            throw MachineSyncPairingLinkError.unsupportedScheme
        }
        guard !rest.contains("#") else { throw MachineSyncPairingLinkError.unsupportedScheme }
        try self.init(parsing: "\(scheme)://\(rest)#\(rootKey.base64URL)")
    }

    public var link: String {
        let scheme = self.transport == .https ? "codexbar-sync" : "codexbar-sync+http"
        return "\(scheme)://\(self.authority)\(self.basePath)#\(self.rootKey.base64URL)"
    }

    public var baseURL: String {
        "\(self.transport.rawValue)://\(self.authority)\(self.basePath)"
    }

    public var apiBaseURL: String {
        "\(self.baseURL)/v1"
    }

    /// Plain HTTP to a host that isn't loopback sends the bearer credential in cleartext; clients must warn.
    public var cleartextWarning: Bool {
        self.transport == .http && !Self.isLoopback(self.host)
    }

    public var keys: MachineSyncKeys {
        MachineSyncKeys(rootKey: self.rootKey)
    }

    private var authority: String {
        self.port.map { "\(self.host):\($0)" } ?? self.host
    }

    private static func isValidSchemeSyntax(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first else { return false }
        return first.isASCIILetter && scheme.unicodeScalars.allSatisfy {
            $0.isASCIILetter || $0.isASCIIDigit || $0 == "+" || $0 == "." || $0 == "-"
        }
    }

    private static func parseAuthority(_ authority: Substring) throws -> (String, Int?) {
        let host: Substring
        let rawPort: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw MachineSyncPairingLinkError.invalidHost }
            host = authority[...close]
            let inner = authority[authority.index(after: authority.startIndex)..<close]
            guard !inner.isEmpty,
                  inner.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit || $0 == ":" || $0 == "." })
            else { throw MachineSyncPairingLinkError.invalidHost }
            let afterHost = authority[authority.index(after: close)...]
            if afterHost.isEmpty {
                rawPort = nil
            } else if afterHost.hasPrefix(":"), !afterHost.dropFirst().contains(":") {
                rawPort = afterHost.dropFirst()
            } else {
                throw MachineSyncPairingLinkError.invalidHost
            }
        } else {
            let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            host = parts[0]
            rawPort = parts.count > 1 ? parts[1] : nil
            guard !host.contains("["), !host.contains("]"), !(rawPort?.contains(":") ?? false) else {
                throw MachineSyncPairingLinkError.invalidHost
            }
            guard !host.isEmpty else { throw MachineSyncPairingLinkError.missingHost }
            guard host.unicodeScalars.allSatisfy({
                $0.isASCIILetter || $0.isASCIIDigit || $0 == "." || $0 == "-"
            }) else { throw MachineSyncPairingLinkError.invalidHost }
        }

        guard let rawPort else { return (String(host), nil) }
        guard (1...5).contains(rawPort.count),
              rawPort.unicodeScalars.allSatisfy(\.isASCIIDigit),
              let port = Int(rawPort),
              (1...65535).contains(port)
        else { throw MachineSyncPairingLinkError.invalidPort }
        return (String(host), port)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "[::1]" { return true }
        let octets = lower.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.dropFirst().allSatisfy {
            (1...3).contains($0.count) && $0.unicodeScalars.allSatisfy(\.isASCIIDigit)
        }
    }
}

extension Unicode.Scalar {
    fileprivate var isASCIILetter: Bool {
        ("A"..."Z").contains(self) || ("a"..."z").contains(self)
    }

    fileprivate var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
