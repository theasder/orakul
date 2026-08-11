import Foundation
import Testing
@testable import MeetGPT

/// Fact-check verdicts, the watch notes and the Efficiency Engine's scored
/// items now travel with the meeting. Two things have to hold: they come back
/// when the call is reopened, and adding them did not break the sessions
/// already on disk.
@Suite("Session artifact persistence")
struct SessionArtifactPersistenceTests {

    private func store() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("cruxwing-tests/ArtifactPersistence-\(UUID().uuidString)",
                                    isDirectory: true))
    }

    private func session(id: UUID = UUID()) -> SavedSession {
        SavedSession(
            id: id,
            title: "Pricing review",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            savedAt: Date(timeIntervalSince1970: 1_800_003_600),
            goal: "Agree the July price",
            entries: [TranscriptEntry(source: .system, text: "We ship in July.",
                                      timestamp: Date(timeIntervalSince1970: 1_800_000_060))],
            aiResponse: "",
            digest: "",
            factClaims: [
                FactClaim(text: "Ships in July", status: .verified,
                          explanation: "Roadmap says July", source: "Roadmap v4: July",
                          confidence: .high, counterQuestion: "Which July build?")
            ],
            rhetoricNote: "Two people talked over each other twice.",
            facilitationNote: "One attendee has not spoken.",
            followUp: SavedFollowUp(
                goalType: "close_the_deal", label: "Close the deal", efficiencyScore: 0.62,
                actionItems: [SavedActionItem(title: "Send pricing", owner: "Priya",
                                              due: "2026-08-14", ask: "Send the deck",
                                              score: 0.9, missing: [])])
        )
    }

    @Test("a checked call keeps its verdicts, notes and scored items")
    func artifactsRoundTrip() throws {
        let store = store()
        let original = session()

        try store.save(original)
        let loaded = try #require(store.load(id: original.id))

        #expect(loaded.factClaims?.count == 1)
        #expect(loaded.factClaims?.first?.status == .verified)
        #expect(loaded.factClaims?.first?.confidence == .high)
        #expect(loaded.factClaims?.first?.counterQuestion == "Which July build?")
        #expect(loaded.rhetoricNote == "Two people talked over each other twice.")
        #expect(loaded.facilitationNote == "One attendee has not spoken.")
        #expect(loaded.followUp?.actionItems.first?.owner == "Priya")
        #expect(loaded.followUp?.efficiencyScore == 0.62)
    }

    @Test("a session written before these fields existed still decodes")
    func olderSessionsStillLoad() throws {
        // The reason every one of these fields is optional. A non-optional with
        // a default is ignored by the synthesized decoder, so a plain `= []`
        // would fail to decode every meeting already in History — losing the
        // transcript, not just the new field.
        let store = store()
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let id = UUID()
        let legacy = """
        {
          "id": "\(id.uuidString)",
          "title": "Old call",
          "startedAt": "2026-07-01T09:00:00Z",
          "savedAt": "2026-07-01T10:00:00Z",
          "goal": "",
          "entries": [],
          "aiResponse": "",
          "digest": "we agreed on the date"
        }
        """
        try Data(legacy.utf8).write(to: store.root.appendingPathComponent("\(id.uuidString).json"))

        let loaded = try #require(store.load(id: id))

        #expect(loaded.title == "Old call")
        #expect(loaded.digest == "we agreed on the date")
        #expect(loaded.factClaims == nil)
        #expect(loaded.rhetoricNote == nil)
        #expect(loaded.followUp == nil)
    }

    @Test("reopening a call restores what the co-pilot concluded about it")
    @MainActor
    func restoreBringsArtifactsBack() {
        let state = AppState(llm: MockLLMGateway(response: ""), credentialStore: InMemoryKeychain())
        state.factClaims = [FactClaim(text: "stale", status: .unverifiable,
                                      explanation: "from the previous call", source: nil)]
        state.rhetoricNote = "previous call's note"

        state.restoreSession(session())

        #expect(state.factClaims.count == 1)
        #expect(state.factClaims.first?.text == "Ships in July")
        #expect(state.rhetoricNote == "Two people talked over each other twice.")
        #expect(state.facilitationNote == "One attendee has not spoken.")
        #expect(state.efficiencyFollowUp?.actionItems.count == 1)
    }

    @Test("a session saved without them clears the previous call's, not leaves them")
    @MainActor
    func restoreClearsWhenAbsent() {
        // Leaving them in place is the bug this mirrors from context files: the
        // previous meeting's verdicts silently describing this one.
        let state = AppState(llm: MockLLMGateway(response: ""), credentialStore: InMemoryKeychain())
        state.factClaims = [FactClaim(text: "stale", status: .verified,
                                      explanation: "", source: "old doc")]
        state.facilitationNote = "previous call's note"

        var bare = session()
        bare.factClaims = nil
        bare.facilitationNote = nil
        bare.followUp = nil
        state.restoreSession(bare)

        #expect(state.factClaims.isEmpty)
        #expect(state.facilitationNote.isEmpty)
        #expect(state.efficiencyFollowUp == nil)
    }
}
