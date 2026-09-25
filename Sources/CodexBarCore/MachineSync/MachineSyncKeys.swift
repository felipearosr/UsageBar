import Crypto
import Foundation

/// Unpadded base64url (RFC 4648 §5), the encoding Machine Sync uses for keys and IDs on the wire.
public enum MachineSyncBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes `text` only when it is the canonical encoding of `byteCount` bytes: the exact length, the
    /// base64url alphabet, no padding, and zero unused trailing bits.
    public static func decodeCanonical(_ text: String, byteCount: Int) -> Data? {
        guard text.count == self.encodedLength(byteCount: byteCount),
              text.unicodeScalars.allSatisfy(self.isAlphabetScalar)
        else { return nil }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard),
              data.count == byteCount,
              self.encode(data) == text
        else { return nil }
        return data
    }

    public static func encodedLength(byteCount: Int) -> Int {
        (byteCount * 8 + 5) / 6
    }

    private static func isAlphabetScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": true
        default: false
        }
    }
}

/// The 32-byte secret at the heart of a Sync Group (§2). Everything else is derived from it (§3).
public struct MachineSyncRootKey: Sendable, Equatable {
    public static let byteCount = 32

    public let data: Data

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        self.data = data
    }

    public init?(base64URL: String) {
        guard let data = MachineSyncBase64URL.decodeCanonical(base64URL, byteCount: Self.byteCount) else {
            return nil
        }
        self.data = data
    }

    public static func generate() -> MachineSyncRootKey {
        MachineSyncRootKey(data: MachineSyncRandom.bytes(self.byteCount))!
    }

    public var base64URL: String {
        MachineSyncBase64URL.encode(self.data)
    }
}

/// Keys derived from a root key with HKDF-SHA256 (§3).
public struct MachineSyncKeys: Sendable {
    static let protocolLabel = "codexbar-sync/v1"

    public let groupID: Data
    public let authKey: Data
    public let encKey: Data

    public init(rootKey: MachineSyncRootKey) {
        func derive(_ info: String, _ length: Int) -> Data {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: rootKey.data),
                salt: Data(Self.protocolLabel.utf8),
                info: Data(info.utf8),
                outputByteCount: length)
            return key.withUnsafeBytes { Data($0) }
        }
        self.groupID = derive("group-id", 16)
        self.authKey = derive("auth", 32)
        self.encKey = derive("enc", 32)
    }

    /// Group ID as sent to the server: 22 base64url characters.
    public var groupIDBase64URL: String {
        MachineSyncBase64URL.encode(self.groupID)
    }

    /// `SHA-256(auth-key)`, the only form of the credential the server stores.
    public var authKeyHash: Data {
        Data(SHA256.hash(data: self.authKey))
    }

    public var authKeyHashBase64URL: String {
        MachineSyncBase64URL.encode(self.authKeyHash)
    }

    public var authorizationHeader: String {
        "Bearer \(MachineSyncBase64URL.encode(self.authKey))"
    }
}

/// A Machine's random identity (§4): 16 bytes, base64url.
public enum MachineSyncMachineID {
    public static let byteCount = 16
    /// Reserved ID for blobs that belong to the Sync Group rather than a Machine (§5.3).
    public static let group = "group"

    public static func generate() -> String {
        MachineSyncBase64URL.encode(MachineSyncRandom.bytes(self.byteCount))
    }

    public static func isValid(_ id: String) -> Bool {
        MachineSyncBase64URL.decodeCanonical(id, byteCount: self.byteCount) != nil
    }
}

enum MachineSyncRandom {
    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
