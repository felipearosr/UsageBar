import Foundation
import Testing
@testable import CodexBarCore

/// Checks the Swift client against `docs/machine-sync-test-vectors/vectors.json` byte for byte.
struct MachineSyncProtocolVectorTests {
    private struct Vectors: Decodable {
        struct RootKey: Decodable {
            let hex: String
            let base64url: String
        }

        struct Keys: Decodable {
            let groupId: String
            let groupIdBase64url: String
            let authKey: String
            let authorizationHeader: String
            let authKeyHash: String
            let authKeyHashBase64url: String
            let encKey: String
        }

        struct Envelope: Decodable {
            let description: String
            let machineId: String
            let name: String
            let nonce: String
            let associatedData: String
            let plaintext: String
            let paddedPlaintext: String
            let ciphertext: String
            let envelope: String
        }

        struct Tampered: Decodable {
            let description: String
            let associatedData: String
            let envelope: String
        }

        struct Links: Decodable {
            struct Valid: Decodable {
                struct Result: Decodable {
                    let transport: String
                    let host: String
                    let port: Int?
                    let basePath: String
                    let baseURL: String
                    let apiBaseURL: String
                    let rootKey: String
                    let groupId: String
                    let cleartextWarning: Bool
                }

                let description: String
                let link: String
                let result: Result
            }

            struct Invalid: Decodable {
                let description: String
                let link: String
                let error: String
            }

            let valid: [Valid]
            let invalid: [Invalid]
        }

        let rootKey: RootKey
        let keys: Keys
        let envelopes: [Envelope]
        let tamperedEnvelopes: [Tampered]
        let pairingLinks: Links
    }

    private static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/machine-sync-test-vectors/vectors.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private static var keys: MachineSyncKeys {
        MachineSyncKeys(rootKey: MachineSyncRootKey(data: self.bytes(hex: self.vectors.rootKey.hex))!)
    }

    /// Splits `codexbar-sync/v1|<group>|<machine>|<name>` back into an address.
    private static func address(associatedData: String) -> MachineSyncBlobAddress {
        let parts = associatedData.split(separator: "|").map(String.init)
        return MachineSyncBlobAddress(groupID: parts[1], machineID: parts[2], name: parts[3])
    }

    @Test
    func `root key round-trips through base64url`() throws {
        let rootKey = try #require(MachineSyncRootKey(base64URL: Self.vectors.rootKey.base64url))
        #expect(Self.hex(rootKey.data) == Self.vectors.rootKey.hex)
        #expect(rootKey.base64URL == Self.vectors.rootKey.base64url)
    }

    @Test
    func `derived keys match the vectors`() {
        let keys = Self.keys
        let expected = Self.vectors.keys
        #expect(Self.hex(keys.groupID) == expected.groupId)
        #expect(keys.groupIDBase64URL == expected.groupIdBase64url)
        #expect(Self.hex(keys.authKey) == expected.authKey)
        #expect(keys.authorizationHeader == expected.authorizationHeader)
        #expect(Self.hex(keys.authKeyHash) == expected.authKeyHash)
        #expect(keys.authKeyHashBase64URL == expected.authKeyHashBase64url)
        #expect(Self.hex(keys.encKey) == expected.encKey)
    }

    @Test(arguments: Self.vectors.envelopes.map(\.description))
    func `sealing reproduces the envelope`(description: String) throws {
        let vector = try #require(Self.vectors.envelopes.first { $0.description == description })
        let address = MachineSyncBlobAddress(
            groupID: Self.keys.groupIDBase64URL,
            machineID: vector.machineId,
            name: vector.name)
        #expect(String(decoding: address.associatedData, as: UTF8.self) == vector.associatedData)
        #expect(Self.hex(MachineSyncEnvelope.pad(Data(vector.plaintext.utf8))) == vector.paddedPlaintext)

        let envelope = try MachineSyncEnvelope.seal(
            Data(vector.plaintext.utf8),
            encKey: Self.keys.encKey,
            address: address,
            nonce: Self.bytes(hex: vector.nonce))
        #expect(envelope.base64EncodedString() == vector.envelope)
        #expect(Self.hex(envelope.dropFirst(13)).hasPrefix(vector.ciphertext))
    }

    @Test(arguments: Self.vectors.envelopes.map(\.description))
    func `opening returns the plaintext`(description: String) throws {
        let vector = try #require(Self.vectors.envelopes.first { $0.description == description })
        let opened = try MachineSyncEnvelope.open(
            #require(Data(base64Encoded: vector.envelope)),
            encKey: Self.keys.encKey,
            address: Self.address(associatedData: vector.associatedData))
        #expect(String(decoding: opened, as: UTF8.self) == vector.plaintext)
    }

    @Test(arguments: Self.vectors.tamperedEnvelopes.map(\.description))
    func `tampered envelopes fail to open`(description: String) throws {
        let vector = try #require(Self.vectors.tamperedEnvelopes.first { $0.description == description })
        #expect(throws: MachineSyncEnvelopeError.authenticationFailed) {
            try MachineSyncEnvelope.open(
                #require(Data(base64Encoded: vector.envelope)),
                encKey: Self.keys.encKey,
                address: Self.address(associatedData: vector.associatedData))
        }
    }

    @Test(arguments: Self.vectors.pairingLinks.valid.map(\.description))
    func `valid pairing links parse as listed`(description: String) throws {
        let vector = try #require(Self.vectors.pairingLinks.valid.first { $0.description == description })
        let link = try MachineSyncPairingLink(parsing: vector.link)
        let expected = vector.result
        #expect(link.transport.rawValue == expected.transport)
        #expect(link.host == expected.host)
        #expect(link.port == expected.port)
        #expect(link.basePath == expected.basePath)
        #expect(link.baseURL == expected.baseURL)
        #expect(link.apiBaseURL == expected.apiBaseURL)
        #expect(Self.hex(link.rootKey.data) == expected.rootKey)
        #expect(link.keys.groupIDBase64URL == expected.groupId)
        #expect(link.cleartextWarning == expected.cleartextWarning)
        #expect(try MachineSyncPairingLink(parsing: link.link) == link)
    }

    @Test(arguments: Self.vectors.pairingLinks.invalid.map(\.description))
    func `invalid pairing links are rejected for the listed reason`(description: String) throws {
        let vector = try #require(Self.vectors.pairingLinks.invalid.first { $0.description == description })
        let expected: MachineSyncPairingLinkError = switch vector.error {
        case "unsupported_scheme": .unsupportedScheme
        case "unexpected_query": .unexpectedQuery
        case "missing_host": .missingHost
        case "invalid_host": .invalidHost
        case "invalid_port": .invalidPort
        case "missing_root_key": .missingRootKey
        default: .invalidRootKey
        }
        #expect(throws: expected) { try MachineSyncPairingLink(parsing: vector.link) }
    }

    @Test
    func `server URLs become pairing links`() throws {
        let rootKey = try #require(MachineSyncRootKey(base64URL: Self.vectors.rootKey.base64url))
        let https = try MachineSyncPairingLink(serverURL: "https://sync.example.com:8443/codexbar/", rootKey: rootKey)
        #expect(https.link == "codexbar-sync://sync.example.com:8443/codexbar#\(rootKey.base64URL)")
        #expect(https.apiBaseURL == "https://sync.example.com:8443/codexbar/v1")

        let http = try MachineSyncPairingLink(serverURL: "HTTP://nas.local:8787", rootKey: rootKey)
        #expect(http.link == "codexbar-sync+http://nas.local:8787#\(rootKey.base64URL)")
        #expect(http.cleartextWarning)

        #expect(throws: MachineSyncPairingLinkError.unsupportedScheme) {
            try MachineSyncPairingLink(serverURL: "ftp://sync.example.com", rootKey: rootKey)
        }
        #expect(throws: MachineSyncPairingLinkError.unexpectedQuery) {
            try MachineSyncPairingLink(serverURL: "https://sync.example.com/?x=1", rootKey: rootKey)
        }
        #expect(throws: MachineSyncPairingLinkError.invalidHost) {
            try MachineSyncPairingLink(serverURL: "https://user@sync.example.com", rootKey: rootKey)
        }
    }
}
