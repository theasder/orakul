import Testing
import Foundation
@testable import MeetGPT

/// M3 session persistence: meetings must survive quit. Round-trip the store in
/// a temp directory with an injectable root.
@Suite("Session store")
struct SessionStoreTests {
    private func makeStore() -> SessionStore {
        SessionStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-tests-\(UUID().uuidString)", isDirectory: true))
    }

    /// ISO8601 persists whole seconds — use second-precision dates so Equatable
    /// round-trips exactly.
    private func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private func sampleSession(title: String, startedAt: Date = Date()) -> SavedSession {
        let now = wholeSeconds(Date())
        return SavedSession(
            id: UUID(), title: title, startedAt: wholeSeconds(startedAt), savedAt: now,
            goal: "close the Q3 renewal",
            entries: [
                TranscriptEntry(source: .mic, text: "we agreed on usage pricing", timestamp: now, speaker: "Sam",
                                transcriptionEngine: .local),
                TranscriptEntry(source: .system, text: "ship before August", timestamp: now, speaker: "Dana",
                                transcriptionEngine: .local),
            ],
            transcriptionEngine: .local,
            aiResponse: "## TL;DR\n- pricing decided",
            aiResponsePrompt: "Summarize the pricing decision.",
            aiResponseExportTitle: "Q3 Pricing Decision",
            digest: "• decided usage pricing")
    }

    @Test("save → list → load round-trips every field")
    func roundTrip() throws {
        let store = makeStore()
        let session = sampleSession(title: "Pricing sync")
        try store.save(session)

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed[0] == session)

        let loaded = store.load(id: session.id)
        #expect(loaded?.entries.count == 2)
        #expect(loaded?.entries[0].speaker == "Sam")
        #expect(loaded?.entries[1].source == .system)
        #expect(loaded?.entries[0].transcriptionEngine == .local)
        #expect(loaded?.transcriptionEngine == .local)
        #expect(loaded?.digest == "• decided usage pricing")
        #expect(loaded?.aiResponsePrompt == "Summarize the pricing decision.")
        #expect(loaded?.aiResponseExportTitle == "Q3 Pricing Decision")
    }

    @Test("sessions saved before DOCX provenance still decode")
    func legacySessionCompatibility() throws {
        let store = makeStore()
        let session = sampleSession(title: "Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        object.removeValue(forKey: "aiResponsePrompt")
        object.removeValue(forKey: "aiResponseExportTitle")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let url = store.root.appendingPathComponent("\(session.id.uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try #require(store.load(id: session.id))
        #expect(loaded.aiResponse == session.aiResponse)
        #expect(loaded.aiResponsePrompt == nil)
        #expect(loaded.aiResponseExportTitle == nil)
    }

    @Test("list orders newest first; delete removes the file")
    func orderingAndDelete() throws {
        let store = makeStore()
        let older = sampleSession(title: "older", startedAt: Date(timeIntervalSinceNow: -3600))
        let newer = sampleSession(title: "newer")
        try store.save(older)
        try store.save(newer)

        #expect(store.list().map(\.title) == ["newer", "older"])

        store.delete(id: newer.id)
        #expect(store.list().map(\.title) == ["older"])
        #expect(store.load(id: newer.id) == nil)
    }

    @Test("deleteAll removes every saved session (History → Clear all)")
    func clearAll() throws {
        let store = makeStore()
        try store.save(sampleSession(title: "a"))
        try store.save(sampleSession(title: "b"))
        try store.save(sampleSession(title: "c"))
        #expect(store.list().count == 3)

        store.deleteAll()
        #expect(store.list().isEmpty)
    }

    @Test("re-saving the same id overwrites instead of duplicating")
    func overwrite() throws {
        let store = makeStore()
        var session = sampleSession(title: "v1")
        try store.save(session)
        session.aiResponse = "updated after post-call summarize"
        session.title = "v2"
        try store.save(session)

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed[0].title == "v2")
        #expect(listed[0].aiResponse.contains("updated"))
    }

    @Test("displayTitle falls back to the date when the title is blank")
    func displayTitle() {
        let untitled = sampleSession(title: "   ")
        #expect(!untitled.displayTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(sampleSession(title: "Named").displayTitle == "Named")
    }
}
