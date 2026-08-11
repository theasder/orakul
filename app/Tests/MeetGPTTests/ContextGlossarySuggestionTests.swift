import Foundation
import Testing
@testable import MeetGPT

/// Mining the glossary from documents the user attached.
///
/// This is the only automatic source that satisfies both conditions the
/// measurements established: the terms are CORRECT (the user wrote or attached
/// them) and they come from OUTSIDE the audio. The two rejected alternatives —
/// the meeting title, and the engine's own first pass — each failed one and
/// made WER worse.
@MainActor
// These tests inject the existing glossary instead of writing
// Config.transcriptionGlossary.
//
// It is one global that several suites read and write. Setting it here broke a
// DIFFERENT suite mid-run, and save/restore did not fix it: restoring happens
// after the test, while the other suite reads DURING it. Injection removes the
// shared state from the test path entirely.
@Suite("Context glossary suggestions", .serialized)
struct ContextGlossarySuggestionTests {


    private func state(files: [ImportedContextFile]) -> AppState {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(contextFiles: files)
        return state
    }

    private let agenda = ImportedContextFile(
        name: "agenda.md",
        text: """
        IETF 125 PCE working group. PCEP extensions for BFD.
        Covers MPLS-TE tunnels, sub-TLV encoding and LSP liveness.
        We should talk about the delivery date before Friday.
        """)

    @Test("proposes the domain vocabulary an attached agenda contains")
    func proposesDomainTerms() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        let terms = state.connectedGlossarySuggestions.map(\.term)
        #expect(terms.contains("PCEP"))
        #expect(terms.contains("MPLS-TE"))
        #expect(terms.contains("sub-TLV"))
        #expect(terms.contains("LSP"))
    }

    @Test("does not propose the ordinary prose in the same document")
    func skipsProse() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        let terms = state.connectedGlossarySuggestions.map { $0.term.lowercased() }
        for noise in ["we", "should", "talk", "about", "the", "delivery", "date", "friday"] {
            #expect(!terms.contains(noise), "proposed \(noise)")
        }
    }

    @Test("every suggestion names the document it came from")
    func suggestionsCiteTheirSource() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        // A suggestion the user cannot account for gets dismissed, and the
        // feature with it.
        let pcep = state.connectedGlossarySuggestions.first { $0.term == "PCEP" }
        #expect(pcep?.sources == ["agenda.md"])
        #expect(pcep?.reason.contains("attached context") == true)
    }

    @Test("does not re-propose terms already in the glossary")
    func skipsExistingTerms() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "PCEP\nMPLS-TE")

        let terms = state.connectedGlossarySuggestions.map(\.term)
        #expect(!terms.contains("PCEP"))
        #expect(!terms.contains("MPLS-TE"))
        #expect(terms.contains("sub-TLV"))
    }

    @Test("running twice does not duplicate a suggestion")
    func isIdempotent() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "")
        let first = state.connectedGlossarySuggestions.count
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        #expect(state.connectedGlossarySuggestions.count == first)
    }

    @Test("no attached documents means no suggestions and no status change")
    func noDocumentsIsQuiet() {
        let state = state(files: [])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        // Silence rather than an empty-state banner: the user attached nothing,
        // which is not a failure to report.
        #expect(state.connectedGlossarySuggestions.isEmpty)
        #expect(state.connectedGlossarySuggestionStatus == .idle)
    }

    @Test("a document with no domain vocabulary proposes nothing")
    func prosaicDocumentProposesNothing() {
        let notes = ImportedContextFile(
            name: "notes.txt",
            text: "we should talk about the delivery date and the open risk before friday")
        let state = state(files: [notes])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        #expect(state.connectedGlossarySuggestions.isEmpty)
    }

    @Test("nothing is written to the glossary without acceptance")
    func nothingAppliedSilently() {
        let state = state(files: [agenda])
        state.refreshContextGlossarySuggestions(existingGlossary: "")

        // The glossary biases every future recording, so it is the user's to
        // change, not a side effect of attaching a file. Asserted on the mined
        // TERM rather than on the whole glossary being empty, because other
        // suites legitimately put their own terms in that global.
        #expect(!Glossary.terms(from: Config.transcriptionGlossary).contains("sub-TLV"))
        #expect(!state.connectedGlossarySuggestions.isEmpty)
    }
    @Test("importing a document proposes its vocabulary without being asked")
    func importTriggersSuggestions() async throws {
        // The previous tests prove the miner works when CALLED. This proves it
        // is called — the method existed for a commit while nothing in
        // production invoked it, which made the whole feature inert.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glossary-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("agenda.txt")
        try """
        IETF 125 PCE working group. PCEP extensions for BFD.
        Covers MPLS-TE tunnels and sub-TLV encoding.
        """.write(to: file, atomically: true, encoding: .utf8)

        let state = AppState(credentialStore: InMemoryKeychain())
        await state.importContext(from: [file])

        let terms = state.connectedGlossarySuggestions.map(\.term)
        #expect(terms.contains("PCEP"), "import did not propose anything: \(terms)")
        #expect(terms.contains("MPLS-TE"))
        // Still proposals — importing a file must not silently change how every
        // future recording is transcribed.
        #expect(!Glossary.terms(from: Config.transcriptionGlossary).contains("MPLS-TE"))
    }

    // MARK: - Connected apps

    private func snippet(_ server: String, _ text: String) -> GroundingSnippet {
        GroundingSnippet(serverName: server, toolName: "search", text: text,
                         sourceID: "mcp:\(server.lowercased())")
    }

    @Test("mines connected-app data the app already fetched")
    func minesConnectedSnippets() {
        // The Settings button spends a research cycle and a model call, so it is
        // manual and in practice never pressed. These snippets were already
        // fetched for an answer, so mining them costs nothing.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromConnectedSnippets([
            snippet("Linear", "CRX-42 blocks the PCEP rollout. Owner: Ada Lovelace."),
            snippet("Notion", "OpenTelemetry spans for the MPLS-TE path are missing."),
        ], existingGlossary: "")

        let terms = state.connectedGlossarySuggestions.map(\.term)
        #expect(terms.contains("PCEP"), "\(terms)")
        #expect(terms.contains("MPLS-TE"), "\(terms)")
        #expect(terms.contains("OpenTelemetry"), "\(terms)")
    }

    @Test("proposes nothing from empty connected data")
    func emptyConnectedIsQuiet() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromConnectedSnippets([], existingGlossary: "")

        #expect(state.connectedGlossarySuggestions.isEmpty)
        #expect(state.connectedGlossarySuggestionStatus == .idle)
    }

    @Test("caps the unranked list so it stays reviewable")
    func capsUnrankedProposals() {
        let state = AppState(credentialStore: InMemoryKeychain())
        let wide = (1...80).map { "TERM\($0) OpenThing\($0)" }.joined(separator: ". ")
        state.proposeGlossaryFromConnectedSnippets([snippet("Notion", wide)], existingGlossary: "")

        // Without the model to order them, a long list is a long list of
        // maybes, and a wall of unsorted suggestions gets dismissed wholesale.
        #expect(state.connectedGlossarySuggestions.count
                <= AppState.unrankedGlossaryProposalLimit)
    }

    @Test("connected mining still never writes the glossary itself")
    func connectedMiningProposesOnly() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromConnectedSnippets([
            snippet("Linear", "CRX-42 blocks the PCEP rollout."),
        ], existingGlossary: "")

        // On the mined TERM, not on the glossary being empty: other suites
        // legitimately put their own terms in that global.
        #expect(!Glossary.terms(from: Config.transcriptionGlossary).contains("PCEP"))
        #expect(!state.connectedGlossarySuggestions.isEmpty)
    }

    // MARK: - Past calls

    private func pastCall(_ lines: [String]) -> SavedSession {
        let start = Date(timeIntervalSince1970: 1_748_736_000)
        return SavedSession(
            id: UUID(),
            title: "Weekly sync",
            startedAt: start,
            savedAt: start,
            goal: "",
            entries: lines.enumerated().map { index, text in
                TranscriptEntry(source: .system, text: text,
                                timestamp: start.addingTimeInterval(Double(index) * 10),
                                speaker: "Ada")
            },
            aiResponse: "",
            digest: "")
    }

    @Test("proposes vocabulary that recurs in an imported past call")
    func minesPastCallTranscript() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromPastTranscript(pastCall([
            "We need the PCEP handshake finished before the MPLS-TE rollout.",
            "PCEP is blocking two teams and the MPLS-TE work depends on it.",
            "Let us revisit PCEP next week once MPLS-TE is unblocked, thanks everyone.",
            "Ada will circulate the notes and we will pick it up at the next sync.",
        ]), existingGlossary: "")

        let terms = state.connectedGlossarySuggestions.map(\.term)
        #expect(terms.contains("PCEP"), "\(terms)")
        #expect(terms.contains("MPLS-TE"), "\(terms)")
    }

    @Test("refuses a term the past transcript said only once")
    func refusesOneOffFromMachineTranscript() {
        // The measured failure this guards: priming on the engine's own output
        // reinforced its corruptions, because "piece" and "cast" look exactly
        // like the acronyms a miner hunts for. A Fireflies transcript is a
        // different engine, but it is still ASR, so a term has to recur.
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromPastTranscript(pastCall([
            "The PCEP handshake is the thing that blocks us, and we should talk about it.",
            "Everything else in the plan is fine and the team is happy with the timeline.",
            "We will pick this up again at the next weekly sync with the whole group.",
        ]), existingGlossary: "")

        #expect(!state.connectedGlossarySuggestions.map(\.term).contains("PCEP"))
    }

    @Test("ignores a transcript too short to judge")
    func ignoresShortTranscript() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromPastTranscript(pastCall(["PCEP. PCEP."]), existingGlossary: "")

        #expect(state.connectedGlossarySuggestions.isEmpty)
    }

    @Test("importing a past call never writes the glossary itself")
    func pastCallProposesOnly() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.proposeGlossaryFromPastTranscript(pastCall([
            "We need the PCEP handshake finished before the MPLS-TE rollout.",
            "PCEP is blocking two teams and the MPLS-TE work depends on it.",
            "Let us revisit PCEP next week once MPLS-TE is unblocked, thanks everyone.",
            "Ada will circulate the notes and we will pick it up at the next sync.",
        ]), existingGlossary: "")

        #expect(!Glossary.terms(from: Config.transcriptionGlossary).contains("PCEP"))
        #expect(!state.connectedGlossarySuggestions.isEmpty)
    }

}
