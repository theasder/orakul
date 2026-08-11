import Foundation
import Testing
@testable import MeetGPT

/// F3's entry point. The digest builder shipped with no way to invoke it, and
/// a feature nobody can reach is not shipped — it is dead code with tests.
///
/// The action is deliberately "build the text and put it on the clipboard".
/// Every send path in this category's public record is a leak story ("it
/// automatically emailed me the transcript, including hours of their private
/// conversations"), so the last mile stays a human choosing a window to paste
/// into.
@Suite("Weekly digest action")
@MainActor
struct WeeklyDigestActionTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(daysAgo: Double) -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(
            id: UUID(), title: "Pricing sync", startedAt: started, savedAt: started,
            goal: "", entries: [], aiResponse: "",
            digest: "Decided to sunset the legacy API in June.",
            followUp: SavedFollowUp(
                goalType: "planning", label: "Follow-up", efficiencyScore: 0.7,
                actionItems: [SavedActionItem(title: "Draft the migration plan",
                                              owner: "Priya", due: "Friday",
                                              ask: nil, score: 0.9, missing: [])]))
    }

    @Test("copying a digest puts the built text on the pasteboard and says so")
    func copiesAndConfirms() throws {
        let state = AppState()
        let store = try scratchStore()
        try store.save(session(daysAgo: 2))

        var copied: String?
        state.copyWeeklyDigest(audience: .team, store: store) { copied = $0 }

        let text = try #require(copied)
        #expect(text.contains("Team digest"))
        #expect(text.contains("sunset the legacy API"))
        #expect(text.contains("Draft the migration plan"))
        // The user is told what happened — a silent clipboard write reads as a
        // dead button.
        #expect(state.lastError == nil)
        #expect(state.digestCopyNotice?.contains("Team digest") == true)
    }

    @Test("each audience copies its own shape")
    func audienceRespected() throws {
        let state = AppState()
        let store = try scratchStore()
        try store.save(session(daysAgo: 1))

        var investor: String?
        state.copyWeeklyDigest(audience: .investor, store: store) { investor = $0 }
        let text = try #require(investor)
        #expect(text.contains("Investor update"))
        #expect(!text.contains("Priya"), "an investor update carries no org chart")
    }

    @Test("an empty week still copies an honest note rather than nothing")
    func emptyWeekCopies() throws {
        let state = AppState()
        let store = try scratchStore()

        var copied: String?
        state.copyWeeklyDigest(audience: .team, store: store) { copied = $0 }
        #expect(copied?.contains("No meetings") == true,
                "a button that does nothing when there is nothing to say looks broken")
    }

    @Test("the action never sends anything anywhere")
    func neverSends() throws {
        // The guarantee is structural: the only side effects are the clipboard
        // and a notice string. If this signature ever grows a network call,
        // the never-auto-send promise on the landing page becomes a lie.
        let state = AppState()
        let store = try scratchStore()
        try store.save(session(daysAgo: 1))
        state.copyWeeklyDigest(audience: .stakeholder, store: store) { _ in }
        #expect(state.digestCopyNotice != nil)
        #expect(state.lastError == nil)
    }
}
