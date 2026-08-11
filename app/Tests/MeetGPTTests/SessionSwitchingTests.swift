import Foundation
import Testing
@testable import MeetGPT

/// Opening a call from History must swap the WHOLE workspace, not just the
/// transcript. The saved session carried the transcript, goal and assistant
/// answer but never the context panel, so switching calls left the previous
/// meeting's documents and notes sitting beside the new transcript — and the
/// outgoing call was replaced without being saved, losing whatever had changed
/// since its last write.
@MainActor
@Suite("Session switching")
struct SessionSwitchingTests {

    private func session(title: String,
                         transcript: String,
                         answer: String,
                         prompt: String,
                         files: [ImportedContextFile] = [],
                         notes: String = "",
                         goal: String = "",
                         history: [AIExchange] = [],
                         suggestions: [Suggestion] = []) -> SavedSession {
        SavedSession(
            id: UUID(),
            title: title,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedAt: Date(timeIntervalSince1970: 1_700_000_100),
            goal: goal,
            entries: [TranscriptEntry(source: .mic, text: transcript)],
            aiResponse: answer,
            aiResponsePrompt: prompt,
            aiHistory: history,
            contextFiles: files,
            contextNotes: notes,
            suggestions: suggestions,
            digest: ""
        )
    }

    /// Switching calls now SAVES the outgoing one, so every test here writes.
    /// A temporary store keeps that away from the real meeting history.
    private func idleState() -> AppState {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cruxwing-switch-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(llm: MockLLMGateway(response: "unused"),
                             sessionStore: SessionStore(root: root))
        // restoreSession is blocked mid-recording by design.
        #expect(state.status == .idle)
        return state
    }

    @Test("opening a call replaces the context panel, not just the transcript")
    func switchReplacesContext() {
        let state = idleState()
        state.contextFiles = [ImportedContextFile(name: "Old brief.pdf", text: "old material")]
        state.contextNotes = "notes from the previous call"
        state.callGoal = "old goal"

        state.restoreSession(session(
            title: "Pricing review",
            transcript: "we discussed pricing",
            answer: "Pricing answer",
            prompt: "What did we decide?",
            files: [ImportedContextFile(name: "Pricing deck.pdf", text: "new material")],
            notes: "notes for pricing",
            goal: "agree the price"
        ))

        #expect(state.contextFiles.count == 1)
        #expect(state.contextFiles.first?.name == "Pricing deck.pdf")
        #expect(state.contextNotes == "notes for pricing")
        #expect(state.callGoal == "agree the price")
    }

    @Test("a call saved without context clears the previous call's context")
    func switchClearsStaleContext() {
        // Every session written before context was persisted decodes with none.
        // Leaving the old panel in place would silently ground the new meeting
        // in the previous meeting's documents.
        let state = idleState()
        state.contextFiles = [ImportedContextFile(name: "Old brief.pdf", text: "old material")]
        state.contextNotes = "stale notes"

        state.restoreSession(session(
            title: "Standup", transcript: "quick sync", answer: "", prompt: ""))

        #expect(state.contextFiles.isEmpty)
        #expect(state.contextNotes.isEmpty)
    }

    @Test("opening a call replaces the assistant dialog")
    func switchReplacesDialog() {
        let state = idleState()
        state.restoreSession(session(
            title: "A", transcript: "first call", answer: "First answer", prompt: "First prompt"))
        #expect(state.aiResponse == "First answer")

        state.restoreSession(session(
            title: "B", transcript: "second call", answer: "Second answer", prompt: "Second prompt"))
        #expect(state.aiResponse == "Second answer")
        #expect(state.aiResponsePrompt == "Second prompt")
        #expect(state.transcript.first?.text == "second call")
    }

    @Test("a call with no saved answer clears the previous call's dialog")
    func switchClearsStaleDialog() {
        let state = idleState()
        state.restoreSession(session(
            title: "A", transcript: "first", answer: "First answer", prompt: "First prompt",
            history: [AIExchange(prompt: "earlier", answer: "earlier answer")]))
        #expect(state.aiHistory.count == 1)

        state.restoreSession(session(title: "B", transcript: "second", answer: "", prompt: ""))

        #expect(state.aiResponse.isEmpty)
        #expect(state.aiResponsePrompt.isEmpty)
        // The archived thread belongs to the call it happened in.
        #expect(state.aiHistory.isEmpty)
    }

    @Test("per-call artifacts do not leak into the next call")
    func switchClearsArtifacts() {
        let state = idleState()
        state.transcriptEnhanceNote = "Enhanced with Fireflies"
        state.suggestions = [Suggestion(title: "old risk", detail: "from call A", kind: .risk)]

        state.restoreSession(session(
            title: "B", transcript: "second", answer: "", prompt: ""))

        #expect(state.transcriptEnhanceNote == nil)
        #expect(state.suggestions.isEmpty)
    }

    @Test("context survives a save and reload through the store")
    func contextRoundTripsThroughDisk() throws {
        // The in-memory tests prove restore READS context; this proves the save
        // WRITES it, which is the half that was missing entirely.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cruxwing-roundtrip-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(llm: MockLLMGateway(response: "unused"),
                             sessionStore: store)
        // A restored call is a real meeting, so it is eligible to be saved.
        state.restoreSession(session(
            title: "Pricing", transcript: "we discussed pricing",
            answer: "Answer", prompt: "Prompt"))
        state.contextFiles = [ImportedContextFile(name: "Deck.pdf", text: "slides")]
        state.contextNotes = "call notes"
        state.persistCurrentSession()

        let reloaded = try #require(store.list().first)
        #expect(reloaded.contextFiles?.count == 1)
        #expect(reloaded.contextFiles?.first?.name == "Deck.pdf")
        #expect(reloaded.contextNotes == "call notes")

        // And a fresh workspace loading it gets the panel back.
        let other = AppState(llm: MockLLMGateway(response: "unused"), sessionStore: store)
        other.restoreSession(reloaded)
        #expect(other.contextFiles.first?.name == "Deck.pdf")
        #expect(other.contextNotes == "call notes")
    }

    @Test("switching away saves the outgoing call's context")
    func switchingSavesOutgoingCall() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cruxwing-outgoing-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(llm: MockLLMGateway(response: "unused"), sessionStore: store)
        let callA = session(title: "A", transcript: "first", answer: "A answer", prompt: "A prompt")
        state.restoreSession(callA)
        // Work done in A after it was last written.
        state.contextNotes = "notes typed in A"

        // Opening B must not discard that.
        state.restoreSession(session(title: "B", transcript: "second", answer: "", prompt: ""))
        #expect(state.contextNotes.isEmpty)

        let savedA = try #require(store.list().first { $0.id == callA.id })
        #expect(savedA.contextNotes == "notes typed in A")
    }

    @Test("opening a call brings back the blind spots it produced")
    func switchRestoresBlindSpots() {
        let state = idleState()
        state.restoreSession(session(
            title: "Pricing", transcript: "we discussed pricing", answer: "", prompt: "",
            suggestions: [
                Suggestion(title: "No owner for the migration", detail: "Nobody agreed to run it",
                           kind: .risk, evidence: "we still need someone to own the migration")
            ]))

        #expect(state.suggestions.count == 1)
        #expect(state.suggestions.first?.title == "No owner for the migration")
        // The verified quote travels with it, so the card can show what it is about.
        #expect(state.suggestions.first?.evidence == "we still need someone to own the migration")
    }

    @Test("a call with no blind spots does not inherit the previous call's")
    func switchClearsStaleBlindSpots() {
        let state = idleState()
        state.restoreSession(session(
            title: "A", transcript: "first", answer: "", prompt: "",
            suggestions: [Suggestion(title: "Old risk", detail: "from call A", kind: .risk)]))
        #expect(state.suggestions.count == 1)

        state.restoreSession(session(title: "B", transcript: "second", answer: "", prompt: ""))
        #expect(state.suggestions.isEmpty)
    }

    @Test("blind spots survive a save and reload through the store")
    func blindSpotsRoundTripThroughDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cruxwing-blindspots-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(llm: MockLLMGateway(response: "unused"), sessionStore: store)
        state.restoreSession(session(
            title: "Pricing", transcript: "we discussed pricing", answer: "", prompt: ""))
        state.suggestions = [
            Suggestion(title: "Unowned migration", detail: "Nobody agreed to run it",
                       kind: .risk, evidence: "someone has to own the migration")
        ]
        state.persistCurrentSession()

        let reloaded = try #require(store.list().first)
        #expect(reloaded.suggestions?.count == 1)
        #expect(reloaded.suggestions?.first?.evidence == "someone has to own the migration")
    }

    @Test("sessions saved before blind spots were persisted still decode")
    func oldSessionsDecodeWithoutBlindSpots() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","startedAt":0,"savedAt":0,
         "goal":"","entries":[],"aiResponse":"answer","digest":""}
        """
        let decoded = try JSONDecoder().decode(SavedSession.self, from: Data(json.utf8))
        #expect(decoded.suggestions == nil)
    }

    @Test("sessions saved before context was persisted still decode")
    func oldSessionsDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","startedAt":0,"savedAt":0,
         "goal":"","entries":[],"aiResponse":"answer","digest":""}
        """
        let decoded = try JSONDecoder().decode(SavedSession.self, from: Data(json.utf8))
        #expect(decoded.contextFiles == nil)
        #expect(decoded.contextNotes == nil)
    }
}
