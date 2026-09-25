import Crypto
import Foundation

/// Where a blob lives on the Sync Server: `(group-id, machine-id, name)` (§5).
public struct MachineSyncBlobAddress: Sendable, Hashable {
    public let groupID: String
    public let machineID: String
    public let name: String

    public init(groupID: String, machineID: String, name: String) {
        self.groupID = groupID
        self.machineID = machineID
        self.name = name
    }

    /// Binds a blob to its address so the server can't swap blobs between Machines, days, or groups.
    public var associatedData: Data {
        Data("\(MachineSyncKeys.protocolLabel)|\(self.groupID)|\(self.machineID)|\(self.name)".utf8)
    }
}

public enum MachineSyncEnvelopeError: Error, Equatable {
    case tooLarge(Int)
    case malformed
    case unsupportedVersion(UInt8)
    case authenticationFailed
}

/// The encrypted blob format (§5.1): `version || nonce || ChaCha20-Poly1305(padded JSON) || tag`.
public enum MachineSyncEnvelope {
    public static let version: UInt8 = 0x01
    public static let maxBytes = 64 * 1024
    static let nonceBytes = 12
    static let tagBytes = 16
    static let padBlock = 1024

    public static func seal(
        _ plaintext: Data,
        encKey: Data,
        address: MachineSyncBlobAddress,
        nonce: Data? = nil) throws -> Data
    {
        let nonceData = nonce ?? MachineSyncRandom.bytes(Self.nonceBytes)
        let box = try ChaChaPoly.seal(
            self.pad(plaintext),
            using: SymmetricKey(data: encKey),
            nonce: ChaChaPoly.Nonce(data: nonceData),
            authenticating: address.associatedData)
        var envelope = Data([Self.version])
        envelope.append(nonceData)
        envelope.append(box.ciphertext)
        envelope.append(box.tag)
        guard envelope.count <= Self.maxBytes else { throw MachineSyncEnvelopeError.tooLarge(envelope.count) }
        return envelope
    }

    /// Opens an envelope and strips the zero padding. Any tampering, including an address mismatch, fails.
    public static func open(_ envelope: Data, encKey: Data, address: MachineSyncBlobAddress) throws -> Data {
        let bytes = [UInt8](envelope)
        guard bytes.count >= 1 + Self.nonceBytes + Self.tagBytes else { throw MachineSyncEnvelopeError.malformed }
        guard bytes[0] == Self.version else { throw MachineSyncEnvelopeError.unsupportedVersion(bytes[0]) }
        let nonceEnd = 1 + Self.nonceBytes
        let tagStart = bytes.count - Self.tagBytes
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Data(bytes[1..<nonceEnd])),
                ciphertext: Data(bytes[nonceEnd..<tagStart]),
                tag: Data(bytes[tagStart...]))
            let padded = try ChaChaPoly.open(
                box,
                using: SymmetricKey(data: encKey),
                authenticating: address.associatedData)
            return self.unpad(padded)
        } catch {
            throw MachineSyncEnvelopeError.authenticationFailed
        }
    }

    /// Zero-pads to the next multiple of 1 KiB; a plaintext already on a boundary gets no padding.
    static func pad(_ plaintext: Data) -> Data {
        let remainder = plaintext.count % Self.padBlock
        guard remainder != 0 else { return plaintext }
        return plaintext + Data(count: Self.padBlock - remainder)
    }

    static func unpad(_ padded: Data) -> Data {
        guard let last = padded.lastIndex(where: { $0 != 0 }) else { return Data() }
        return Data(padded[...last])
    }
}
