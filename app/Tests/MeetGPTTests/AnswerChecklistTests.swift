import Foundation
import Testing
@testable import MeetGPT

/// Detecting a checklist in an answer.
///
/// The cost of a false positive is real: the action group gets renamed after a
/// list that is not a checklist, so the button describes something the answer
/// never offered. These tests are weighted towards refusing rather than
/// finding.
@Suite("Answer checklist")
struct AnswerChecklistTests {

    @Test("finds markdown checkboxes")
    func findsCheckboxes() {
        let answer = """
        Before the launch:

        - [ ] Confirm the vendor delivery date
        - [ ] Sign off the DPA
        - [x] Freeze the pricing page
        """
        #expect(AnswerChecklist.itemCount(in: answer) == 3)
        #expect(AnswerChecklist.contains(in: answer))
    }

    @Test("finds numbered steps")
    func findsNumberedSteps() {
        let answer = """
        1. Migrate the Postgres cluster
        2. Run the backfill
        3) Re-enable writes
        """
        #expect(AnswerChecklist.itemCount(in: answer) == 3)
    }

    @Test("plain prose bullets are not a checklist")
    func prosebulletsAreNotChecklists() {
        // The common case: an answer that explains something in bullets. There
        // is nothing here to turn into tasks.
        let answer = """
        Two things stood out:

        - Maria owns the contract
        - The launch slipped to September
        """
        #expect(AnswerChecklist.itemCount(in: answer) == 0)
    }

    @Test("a single item is a sentence with a dash, not a list")
    func singleItemIsNotAList() {
        #expect(AnswerChecklist.itemCount(in: "- [ ] Do the one thing") == 0)
        #expect(AnswerChecklist.itemCount(in: "1. Only one step") == 0)
    }

    @Test("ordinary prose containing digits is not a checklist")
    func proseWithNumbersIsNotAList() {
        let answer = "The budget is 40,000 and the launch is in September. 2 risks remain."
        #expect(AnswerChecklist.itemCount(in: answer) == 0)
    }

    @Test("checkboxes win over an unrelated numbered list in the same answer")
    func checkboxesTakePrecedence() {
        let answer = """
        - [ ] Confirm delivery
        - [ ] Sign the DPA

        For reference the tiers are:
        1. Pro
        2. Premium
        3. Ultra
        """
        // Counting both would claim 5 tasks when only 2 are actionable.
        #expect(AnswerChecklist.itemCount(in: answer) == 2)
    }

    @Test("an empty answer has no checklist")
    func emptyAnswer() {
        #expect(AnswerChecklist.itemCount(in: "") == 0)
        #expect(!AnswerChecklist.contains(in: ""))
    }

    // MARK: - The group title

    @Test("names the connection when the answer is a checklist")
    func namesTheConnection() {
        let answer = "- [ ] One\n- [ ] Two\n- [ ] Three"
        #expect(AnswerChecklist.actionGroupTitle(forAnswer: answer, hasTaskAction: true)
                == "Turn these 3 into tasks")
    }

    @Test("keeps the default label when nothing creates tasks")
    func keepsDefaultWithoutTaskAction() {
        // Renaming above a "Draft an email" action would describe the wrong
        // thing, so the caller keeps "Do this".
        let answer = "- [ ] One\n- [ ] Two"
        #expect(AnswerChecklist.actionGroupTitle(forAnswer: answer, hasTaskAction: false) == nil)
    }

    @Test("keeps the default label when the answer is not a checklist")
    func keepsDefaultWithoutChecklist() {
        #expect(AnswerChecklist.actionGroupTitle(forAnswer: "Maria owns the contract.",
                                                 hasTaskAction: true) == nil)
    }

    @Test("indented checklist items still count")
    func indentedItemsCount() {
        let answer = "  - [ ] Nested one\n  - [ ] Nested two"
        #expect(AnswerChecklist.itemCount(in: answer) == 2)
    }
}
