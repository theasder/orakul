import Foundation
import Testing
@testable import MeetGPT

// Every saved session on every user's disk was written by an OLDER build than
// the one reading it. The models say so repeatedly in their own comments:
//
//   "a non-optional property with a default is ignored by Codable's
//    synthesized init — adding one silently fails to decode every session
//    recorded before it existed, taking the whole session with it"
//
// Nothing enforced it. Round-tripping through the current code proves only that
// today can read today; it cannot catch a field added this morning that rejects
// a file written last year. These decode the OLDEST shapes by hand, so the day
// someone adds a required field this fails — instead of a user's history
// quietly disappearing.

@Suite("Sessions written by older builds still decode")
struct LegacySessionDecodeTests {
    /// Configured like `SessionStore`'s, because a fixture the store itself
    /// cannot read proves nothing. Dates on disk are ISO-8601 strings; under
    /// the default strategy these fixtures would decode a *number* of seconds
    /// — a shape no build has ever written — and the suite would pass while
    /// the real reader rejected the very same file.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    /// A scratch store, so the session cases go through the real reader rather
    /// than a decoder assembled here to resemble it.
    private func scratchStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("cruxwing-legacy-decode/\(UUID().uuidString)",
                                    isDirectory: true))
    }

    @Test("the oldest session shape survives")
    func oldestSessionDecodes() throws {
        // Only fields that have existed since the first release. Everything
        // added later must be optional, or this file is unreadable.
        let session = try decode(SavedSession.self, """
        {
          "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
          "title": "Weekly planning",
          "startedAt": "2024-05-01T09:00:00Z",
          "savedAt": "2024-05-01T10:00:00Z",
          "goal": "Decide the launch date",
          "entries": [],
          "aiResponse": "",
          "digest": ""
        }
        """)
        #expect(session.title == "Weekly planning")
        #expect(session.aiHistory == nil)
        #expect(session.suggestions == nil)
        #expect(session.recordingContext == nil)
    }

    @Test("a session from before the dialog history decodes with its single answer")
    func preHistorySessionDecodes() throws {
        let session = try decode(SavedSession.self, """
        {
          "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
          "title": "Retro",
          "startedAt": "2024-05-01T09:00:00Z",
          "savedAt": "2024-05-01T10:00:00Z",
          "goal": "",
          "entries": [
            {"id": "1C4A2E80-0000-4000-8000-000000000001",
             "source": "system", "text": "We shipped late.", "timestamp": "2024-05-01T09:01:00Z"}
          ],
          "aiResponse": "The release slipped by a week.",
          "digest": ""
        }
        """)
        #expect(session.entries.count == 1)
        #expect(session.aiResponse == "The release slipped by a week.")
    }

    @Test("an exchange from before actions, feedback and status decodes")
    func oldestExchangeDecodes() throws {
        // status is INFERRED when absent — an old answer that looks complete
        // must not be archived as cancelled, or it vanishes from the dialog.
        let exchange = try decode(AIExchange.self, """
        {
          "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
          "prompt": "Summarize",
          "answer": "We decided to ship on the 22nd.",
          "at": "2024-05-01T09:00:00Z"
        }
        """)
        #expect(exchange.status == .succeeded)
        #expect(exchange.answerActions.isEmpty)
        #expect(exchange.followUpPrompts.isEmpty)
        #expect(exchange.feedback == nil)
    }

    @Test("an old empty answer is not resurrected as a successful one")
    func emptyLegacyAnswerIsCancelled() throws {
        let exchange = try decode(AIExchange.self, """
        {"id": "6B29FC40-CA47-1067-B31D-00DD010662DA", "prompt": "p",
         "answer": "   ", "at": "2024-05-01T09:00:00Z"}
        """)
        #expect(exchange.status == .cancelled)
    }

    @Test("an old error answer stays a failure")
    func legacyErrorAnswerIsFailed() throws {
        let exchange = try decode(AIExchange.self, """
        {"id": "6B29FC40-CA47-1067-B31D-00DD010662DA", "prompt": "p",
         "answer": "Error: provider timed out", "at": "2024-05-01T09:00:00Z"}
        """)
        #expect(exchange.status == .failed)
    }

    @Test("a blind spot from before evidence and hunches decodes")
    func oldestSuggestionDecodes() throws {
        // Suggestion has no custom decoder, so every field added after the
        // first release has to be Optional. This is what proves it.
        let suggestion = try decode(Suggestion.self, """
        {
          "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
          "title": "Nobody named an owner",
          "detail": "The budget has no owner.",
          "kind": "question"
        }
        """)
        #expect(suggestion.evidence == nil)
        #expect(suggestion.claim == nil)
        #expect(!suggestion.isTestableHypothesis)
    }

    @Test("a recording type retired from the app still decodes")
    func retiredRecordingTypeDecodes() throws {
        // `.video` was removed as a preset but kept in the persisted enum. A
        // session pinned to it must open, and resolve to something sane.
        let selection = try decode(RecordingContextSelection.self, """
        {"mode": "video"}
        """)
        #expect(selection.mode == .video)
        #expect(selection.resolvedKind(detected: .meeting) == .lecture)
    }

    @Test("a session carrying every later addition still decodes")
    func fullyPopulatedSessionDecodes() throws {
        // The other direction: today's writer must produce something today's
        // reader accepts, including the most recent fields. Written and read
        // through the store, so the encoder and decoder are the ones that
        // actually face the disk rather than a matched pair set up here.
        let store = scratchStore()
        let original = SavedSession(
            id: UUID(), title: "Full", startedAt: Date(), savedAt: Date(),
            goal: "g",
            recordingContext: RecordingContextSelection(mode: .lecture),
            entries: [TranscriptEntry(source: .mic, text: "hello")],
            aiResponse: "answer",
            aiHistory: [AIExchange(prompt: "p", answer: "a",
                                   feedback: AnswerFeedback(rating: .helpful))],
            digest: "d")
        try store.save(original)
        let restored = try #require(store.load(id: original.id))

        #expect(restored.title == "Full")
        #expect(restored.aiHistory?.first?.feedback?.isHelpful == true)
        #expect(restored.recordingContext?.mode == .lecture)
    }

    @Test("the store itself reads an old file, not just a decoder built to match")
    func storeReadsTheOldestFileFromDisk() throws {
        // The cases above decode fixtures directly, which only proves the
        // fixtures match the decoder written beside them — the two can drift
        // together and stay green. This puts an old file on disk under the
        // real filename convention and asks the store for it, so the store's
        // own configuration is what is under test.
        //
        // `list()` and `load(id:)` both swallow failure by design (a corrupt
        // file must not take the History window with it), so a mismatch here
        // surfaces as an empty list, never as an error.
        let store = scratchStore()
        let id = try #require(UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA"))
        try FileManager.default.createDirectory(at: store.root,
                                                withIntermediateDirectories: true)
        try """
        {
          "id": "\(id.uuidString)",
          "title": "Weekly planning",
          "startedAt": "2024-05-01T09:00:00Z",
          "savedAt": "2024-05-01T10:00:00Z",
          "goal": "Decide the launch date",
          "entries": [],
          "aiResponse": "",
          "digest": ""
        }
        """.write(to: store.root.appendingPathComponent("\(id.uuidString).json"),
                  atomically: true, encoding: .utf8)

        #expect(store.list().count == 1)
        #expect(store.load(id: id)?.title == "Weekly planning")
    }

    @Test("a file with the wrong date format is silently unreadable")
    func numericDatesAreNotReadable() throws {
        // The counterweight to the test above: without this, a fixture whose
        // dates the store cannot parse would leave `list()` empty and every
        // assertion about "an old file loads" would be provable by writing no
        // file at all. Seconds-since-reference is the shape those fixtures had
        // before, and it costs a whole session — not one field.
        let store = scratchStore()
        let id = try #require(UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA"))
        try FileManager.default.createDirectory(at: store.root,
                                                withIntermediateDirectories: true)
        try """
        {
          "id": "\(id.uuidString)", "title": "Weekly planning",
          "startedAt": 750000000, "savedAt": 750003600, "goal": "",
          "entries": [], "aiResponse": "", "digest": ""
        }
        """.write(to: store.root.appendingPathComponent("\(id.uuidString).json"),
                  atomically: true, encoding: .utf8)

        #expect(store.list().isEmpty)
        #expect(store.load(id: id) == nil)
    }
}
