import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MeetGPT

/// Real character-level transcript selection.
///
/// The renderer owns the hard part: an `NSTextView` hands back a character
/// range and nothing else, so without a map from range to entry a selection is
/// anonymous text the model cannot attribute. These cover that mapping, and the
/// rule that a partial highlight is quoted partially — quoting the whole
/// utterance when someone highlighted six words puts words in their mouth.
@Suite("Transcript text selection")
struct TranscriptTextSelectionTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entries() -> [TranscriptEntry] {
        [
            TranscriptEntry(source: .mic, text: "We should ship the connector first.",
                            timestamp: base, speaker: "Ana"),
            TranscriptEntry(source: .system, text: "Pricing has to land before that.",
                            timestamp: base.addingTimeInterval(30), speaker: "Bo"),
            TranscriptEntry(source: .mic, text: "Fine, pricing first.",
                            timestamp: base.addingTimeInterval(60), speaker: "Ana")
        ]
    }

    private func render(_ entries: [TranscriptEntry],
                        provisional: [ProvisionalLine] = []) -> TranscriptTextRenderer.Rendered {
        TranscriptTextRenderer.render(entries: entries, provisional: provisional, appearance: nil)
    }

    @Test("every entry's body text is indexed to a range")
    func indexesBodies() {
        let entries = entries()
        let rendered = render(entries)

        #expect(rendered.segments.count == 3)
        let text = rendered.attributed.string as NSString
        for (segment, entry) in zip(rendered.segments, entries) {
            #expect(segment.entryID == entry.id)
            #expect(text.substring(with: segment.bodyRange) == entry.text)
        }
    }

    // Reported from a real call: "duplicating speaker name all the time".
    // Streaming finalizes an utterance every few seconds, so one person
    // talking for a minute became a stack of entries each with its own
    // "HH:mm:ss Speaker A" gutter.

    @Test("consecutive lines from one speaker share a single gutter")
    func coalescesConsecutiveSameSpeaker() {
        let burst = [
            TranscriptEntry(source: .system, text: "We reviewed the funnel.",
                            timestamp: base, speaker: "Speaker A"),
            TranscriptEntry(source: .system, text: "Conversion held at four percent.",
                            timestamp: base.addingTimeInterval(6), speaker: "Speaker A"),
            TranscriptEntry(source: .system, text: "Churn is the real story.",
                            timestamp: base.addingTimeInterval(12), speaker: "Speaker A")
        ]
        let rendered = render(burst)
        // One label for the run — not three.
        #expect(rendered.attributed.string.components(separatedBy: "Speaker A").count - 1 == 1)
        // Attribution is untouched: every entry keeps its own indexed range.
        #expect(rendered.segments.count == 3)
        let text = rendered.attributed.string as NSString
        for (segment, entry) in zip(rendered.segments, burst) {
            #expect(text.substring(with: segment.bodyRange) == entry.text)
            #expect(segment.speaker == "Speaker A")
        }
    }

    @Test("a mic echo crumb between meeting entries is rendered out, not made a turn")
    func crossTrackEchoSuppressed() {
        // From a real call: the mic hears the room's speakers, so fragments
        // of the meeting audio land on the mic track seconds later and every
        // one of them used to start a fresh "paragraph".
        let echoed = [
            TranscriptEntry(source: .system, text: "переходный период, до того момента, как он вернет.",
                            timestamp: base, speaker: nil),
            TranscriptEntry(source: .mic, text: "вернется",
                            timestamp: base.addingTimeInterval(2), speaker: nil),
            TranscriptEntry(source: .system, text: "и вы там все уже мощно передадите.",
                            timestamp: base.addingTimeInterval(3), speaker: nil)
        ]
        let rendered = render(echoed)
        #expect(!rendered.segments.contains { $0.text == "вернется" },
                "the echo crumb must not be rendered")
        #expect(rendered.segments.count == 2)

        // A substantial reply on the other track is a real turn and stays.
        let realTurn = [
            echoed[0],
            TranscriptEntry(source: .mic, text: "Я не согласен, давайте обсудим сроки отдельно.",
                            timestamp: base.addingTimeInterval(2), speaker: nil),
            echoed[2]
        ]
        #expect(render(realTurn).segments.count == 3)

        // Cross-track evidence is required: a short line between SAME-track
        // neighbours is speech, however short.
        let sameTrack = echoed.map {
            TranscriptEntry(source: .system, text: $0.text, timestamp: $0.timestamp, speaker: nil)
        }
        #expect(render(sameTrack).segments.count == 3)
    }

    @Test("one speaking turn reads as one flowing paragraph, like dialogue in a book")
    func turnFlowsAsOneParagraph() {
        // Reported: "transcript shows phrases by paragraph all the time".
        // Coalescing the gutter was not enough — every six-second chunk still
        // sat on its own line inside the block.
        let burst = [
            TranscriptEntry(source: .system, text: "We reviewed the funnel.",
                            timestamp: base, speaker: "Speaker A"),
            TranscriptEntry(source: .system, text: "Conversion held at four percent.",
                            timestamp: base.addingTimeInterval(6), speaker: "Speaker A"),
            TranscriptEntry(source: .system, text: "Churn is the real story.",
                            timestamp: base.addingTimeInterval(12), speaker: "Speaker A")
        ]
        let rendered = render(burst)
        #expect(rendered.attributed.string.contains(
            "We reviewed the funnel. Conversion held at four percent. Churn is the real story."),
            "chunks of one turn must join with spaces, not line breaks")
        // A speaker change still breaks the paragraph.
        let dialogue = burst + [
            TranscriptEntry(source: .system, text: "Disagree.",
                            timestamp: base.addingTimeInterval(18), speaker: "Speaker B")
        ]
        let text = render(dialogue).attributed.string
        #expect(text.contains("story.\n\n"), "a new voice starts a new paragraph")
    }

    @Test("a speaker change, a source change, or a long pause starts a new gutter")
    func gutterBreaksOnChangeOrPause() {
        let lines = [
            TranscriptEntry(source: .system, text: "First point.",
                            timestamp: base, speaker: "Speaker A"),
            TranscriptEntry(source: .system, text: "Reply.",
                            timestamp: base.addingTimeInterval(5), speaker: "Speaker B"),
            TranscriptEntry(source: .system, text: "Back again.",
                            timestamp: base.addingTimeInterval(10), speaker: "Speaker A"),
            // Same speaker but far later — visually a new moment in the call.
            TranscriptEntry(source: .system, text: "Much later thought.",
                            timestamp: base.addingTimeInterval(10 + 120), speaker: "Speaker A")
        ]
        let rendered = render(lines)
        let text = rendered.attributed.string
        #expect(text.components(separatedBy: "Speaker A").count - 1 == 3)
        #expect(text.components(separatedBy: "Speaker B").count - 1 == 1)
    }

    // Reported: the same sentence visible twice while being spoken — the mic
    // hears the meeting audio too, so both tracks carry a provisional copy.

    @Test("a mic provisional echoing the system provisional is not rendered twice")
    func hidesEchoedProvisional() {
        let lines = [
            ProvisionalLine(source: .system, text: "we can ship the migration on friday"),
            ProvisionalLine(source: .mic, text: "we can ship the migration on friday")
        ]
        let kept = TranscriptDeduplicator.withoutEchoedProvisionals(lines)
        #expect(kept.count == 1)
        #expect(kept.first?.source == .system)

        // Two genuinely different in-progress sentences both stay.
        let distinct = [
            ProvisionalLine(source: .system, text: "we can ship the migration on friday"),
            ProvisionalLine(source: .mic, text: "what does the rollback plan look like")
        ]
        #expect(TranscriptDeduplicator.withoutEchoedProvisionals(distinct).count == 2)
    }

    @Test("the gutter is excluded, so a selection maps to what was said")
    func gutterIsNotIndexed() {
        let rendered = render(entries())
        let text = rendered.attributed.string as NSString
        // The timestamp and speaker precede the first body range and are not
        // part of it — selecting the first character of the body must not pick
        // up "09:33:20  Ana".
        let firstBody = rendered.segments[0].bodyRange
        #expect(firstBody.location > 0)
        #expect(!text.substring(with: firstBody).contains("Ana"))
    }

    @Test("a partial highlight quotes only the highlighted words")
    func quotesPartialSelection() {
        let rendered = render(entries())
        let body = rendered.segments[0].bodyRange
        // Highlight "should ship" out of "We should ship the connector first."
        let partial = NSRange(location: body.location + 3, length: 11)

        let quote = TranscriptTextRenderer.quote(
            for: partial, in: rendered.segments, fullText: rendered.attributed.string)

        #expect(quote.contains("should ship"))
        #expect(!quote.contains("connector"))
        #expect(quote.contains("Ana"))
    }

    @Test("a selection spanning several utterances attributes each one")
    func quotesAcrossEntries() {
        let rendered = render(entries())
        let first = rendered.segments[0].bodyRange
        let second = rendered.segments[1].bodyRange
        let across = NSRange(location: first.location,
                             length: NSMaxRange(second) - first.location)

        let quote = TranscriptTextRenderer.quote(
            for: across, in: rendered.segments, fullText: rendered.attributed.string)
        let lines = quote.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].contains("Ana"))
        #expect(lines[1].contains("Bo"))
        #expect(lines[1].contains("Pricing has to land"))
    }

    @Test("quotes carry a timestamp so the model can place them")
    func quoteCarriesTimestamp() {
        let rendered = render(entries())
        let quote = TranscriptTextRenderer.quote(
            for: rendered.segments[0].bodyRange,
            in: rendered.segments,
            fullText: rendered.attributed.string)
        #expect(quote.hasPrefix("["))
        #expect(quote.contains("]"))
    }

    @Test("an empty selection quotes nothing")
    func emptySelection() {
        let rendered = render(entries())
        let quote = TranscriptTextRenderer.quote(
            for: NSRange(location: 0, length: 0),
            in: rendered.segments,
            fullText: rendered.attributed.string)
        #expect(quote.isEmpty)
    }

    @Test("undiarized lines fall back to the side that spoke")
    func fallsBackToSideLabel() {
        let entries = [
            TranscriptEntry(source: .mic, text: "mine", timestamp: base),
            TranscriptEntry(source: .system, text: "theirs", timestamp: base.addingTimeInterval(5))
        ]
        let rendered = render(entries)
        #expect(rendered.segments[0].speaker == "Вы")
        #expect(rendered.segments[1].speaker == "Собеседник")
    }

    @Test("in-progress speech is rendered but never quotable")
    func provisionalIsNotIndexed() {
        let rendered = render(entries(), provisional: [
            ProvisionalLine(source: .mic, text: "and one more thing")
        ])
        // It is visible…
        #expect(rendered.attributed.string.contains("and one more thing"))
        // …but not indexed, because it has no stable id and is about to be
        // replaced by a finalized entry.
        #expect(rendered.segments.count == 3)
    }
}

/// The AppState half: what the view reports and what "ask about this" does.
@MainActor
@Suite("Ask about a transcript selection")
struct AskAboutSelectionTests {

    private func state() -> AppState {
        AppState(llm: MockLLMGateway(response: "unused"))
    }

    @Test("reporting a selection makes the ask affordance available")
    func reportsSelection() {
        let state = state()
        #expect(!state.hasTranscriptSelection)

        state.updateTranscriptSelection("[09:33:20] Ana: ship the connector")
        #expect(state.hasTranscriptSelection)

        state.clearTranscriptSelection()
        #expect(!state.hasTranscriptSelection)
    }

    @Test("whitespace-only selections do not count as a selection")
    func ignoresWhitespaceSelection() {
        let state = state()
        state.updateTranscriptSelection("   \n ")
        #expect(!state.hasTranscriptSelection)
    }

    @Test("asking loads the quote into the composer without sending it")
    func loadsComposerDraft() {
        let state = state()
        state.updateTranscriptSelection("[09:33:20] Ana: ship the connector")
        state.askAboutTranscriptSelection()

        let draft = state.composerDraft
        #expect(draft?.contains("ship the connector") == true)
        #expect(draft?.contains("About this part of the call") == true)
        // The question is the user's half — auto-sending would invent it.
        #expect(state.aiResponse.isEmpty)
        #expect(!state.aiStreaming)
    }

    @Test("asking with nothing selected does nothing")
    func noSelectionNoDraft() {
        let state = state()
        state.askAboutTranscriptSelection()
        #expect(state.composerDraft == nil)
    }
}

/// Dictation now works DURING a recording by taking a window of the live
/// transcript — both sources — rather than opening a second capture that would
/// fight the meeting's input node.
@MainActor
@Suite("Prompt dictation")
struct PromptDictationTests {

    private func recordingState() -> AppState {
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        state.status = .recording
        return state
    }

    @Test("starts idle")
    func startsIdle() {
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        #expect(state.dictation.state == .idle)
        #expect(!state.isDictating)
    }

    @Test("during a recording the first press opens a capture window")
    func opensWindowWhileRecording() async {
        let state = recordingState()
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })

        await state.toggleDictation(into: binding)
        #expect(state.dictationWindowStart != nil)
        #expect(state.isDictating)
        // No second microphone capture is opened.
        #expect(!state.dictation.isListening)
    }

    @Test("the second press takes what was said in the window, from both sides")
    func capturesWindowFromBothSources() async {
        let state = recordingState()
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })

        await state.toggleDictation(into: binding)
        let start = try? #require(state.dictationWindowStart)

        // Something said before the window must not be picked up; the other
        // side's speech inside it must be.
        state.transcript = [
            TranscriptEntry(source: .mic, text: "earlier chatter",
                            timestamp: (start ?? Date()).addingTimeInterval(-60)),
            TranscriptEntry(source: .system, text: "what is our refund policy",
                            timestamp: (start ?? Date()).addingTimeInterval(1))
        ]

        await state.toggleDictation(into: binding)

        #expect(state.dictationWindowStart == nil)
        #expect(text.contains("what is our refund policy"))
        #expect(!text.contains("earlier chatter"))
    }

    @Test("an empty window reports rather than silently doing nothing")
    func emptyWindowReports() async {
        let state = recordingState()
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })

        await state.toggleDictation(into: binding)
        await state.toggleDictation(into: binding)

        #expect(text.isEmpty)
        #expect(state.lastError != nil)
    }

    @Test("captured speech appends to what is already typed")
    func appendsToExistingText() async {
        let state = recordingState()
        var text = "Draft a reply to"
        let binding = Binding(get: { text }, set: { text = $0 })

        await state.toggleDictation(into: binding)
        let start = try? #require(state.dictationWindowStart)
        state.transcript = [
            TranscriptEntry(source: .system, text: "their pricing objection",
                            timestamp: (start ?? Date()).addingTimeInterval(1))
        ]
        await state.toggleDictation(into: binding)

        #expect(text == "Draft a reply to their pricing objection")
    }

    @Test("cancelling an idle dictation is harmless")
    func cancelIdle() {
        let dictation = PromptDictation(transcriber: StubTranscriber(text: "unused"))
        dictation.cancel()
        #expect(dictation.state == .idle)
        #expect(dictation.level == 0)
    }

    @Test("stopping without having started returns nothing")
    func stopWithoutStart() async {
        let dictation = PromptDictation(transcriber: StubTranscriber(text: "hello"))
        let result = await dictation.stopAndTranscribe()
        #expect(result == nil)
        #expect(dictation.state == .idle)
    }
}

/// Minimal transcriber so dictation state can be exercised without audio
/// hardware or a network.
private final class StubTranscriber: TranscriptionService, @unchecked Sendable {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(wav: Data) async throws -> String { text }
}
