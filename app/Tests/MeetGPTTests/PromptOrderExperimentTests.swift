import Foundation
import Testing
@testable import MeetGPT

// A token saving is only a saving if the answer survives it.
//
// Most of the caching work cannot lose anything: the model receives identical
// bytes, merely annotated. Two levers CAN lose something, and they are measured
// the same way — run the recorded window with the lever ON and OFF, score both
// with the deterministic critics, and report what was saved against what broke.
//
//   * PROMPT ORDER moves the attached context above the transcript. Same tokens,
//     different order, and models are order-sensitive.
//   * THE ROLLING DIGEST replaces the early transcript with a summary past 12k
//     characters. That is real compression: the facts it drops are gone.
//
// The verdict is deliberately a ratio. "Saves 40% of input" means nothing on its
// own, and neither does "one ungrounded answer".

@Suite("Token levers — measured against turning them off")
struct LeverExperimentTests {
    private let transcript = [
        TranscriptEntry(source: .system, text: "We should ship the beta on the 22nd."),
        TranscriptEntry(source: .mic, text: "Only if the offline path is flagged off."),
    ]

    private func window(digest: String = "") -> LeverExperiment.Window {
        LeverExperiment.Window(
            sessionTitle: "Mobile beta",
            transcript: transcript,
            attachedContext: "Project brief: the beta ships behind a flag.",
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting.",
            digest: digest)
    }

    @Test("the prompt-order lever carries exactly the same content either way")
    func orderIsContentPreserving() {
        // If this fails, the reorder stopped being a reorder and became a
        // rewrite — and any quality difference would be uninterpretable.
        let w = window()
        let off = LeverExperiment.message(w, lever: .promptOrder, applied: false)
        let on = LeverExperiment.message(w, lever: .promptOrder, applied: true)

        #expect(off != on)
        #expect(off.count == on.count)
        for fragment in ["Project brief", "Transcript so far", "Request:"] {
            #expect(off.contains(fragment))
            #expect(on.contains(fragment))
        }
        // Same tokens in a different order: nothing is saved directly, the
        // saving comes from what a cache can then reuse.
        #expect(LeverExperiment.estimatedTokens(off)
                == LeverExperiment.estimatedTokens(on))
    }

    @Test("the digest lever really does drop content, and saves tokens for it")
    func digestIsLossyAndCheaper() {
        let long = (0..<400).map {
            TranscriptEntry(source: .system, text: "Line \($0) of a long call.")
        }
        let w = LeverExperiment.Window(
            sessionTitle: "Long call", transcript: long,
            attachedContext: "", prompt: "Summarize",
            recordingContext: "", digest: "Earlier: the team argued about scope.")

        let off = LeverExperiment.message(w, lever: .transcriptDigest, applied: false)
        let on = LeverExperiment.message(w, lever: .transcriptDigest, applied: true)

        #expect(LeverExperiment.estimatedTokens(on)
                < LeverExperiment.estimatedTokens(off))
        // And the early lines are genuinely gone — that is the cost side.
        #expect(off.contains("Line 0 of a long call."))
        #expect(!on.contains("Line 0 of a long call."))
    }

    @Test("an answer that stops quoting the transcript is scored as a loss")
    func ungroundedAnswerIsALoss() {
        let score = LeverExperiment.score([
            .init(window: "w1", applied: false,
                  answer: "They agreed to \"ship the beta on the 22nd\".",
                  transcript: "We should ship the beta on the 22nd.",
                  inputTokens: 100),
            .init(window: "w1", applied: true,
                  answer: "They agreed to \"double the marketing budget\".",
                  transcript: "We should ship the beta on the 22nd.",
                  inputTokens: 60),
        ])
        #expect(score.ungroundedWithLever == 1)
        #expect(score.ungroundedWithout == 0)
        #expect(score.regressed)
    }

    @Test("matching quality with fewer tokens is the result worth having")
    func parityWithSavingIsAWin() {
        let answer = "They agreed to \"ship the beta on the 22nd\"."
        let score = LeverExperiment.score([
            .init(window: "w1", applied: false, answer: answer,
                  transcript: "We should ship the beta on the 22nd.", inputTokens: 100),
            .init(window: "w1", applied: true, answer: answer,
                  transcript: "We should ship the beta on the 22nd.", inputTokens: 60),
        ])
        #expect(!score.regressed)
        #expect(score.tokensSavedShare > 0.35)
    }

    @Test("an answer that goes silent counts, even though it breaks no rule")
    func silenceIsMeasured() {
        // A refusal quotes nothing and therefore violates nothing. Counting only
        // rule breaks would score "said nothing" as flawless.
        let score = LeverExperiment.score([
            .init(window: "w1", applied: false,
                  answer: "They agreed to \"ship the beta on the 22nd\".",
                  transcript: "We should ship the beta on the 22nd.", inputTokens: 100),
            .init(window: "w1", applied: true, answer: "   ",
                  transcript: "We should ship the beta on the 22nd.", inputTokens: 60),
        ])
        #expect(score.silentWithLever == 1)
        #expect(score.regressed)
    }

    @Test("a verdict on too few windows says so instead of concluding")
    func smallSampleRefusesToConclude() {
        let thin = LeverExperiment.score([
            .init(window: "w1", applied: false, answer: "a", transcript: "a",
                  inputTokens: 10),
        ])
        #expect(LeverExperiment.verdict(thin).lowercased().contains("too few"))
    }

    @Test("a verdict names the price as well as the saving")
    func verdictIsARatio() {
        let observations = (0..<12).flatMap { index -> [LeverExperiment.Observation] in
            [.init(window: "w\(index)", applied: false,
                   answer: "They agreed to \"ship the beta on the 22nd\".",
                   transcript: "We should ship the beta on the 22nd.", inputTokens: 100),
             .init(window: "w\(index)", applied: true,
                   answer: "They agreed to \"ship the beta on the 22nd\".",
                   transcript: "We should ship the beta on the 22nd.", inputTokens: 55)]
        }
        let verdict = LeverExperiment.verdict(LeverExperiment.score(observations))
        #expect(verdict.contains("%"))
        #expect(!verdict.lowercased().contains("too few"))
    }

    @Test("windows are built from what the live path would actually have sent")
    func windowsComeFromRealSessions() {
        let session = SavedSession(
            id: UUID(), title: "Mobile beta", startedAt: Date(), savedAt: Date(),
            goal: "Decide the date", entries: transcript,
            aiResponse: "",
            aiHistory: [AIExchange(prompt: "What did we decide?", answer: "…")],
            digest: "")
        let windows = LeverExperiment.windows(for: session)
        #expect(!windows.isEmpty)
        #expect(windows.first?.prompt == "What did we decide?")
    }
}
