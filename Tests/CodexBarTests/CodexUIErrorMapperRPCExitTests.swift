import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CodexUIErrorMapperRPCExitTests {
    @Test
    func `app-server exit keeps the transient transport mapping`() {
        let exited = RPCWireError.processExited(termination: .exited(1), stderr: "boom").localizedDescription
        let closed = RPCWireError.processExited(termination: nil, stderr: nil).localizedDescription

        #expect(
            CodexUIErrorMapper.userFacingMessage(exited) == "Codex usage is temporarily unavailable. Try refreshing.")
        #expect(
            CodexUIErrorMapper.userFacingMessage(closed) == "Codex usage is temporarily unavailable. Try refreshing.")
    }
}
