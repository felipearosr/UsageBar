import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIErrorReasonTests {
    /// The error payload shape before `reason` existed; payloads without a reason must encode identically.
    private struct LegacyProviderErrorPayload: Encodable {
        let code: Int32
        let message: String
        let kind: CLIErrorKind?
    }

    private struct PlainError: LocalizedError {
        var errorDescription: String? {
            "plain failure"
        }
    }

    private struct ReasonedError: LocalizedError, CLIErrorReasonProviding {
        var errorDescription: String? {
            "reasoned failure"
        }

        var cliErrorReason: String {
            "example_reason"
        }
    }

    private static func encode(_ value: some Encodable, sorted: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = sorted ? [.sortedKeys] : []
        return try #require(String(data: encoder.encode(value), encoding: .utf8))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func `error payload without reason encodes like the legacy shape`() throws {
        let kinds: [CLIErrorKind?] = [nil, .args, .config, .provider, .runtime]
        for kind in kinds {
            let current = ProviderErrorPayload(code: 1, message: "Nope", kind: kind)
            let legacy = LegacyProviderErrorPayload(code: 1, message: "Nope", kind: kind)
            // Sorted keys give a deterministic byte stream (unsorted key order is not stable on Linux).
            #expect(try Self.encode(current, sorted: true) == Self.encode(legacy, sorted: true))
            // Unsorted output still carries exactly the legacy keys and values.
            let currentObject = try Self.jsonObject(Data(Self.encode(current, sorted: false).utf8))
            let legacyObject = try Self.jsonObject(Data(Self.encode(legacy, sorted: false).utf8))
            #expect(NSDictionary(dictionary: currentObject).isEqual(to: legacyObject))
        }
    }

    @Test
    func `cli error payload omits reason unless one is given`() throws {
        let withoutReason = try #require(CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            pretty: false))
        #expect(!withoutReason.contains("reason"))
        let plainArray = try #require(
            JSONSerialization.jsonObject(with: Data(withoutReason.utf8)) as? [[String: Any]])
        let plainError = try #require(plainArray.first?["error"] as? [String: Any])
        #expect(Set(plainError.keys) == ["code", "message", "kind"])

        let withReason = try #require(CodexBarCLI.makeCLIErrorPayload(
            message: "Nope",
            code: .failure,
            kind: .args,
            reason: "example_reason",
            pretty: true))
        let array = try #require(JSONSerialization.jsonObject(with: Data(withReason.utf8)) as? [[String: Any]])
        let error = try #require(array.first?["error"] as? [String: Any])
        #expect(error["reason"] as? String == "example_reason")
        #expect(error["message"] as? String == "Nope")
        #expect(error["kind"] as? String == "args")
    }

    @Test
    func `toon output only mentions reason when one is set`() {
        let output = CLIOutputPreferences.from(argv: ["--format", "toon"])
        let plain = CodexBarCLI.renderProviderPayloads(
            [CodexBarCLI.makeCLIErrorProviderPayload(message: "Nope", code: .failure, kind: .args)],
            output: output)
        #expect(!plain.contains("reason"))

        let reasoned = CodexBarCLI.renderProviderPayloads(
            [CodexBarCLI.makeCLIErrorProviderPayload(
                message: "Nope",
                code: .failure,
                kind: .args,
                reason: "example_reason")],
            output: output)
        #expect(reasoned.contains("reason"))
        #expect(reasoned.contains("example_reason"))
    }

    @Test
    func `error payload takes reason from errors that provide one`() {
        #expect(CodexBarCLI.makeErrorPayload(PlainError()).reason == nil)
        let payload = CodexBarCLI.makeErrorPayload(ReasonedError(), kind: .provider)
        #expect(payload.reason == "example_reason")
        #expect(payload.message == "reasoned failure")
        #expect(payload.kind == .provider)
    }

    @Test
    func `serve provider timeout row carries the timeout reason`() throws {
        let output = CodexBarCLI.serveProviderTimeoutOutput(provider: .codex)
        let error = try #require(output.payload.first?.error)
        #expect(error.reason == CodexBarCLI.serveTimeoutReason)
        #expect(error.reason == "timeout")
        #expect(error.kind == .provider)
    }

    @Test
    func `serve error body is unchanged without a reason`() {
        let response = CodexBarCLI.serveError(status: .notFound, message: "not found")
        #expect(String(data: response.body, encoding: .utf8) == #"{"error":"not found"}"#)
    }

    @Test
    func `serve timeout body carries the timeout reason`() throws {
        let response = CodexBarCLI.serveTimeoutResponse()
        #expect(response.status == .gatewayTimeout)
        let body = try Self.jsonObject(response.body)
        #expect(body["error"] as? String == "request timed out")
        #expect(body["reason"] as? String == "timeout")
        #expect(body.count == 2)
    }
}
