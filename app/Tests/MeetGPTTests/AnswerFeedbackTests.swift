import Foundation
import Testing
@testable import MeetGPT

/// Rating an answer.
///
/// The value of this data is entirely in its being attached to the evidence:
/// the transcript, prompt and answer that earned the verdict are in the same
/// file. A rating that survives but loses its exchange, or an exchange that
/// stops decoding because a rating was added, are both worse than no feature.
@Suite("Answer feedback")
struct AnswerFeedbackTests {

    @Test("a whitespace-only note is stored as no note")
    func blankNoteIsAbsent() {
        // An empty text field must not persist as a note that says nothing,
        // or every unrated answer grows a meaningless record.
        #expect(AnswerFeedback(rating: .helpful, note: "   \n ").note == nil)
        #expect(AnswerFeedback(rating: .helpful, note: "").note == nil)
        #expect(AnswerFeedback(rating: .helpful, note: nil).note == nil)
    }

    @Test("a note is trimmed and bounded")
    func noteIsBounded() {
        #expect(AnswerFeedback(rating: .unhelpful, note: "  it invented a date  ").note
                == "it invented a date")

        let huge = String(repeating: "x", count: AnswerFeedback.maximumNoteLength + 500)
        let stored = AnswerFeedback(rating: .unhelpful, note: huge).note
        #expect(stored?.count == AnswerFeedback.maximumNoteLength)
    }

    @Test("feedback round-trips through the exchange")
    func roundTripsThroughExchange() throws {
        let exchange = AIExchange(
            prompt: "What did we decide?",
            answer: "The launch moves to September.",
            feedback: AnswerFeedback(rating: .unhelpful, note: "missed the DPA risk"))

        let data = try JSONEncoder().encode(exchange)
        let restored = try JSONDecoder().decode(AIExchange.self, from: data)

        #expect(restored.feedback?.rating == .unhelpful)
        #expect(restored.feedback?.note == "missed the DPA risk")
    }

    @Test("an exchange saved before feedback existed still decodes")
    func legacyExchangeStillDecodes() throws {
        // The whole archive is in one file. Requiring this key would reject
        // every session ever saved, taking its transcript with it.
        let legacy = """
        {"id":"\(UUID().uuidString)","prompt":"p","answer":"a",
         "at":\(Date().timeIntervalSinceReferenceDate)}
        """
        let restored = try JSONDecoder().decode(AIExchange.self, from: Data(legacy.utf8))

        #expect(restored.feedback == nil)
        #expect(restored.answer == "a")
    }

    @Test("an unrated answer carries no feedback")
    func unratedIsNil() {
        #expect(AIExchange(prompt: "p", answer: "a").feedback == nil)
    }

    @MainActor
    @Test("rating an archived answer stores it against that exchange")
    func recordsAgainstExchange() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(history: [AIExchange(prompt: "first", answer: "one"),
                                           AIExchange(prompt: "second", answer: "two")])
        let target = try #require(state.aiHistory.first { $0.prompt == "second" })

        state.recordAnswerFeedback(AnswerFeedback(rating: .helpful), forExchange: target.id)

        #expect(state.aiHistory.first { $0.prompt == "second" }?.feedback?.rating == .helpful)
        // The other answer must be untouched: feedback that lands on the wrong
        // turn is worse than none, because it reads as a judgement of it.
        #expect(state.aiHistory.first { $0.prompt == "first" }?.feedback == nil)
    }

    @MainActor
    @Test("re-rating replaces rather than appends")
    func reRatingReplaces() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(history: [AIExchange(prompt: "p", answer: "a")])
        let id = try #require(state.aiHistory.first?.id)

        state.recordAnswerFeedback(AnswerFeedback(rating: .helpful), forExchange: id)
        state.recordAnswerFeedback(AnswerFeedback(rating: .unhelpful, note: "wrong owner"),
                                   forExchange: id)

        #expect(state.aiHistory.first?.feedback?.rating == .unhelpful)
        #expect(state.aiHistory.first?.feedback?.note == "wrong owner")
        #expect(state.answerFeedbackSoFar.count == 1)
    }

    @MainActor
    @Test("clearing a rating removes it")
    func clearingRemoves() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(history: [AIExchange(prompt: "p", answer: "a")])
        let id = try #require(state.aiHistory.first?.id)

        state.recordAnswerFeedback(AnswerFeedback(rating: .helpful), forExchange: id)
        state.recordAnswerFeedback(nil, forExchange: id)

        // A mis-click has to be undoable, or the stored opinion is not the
        // user's.
        #expect(state.aiHistory.first?.feedback == nil)
        #expect(state.answerFeedbackSoFar.isEmpty)
    }

    @MainActor
    @Test("rating an unknown exchange changes nothing")
    func unknownExchangeIsIgnored() {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.applyTestWorkspace(history: [AIExchange(prompt: "p", answer: "a")])

        state.recordAnswerFeedback(AnswerFeedback(rating: .helpful), forExchange: UUID())

        #expect(state.aiHistory.allSatisfy { $0.feedback == nil })
    }
}
