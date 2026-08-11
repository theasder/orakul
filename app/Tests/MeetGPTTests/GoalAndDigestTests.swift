import Testing
import Foundation
@testable import MeetGPT

/// A3 (goal auto-suggest) and A2 (rolling call digest) — pin the pure logic:
/// suggestion sanitizing, calendar-title filtering, and the digest-aware
/// transcript composition in the prompt builder.
@Suite("Goal suggestion")
struct GoalSuggestionTests {
    @Test("sanitizes model output: strips wrapping, rejects NONE/rambles")
    func sanitize() {
        #expect(GoalSuggestion.sanitizeModelGoal("\"Close the Q3 renewal deal.\"") == "Close the Q3 renewal deal")
        #expect(GoalSuggestion.sanitizeModelGoal("  Align on hiring plan ") == "Align on hiring plan")
        #expect(GoalSuggestion.sanitizeModelGoal("NONE") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal("none.") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal("") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal("Line one\nLine two") == nil)
        #expect(GoalSuggestion.sanitizeModelGoal(String(repeating: "x", count: 120)) == nil)
    }

    @Test("filters generic calendar titles, keeps specific ones")
    func calendarTitles() {
        #expect(GoalSuggestion.isUsableCalendarTitle("Q3 renewal — Acme Corp"))
        #expect(GoalSuggestion.isUsableCalendarTitle("Pricing model review"))
        #expect(!GoalSuggestion.isUsableCalendarTitle("Busy"))
        #expect(!GoalSuggestion.isUsableCalendarTitle("1:1"))
        #expect(!GoalSuggestion.isUsableCalendarTitle("Sync"))
        #expect(!GoalSuggestion.isUsableCalendarTitle("  "))
        #expect(!GoalSuggestion.isUsableCalendarTitle(String(repeating: "t", count: 120)))
    }

    @Test("effective goal prefers typed, then meeting name, then suggestion")
    func resolveEffective() {
        #expect(GoalSuggestion.resolveEffective(
            callGoal: "Close renewal", meetingTitle: "Weekly sync", suggestedGoal: "Align roadmap")
            == "Close renewal")
        #expect(GoalSuggestion.resolveEffective(
            callGoal: "  ", meetingTitle: "Q3 renewal — Acme", suggestedGoal: "Align roadmap")
            == "Q3 renewal — Acme")
        #expect(GoalSuggestion.resolveEffective(
            callGoal: "", meetingTitle: "", suggestedGoal: "Align roadmap")
            == "Align roadmap")
        #expect(GoalSuggestion.resolveEffective(
            callGoal: "", meetingTitle: "  ", suggestedGoal: nil)
            == "")
    }

    @Test("calendar names replace placeholders without overwriting a user title")
    func calendarMeetingTitlePolicy() {
        #expect(MeetingTitlePolicy.applyingCalendarTitle(
            "Design sync", to: "") == "Design sync")
        #expect(MeetingTitlePolicy.applyingCalendarTitle(
            "Design sync", to: "Untitled meeting") == "Design sync")
        #expect(MeetingTitlePolicy.applyingCalendarTitle(
            "Design sync", to: "UNTITLED") == "Design sync")
        #expect(MeetingTitlePolicy.applyingCalendarTitle(
            "Design sync", to: "Customer discovery") == "Customer discovery")
        #expect(MeetingTitlePolicy.applyingCalendarTitle(
            "   ", to: "Customer discovery") == "Customer discovery")
    }
}

@Suite("Automatic co-pilot transcript gate")
struct CopilotTranscriptEligibilityTests {
    private func entry(_ text: String) -> TranscriptEntry {
        TranscriptEntry(source: .mic, text: text)
    }

    @Test("rejects sparse recognition fragments and accepts substantive discussion")
    func eligibility() {
        #expect(!CopilotTranscriptEligibility.canGenerateSuggestions([
            entry("Да."), entry("Шум"), entry("Продолжение следует.")
        ]))
        #expect(!CopilotTranscriptEligibility.canGenerateSuggestions([
            entry(String(repeating: "короткий фрагмент ", count: 20))
        ]))
        #expect(CopilotTranscriptEligibility.canGenerateSuggestions([
            entry(String(repeating: "обсуждаем требования и ограничения ", count: 4)),
            entry(String(repeating: "сравниваем варианты и риски ", count: 4)),
            entry(String(repeating: "фиксируем решение и следующий шаг ", count: 4)),
        ]))
    }

    @Test("eligibility saturates before cumulative Instant row tails")
    func cumulativeRowsAreBounded() {
        let longTail = String(repeating: "tail ", count: 200_000)
        let result = CopilotTranscriptEligibility.evaluate([
            entry(String(repeating: "recognized ", count: 30) + longTail),
            entry("second" + longTail),
            entry("third" + longTail),
        ])

        #expect(result.canGenerate)
        #expect(result.inspectedScalars <= 300)
    }

    @Test("recommendation evidence must appear in the recognized transcript")
    func exactEvidence() {
        let transcript = "[mic] Сегодня мы обсудили бюджет проекта и сроки запуска."
        #expect(SuggestionGrounding.contains(
            evidence: "мы обсудили бюджет проекта",
            in: transcript
        ))
        #expect(!SuggestionGrounding.contains(
            evidence: "клиент уже согласовал бюджет",
            in: transcript
        ))
        #expect(!SuggestionGrounding.contains(evidence: nil, in: transcript))
    }
}

@Suite("Rolling digest prompt composition")
struct DigestPromptTests {
    private func entries(count: Int, textLength: Int) -> [TranscriptEntry] {
        (0..<count).map { index in
            TranscriptEntry(source: .mic,
                            text: "entry-\(index) " + String(repeating: "word ", count: textLength / 5),
                            speaker: "Speaker \(index % 2)")
        }
    }

    @Test("short calls keep the full transcript even when a digest exists")
    func shortCallUnchanged() {
        let message = SystemInstructions.buildUserMessage(
            transcript: entries(count: 5, textLength: 100),
            additionalContext: nil, prompt: "Summarize", digest: "• early decision")
        #expect(message.contains("Transcript so far:"))
        #expect(!message.contains("rolling digest"))
        #expect(message.contains("entry-0"))
    }

    @Test("long calls switch to digest + verbatim tail, dropping the early raw text")
    func longCallUsesDigest() {
        let message = SystemInstructions.buildUserMessage(
            transcript: entries(count: 40, textLength: 600),   // ≫ digestActivationChars
            additionalContext: nil, prompt: "Summarize",
            digest: "• decided to migrate to Postgres (min 4)")
        #expect(message.contains("Call so far (rolling digest of earlier discussion):"))
        #expect(message.contains("decided to migrate to Postgres"))
        #expect(message.contains("Recent transcript (verbatim):"))
        #expect(!message.contains("entry-0 "))     // earliest raw entry gone
        #expect(message.contains("entry-39"))      // latest kept verbatim
    }

    @Test("long calls WITHOUT a digest keep the full transcript (no regression)")
    func longCallNoDigest() {
        let message = SystemInstructions.buildUserMessage(
            transcript: entries(count: 40, textLength: 600),
            additionalContext: nil, prompt: "Summarize", digest: nil)
        #expect(message.contains("entry-0 "))
        #expect(!message.contains("rolling digest"))
    }

    /// The context-preservation spine (M6d): in a long call the digest yields a
    /// BOUNDED prompt that still carries an early decision, after its raw line
    /// has scrolled far past the verbatim window. (Without the digest the raw
    /// line survives too — but only by sending the whole, unbounded transcript.)
    @Test("spine: an early decision survives a long call in a bounded prompt via the digest")
    func decisionSpineSurvivesLongCall() {
        // The early decision (unique raw marker "freeze the scope"), then a long
        // run of unrelated talk — far more than the verbatim tail can hold.
        var transcript = [
            TranscriptEntry(source: .mic,
                            text: "We will ship on the 15th and freeze the scope now.",
                            speaker: "Alex"),
        ]
        transcript += entries(count: 120, textLength: 400)   // ~48k chars ≫ tail

        // The digest carries the decision in its OWN wording ("launch is locked").
        let digest = "Decided early: launch is locked to the 15th; scope frozen."

        let withDigest = SystemInstructions.buildUserMessage(
            transcript: transcript, additionalContext: nil,
            prompt: "What did we commit to?", digest: digest)
        #expect(withDigest.contains("launch is locked"))    // recoverable via the digest
        #expect(!withDigest.contains("freeze the scope"))   // raw early line scrolled out of the tail
        #expect(withDigest.contains("entry-119"))           // recent talk stays verbatim

        // The full (no-digest) path keeps the raw early line — but unbounded: it
        // is materially larger. The digest is what makes preservation cheap.
        let withoutDigest = SystemInstructions.buildUserMessage(
            transcript: transcript, additionalContext: nil,
            prompt: "What did we commit to?", digest: nil)
        #expect(withoutDigest.contains("freeze the scope"))       // full transcript kept…
        #expect(withoutDigest.count > withDigest.count * 2)       // …at 2×+ the size
    }
}
