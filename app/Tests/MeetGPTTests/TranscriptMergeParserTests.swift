import Foundation
import Testing
@testable import MeetGPT

/// The Fireflies merge asks the model for a whole reconciled transcript as
/// JSON — the longest output the app requests. Strict whole-document parsing
/// threw away everything whenever any part of it was malformed, which is how
/// "Couldn't merge the transcripts" became the normal outcome.
@Suite("Transcript merge parser")
struct TranscriptMergeParserTests {

    @Test("reads a well-formed merge")
    func readsWellFormed() {
        let raw = """
        {"summary":"Cleaned names and timings.","entries":[\
        {"offsetSec":0.0,"speaker":"Artem","source":"mic","text":"Let's start."},\
        {"offsetSec":12.5,"speaker":"Dana","source":"system","text":"Agreed."}]}
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.summary == "Cleaned names and timings.")
        #expect(parsed.items.count == 2)
        #expect(parsed.isTruncated == false)
        #expect(parsed.items.first?.speaker == "Artem")
    }

    @Test("survives a missing comma between summary and entries")
    func survivesMissingSeparator() {
        // Observed verbatim in production: the model omitted the comma between
        // the two top-level members. Strict JSON rejects the whole document.
        let raw = """
        {"summary":"Сверены решения по каналам." "entries":[\
        {"offsetSec":2163.0,"speaker":"Artem Dremov","source":"mic","text":"Готово."}]}
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.summary == "Сверены решения по каналам.")
        #expect(parsed.items.count == 1)
        #expect(parsed.items.first?.text == "Готово.")
    }

    @Test("keeps every complete entry before a truncation and flags it")
    func salvagesTruncatedOutput() {
        // Output budget ran out mid-object: two entries finished, the third did
        // not, and the array never closed.
        let raw = """
        {"summary":"Merged.","entries":[\
        {"offsetSec":0.0,"speaker":"A","source":"mic","text":"one"},\
        {"offsetSec":5.0,"speaker":"B","source":"system","text":"two"},\
        {"offsetSec":9.0,"speaker":"B","sour
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.summary == "Merged.")
        #expect(parsed.items.count == 2)
        // The flag is what stops a partial merge from replacing the transcript.
        #expect(parsed.isTruncated == true)
    }

    @Test("recovers the summary even when no entry survives")
    func summarySurvivesAlone() {
        let raw = #"{"summary":"Reconciled decisions and names.","entries":[{"offsetSe"#
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.summary == "Reconciled decisions and names.")
        #expect(parsed.items.isEmpty)
        #expect(parsed.isTruncated == true)
    }

    @Test("a brace inside an utterance does not end the object")
    func braceInsideTextIsSafe() {
        let raw = """
        {"summary":"s","entries":[\
        {"offsetSec":1.0,"speaker":"A","source":"mic","text":"use {curly} braces"},\
        {"offsetSec":2.0,"speaker":"B","source":"mic","text":"ok"}]}
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.items.count == 2)
        #expect(parsed.items.first?.text == "use {curly} braces")
    }

    @Test("an escaped quote inside text does not end the object")
    func escapedQuoteIsSafe() {
        let raw = #"{"summary":"s","entries":[{"offsetSec":1.0,"speaker":"A","source":"mic","text":"he said \"go\" then left"}]}"#
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.items.count == 1)
        #expect(parsed.items.first?.text == #"he said "go" then left"#)
    }

    @Test("one malformed entry costs only itself")
    func skipsOnlyTheBadEntry() {
        let raw = """
        {"summary":"s","entries":[\
        {"offsetSec":1.0,"speaker":"A","source":"mic","text":"good"},\
        {"offsetSec":"not-a-number","speaker":"B","source":"mic","text":"bad"},\
        {"offsetSec":3.0,"speaker":"C","source":"mic","text":"also good"}]}
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.items.count == 2)
        #expect(parsed.isTruncated == false)
    }

    @Test("prose around the JSON is ignored")
    func ignoresSurroundingProse() {
        let raw = """
        Here is the merged transcript:
        {"summary":"s","entries":[{"offsetSec":1.0,"speaker":"A","source":"mic","text":"hi"}]}
        """
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.items.count == 1)
        #expect(parsed.summary == "s")
    }

    @Test("unicode escapes in the summary are decoded")
    func decodesEscapes() {
        let raw = #"{"summary":"line\nbreak and \"quotes\"","entries":[]}"#
        let parsed = TranscriptMergeParser.parse(raw)
        #expect(parsed.summary == "line\nbreak and \"quotes\"")
    }

    @Test("junk yields nothing rather than crashing")
    func handlesJunk() {
        #expect(TranscriptMergeParser.parse("").items.isEmpty)
        #expect(TranscriptMergeParser.parse("not json at all").summary == nil)
        #expect(TranscriptMergeParser.parse("{}").items.isEmpty)
    }
}

@Suite("Output token budget")
struct OutputTokenBudgetTests {
    @Test("nil keeps the ordinary answer budget")
    func nilIsStandard() {
        #expect(OutputTokenBudget.clamp(nil) == OutputTokenBudget.standard)
    }

    @Test("a request is clamped into range, never unbounded")
    func clampsRange() {
        #expect(OutputTokenBudget.clamp(1_000_000) == OutputTokenBudget.maximum)
        #expect(OutputTokenBudget.clamp(1) == OutputTokenBudget.minimum)
        #expect(OutputTokenBudget.clamp(4_000) == 4_000)
    }

    @Test("the merge budget is well above the default it replaced")
    func mergeBudgetIsBigger() {
        // The whole point: the standard budget cannot hold a reconciled
        // transcript.
        #expect(OutputTokenBudget.maximum >= OutputTokenBudget.standard * 3)
    }

    @Test("an ordinary answer's budget holds a structured answer to the end")
    func standardHoldsAStructuredAnswer() {
        // Reported from a real call: "answer to prompt button wasn't printed
        // till the end". The old 1200-token ceiling clips a digest with tables
        // and task lists mid-sentence — the stream just stops, which reads as
        // a rendering bug rather than the cost lever it is.
        #expect(OutputTokenBudget.standard >= 2_048)
        // Still a bounded ceiling, not an open one.
        #expect(OutputTokenBudget.standard < OutputTokenBudget.maximum)
    }
}
