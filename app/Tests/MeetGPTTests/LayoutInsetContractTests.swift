import Testing
import Foundation
@testable import MeetGPT

/// The top inset is a contract with history, because it has flip-flopped:
/// 30 once collided the sidebar brand with the traffic lights, the
/// short-window fix raised it to 52, and the owner then unified sidebar and
/// content panes at 16 after checking the real window (the brand row clears
/// the lights horizontally). Changing this number again should be a decision
/// that reads that history, not a drive-by.
@Suite("Layout inset contract")
struct LayoutInsetContractTests {
    @Test("one shared inset, owner-set to 16")
    func unifiedInset() {
        #expect(kContentTopInset == 16)
    }
}
