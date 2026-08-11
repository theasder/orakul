import Foundation
import Testing
@testable import MeetGPT

/// A gateway that answers by which system prompt it was handed, so the
/// experiment's own logic is provable without spending a single token. The live
/// run costs model calls; the scoring must not.
private final class ScriptedGateway: LLMGateway, @unchecked Sendable {
    var rhetoric: String
    var facilitation: String
    var merged: String
    private(set) var calls = 0

    init(rhetoric: String = "NONE", facilitation: String = "NONE",
         merged: String = #"{"rhetoric":null,"facilitation":null}"#) {
        self.rhetoric = rhetoric
        self.facilitation = facilitation
        self.merged = merged
    }

    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        calls += 1
        if system == MergedWatch.systemPrompt { return merged }
        if system == FacilitationWatch.systemPrompt { return facilitation }
        return rhetoric
    }
}

@Suite("Watch A/B experiment")
struct WatchABExperimentTests {

    private func model() -> LLMModel {
        LLMCatalog.model(id: "gpt-5.4-mini") ?? LLMCatalog.defaultModel(for: .free)
    }

    private func window() -> WatchABExperiment.Window {
        WatchABExperiment.Window(sessionTitle: "Pricing review", goal: "Agree the July price",
                                 transcript: "[system] We keep circling the same discount.",
                                 offset: 300)
    }

    private func session(entries: Int, secondsApart: TimeInterval = 60,
                         text: String = String(repeating: "we discussed the roadmap at length. ", count: 12))
    -> SavedSession {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return SavedSession(
            id: UUID(), title: "Replay", startedAt: start, savedAt: start,
            goal: "Ship in July",
            entries: (0..<entries).map {
                TranscriptEntry(source: .system, text: text,
                                timestamp: start.addingTimeInterval(secondsApart * Double($0)))
            },
            aiResponse: "", digest: "")
    }

    // MARK: - Replay fidelity

    @Test("windows follow the live cadence, not a round number")
    func windowsFollowCadence() {
        // 30 entries a minute apart = 30 minutes of call, judged every 300 s.
        let windows = WatchABExperiment.windows(for: session(entries: 30))

        #expect(windows.count >= 4)
        #expect(windows[0].offset == 300)
        #expect(windows[1].offset == 600)
        #expect(windows.allSatisfy { $0.goal == "Ship in July" })
    }

    @Test("a tick with too little new material is skipped, as in production")
    func quietTicksAreSkipped() {
        // Entries far apart and tiny: the coalescing gate that stops the live
        // loop paying to re-read what it already read must stop the replay too,
        // or the experiment measures windows the product never sends.
        let quiet = session(entries: 30, secondsApart: 60, text: "ok")
        let busy = session(entries: 30, secondsApart: 60)

        #expect(WatchABExperiment.windows(for: quiet).count
                < WatchABExperiment.windows(for: busy).count)
    }

    @Test("a call too short to judge produces no windows")
    func shortCallsAreNotReplayed() {
        #expect(WatchABExperiment.windows(for: session(entries: 2)).isEmpty)
    }

    @Test("the window is capped like promptTranscript's tail")
    func windowIsCapped() {
        let long = session(entries: 30, text: String(repeating: "x", count: 2_000))
        let windows = WatchABExperiment.windows(for: long, cap: 1_000)

        #expect(windows.allSatisfy { $0.transcript.count <= 1_000 })
    }

    // MARK: - Both variants over identical input

    @Test("each window costs two separate calls and one merged call")
    func runsBothVariants() async {
        let gateway = ScriptedGateway()
        _ = await WatchABExperiment.observe(window(), gateway: gateway, model: model())

        #expect(gateway.calls == 3)
    }

    @Test("silence on both sides is recorded as silence")
    func silenceIsSilence() async {
        let gateway = ScriptedGateway()
        let observation = await WatchABExperiment.observe(window(), gateway: gateway, model: model())

        #expect(observation.separateRhetoric == nil)
        #expect(observation.merged.rhetoric == nil)
        #expect(!observation.mergedUnparsable)
    }

    // MARK: - Scoring the risks

    @Test("a note merged invented where separate stayed quiet is counted against it")
    func slotFillingIsCaught() async {
        // The precision risk the whole experiment exists to measure: two named
        // fields make "nothing to report" harder to say than a whole call
        // answering NONE.
        let gateway = ScriptedGateway(
            rhetoric: "NONE", facilitation: "NONE",
            merged: #"{"rhetoric":"The discount claim is unsupported.","facilitation":null}"#)
        let observation = await WatchABExperiment.observe(window(), gateway: gateway, model: model())

        let score = WatchABExperiment.score([observation])

        #expect(score.mergedSpokeAlone == 1)
        #expect(score.falseSpeechRate == 0.5)   // 1 of 2 tracks
    }

    @Test("the same claim reworded counts as agreement, not as a difference")
    func rewordingIsAgreement() async {
        let gateway = ScriptedGateway(
            rhetoric: "The discount claim is unsupported by any number.",
            facilitation: "NONE",
            merged: #"{"rhetoric":"Discount claim unsupported by numbers.","facilitation":null}"#)

        let score = WatchABExperiment.score(
            [await WatchABExperiment.observe(window(), gateway: gateway, model: model())])

        #expect(score.agreed == 1)
        #expect(score.disagreed == 0)
        #expect(score.agreementRate == 1)
    }

    @Test("one theme in both slots is recorded as collapse")
    func themeCollapseIsCaught() async {
        let gateway = ScriptedGateway(
            rhetoric: "Discount claim unsupported by numbers.",
            facilitation: "The discount discussion is going in circles.",
            merged: """
            {"rhetoric":"The discount claim is unsupported by numbers.",\
            "facilitation":"Discount claim unsupported by numbers."}
            """)

        let score = WatchABExperiment.score(
            [await WatchABExperiment.observe(window(), gateway: gateway, model: model())])

        #expect(score.collapsed == 1)
    }

    @Test("an unparsable merged reply is the failure that costs both notes")
    func unparsableIsCounted() async {
        let gateway = ScriptedGateway(
            rhetoric: "Discount claim unsupported.", facilitation: "Going in circles.",
            merged: "I'm sorry, I can't help with that.")

        let observation = await WatchABExperiment.observe(window(), gateway: gateway, model: model())
        let score = WatchABExperiment.score([observation])

        #expect(observation.mergedUnparsable)
        #expect(score.unparsable == 1)
        #expect(score.separateSpokeAlone == 2)   // both notes lost at once
    }

    // MARK: - The verdict

    @Test("the bar is stated up front and rejects an invented-note rate")
    func verdictRejectsNoisyMerge() {
        var score = WatchABExperiment.Score()
        score.windows = 10
        score.mergedSpokeAlone = 3      // 15% of 20 tracks
        score.agreed = 8

        #expect(WatchABExperiment.verdict(score).hasPrefix("VERDICT: reject"))
        #expect(WatchABExperiment.verdict(score).contains("invented"))
    }

    @Test("a clean merge is accepted, and the payoff named is coverage not credits")
    func verdictAcceptsCleanMerge() {
        // Rotation means merging saves no credits — it buys each track a
        // 10-minute cadence instead of 15. The verdict has to say so, or the
        // result gets sold as a saving it is not.
        var score = WatchABExperiment.Score()
        score.windows = 12
        score.agreed = 9
        score.disagreed = 2
        score.mergedSpokeAlone = 1

        let verdict = WatchABExperiment.verdict(score)

        #expect(verdict.hasPrefix("VERDICT: accept"))
        #expect(verdict.contains("coverage"))
    }

    @Test("too few windows decides nothing")
    func smallSampleIsNotAVerdict() {
        var score = WatchABExperiment.Score()
        score.windows = 3
        score.agreed = 3

        #expect(WatchABExperiment.verdict(score).contains("not enough windows"))
    }

    // MARK: - Merged parsing

    @Test("the merged parser applies the same normalization as the separate watches")
    func mergedParsingMatchesSeparate() {
        // Otherwise a comparison measures post-processing, not the merge.
        let verdicts = MergedWatch.parse(#"{"rhetoric":"NONE","facilitation":"  “Steer back.”  "}"#)

        #expect(verdicts.rhetoric == nil)
        #expect(verdicts.facilitation == "Steer back")
    }

    @Test("JSON wrapped in prose or a fence still parses")
    func mergedParserToleratesWrapping() {
        let fenced = """
        Here you go:
        ```json
        {"rhetoric":null,"facilitation":"You have drifted onto pricing."}
        ```
        """
        #expect(MergedWatch.parse(fenced).facilitation == "You have drifted onto pricing")
    }
}
