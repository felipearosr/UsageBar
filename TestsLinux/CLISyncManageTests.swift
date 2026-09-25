import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLISyncManageTests {
    private final class Asked: @unchecked Sendable {
        var prompts: [String] = []
    }

    private func confirm(yes: Bool = false, json: Bool = false, terminal: Bool = true, answer: String?) -> (
        Bool,
        [String])
    {
        let asked = Asked()
        let confirmed = CodexBarCLI.confirmSyncAction(
            "Forget it?",
            yes: yes,
            jsonOutput: json,
            isTerminal: terminal,
            ask: { prompt in
                asked.prompts.append(prompt)
                return answer
            })
        return (confirmed, asked.prompts)
    }

    @Test
    func `forget and leave ask before acting and only a yes goes ahead`() {
        #expect(self.confirm(answer: "y") == (true, ["Forget it?"]))
        #expect(self.confirm(answer: " YES ").0)
        #expect(self.confirm(answer: "").0 == false)
        #expect(self.confirm(answer: "n").0 == false)
        #expect(self.confirm(answer: nil).0 == false)
    }

    @Test
    func `--yes skips the question for scripts`() {
        #expect(self.confirm(yes: true, terminal: false, answer: nil) == (true, []))
        #expect(self.confirm(yes: true, json: true, answer: nil) == (true, []))
    }

    @Test
    func `without a terminal or with JSON output nothing is asked and nothing happens`() {
        #expect(self.confirm(terminal: false, answer: "y") == (false, []))
        #expect(self.confirm(json: true, answer: "y") == (false, []))
    }

    @Test
    func `prompts and results name the Machine and what happens to its Spend`() {
        let desk = MachineSyncMachineRef(machineID: "AAAAAAAAAAAAAAAAAAAAAA", displayName: "desk", isThisMachine: false)
        #expect(CodexBarCLI.syncForgetPrompt(desk).hasPrefix("Forget \"desk\" (AAAAAAAAAAAAAAAAAAAAAA)?"))
        #expect(CodexBarCLI.syncForgetPrompt(desk).contains("can't be undone"))
        #expect(CodexBarCLI.syncRetireText(desk).contains("still counts toward totals"))
        #expect(CodexBarCLI.syncLeavePrompt.contains("stays on the server"))

        let unnamed = MachineSyncMachineRef(machineID: "BBBBBBBBBBBBBBBBBBBBBB", displayName: nil, isThisMachine: false)
        #expect(CodexBarCLI.syncRetireText(unnamed).hasPrefix("Retired \"BBBBBBBBBBBBBBBBBBBBBB\""))

        let unpaired = MachineSyncSettings(machineID: "m", displayName: "laptop")
        #expect(CodexBarCLI.syncRenameText(unpaired, pushError: nil)
            == "This Machine is now \"laptop\".\nIt isn't in a Sync Group; the name is used when it pairs.")
        let paired = MachineSyncSettings(machineID: "m", displayName: "laptop", pairingLink: "codexbar-sync://x#k")
        #expect(CodexBarCLI.syncRenameText(paired, pushError: nil) == "This Machine is now \"laptop\".")
    }
}
