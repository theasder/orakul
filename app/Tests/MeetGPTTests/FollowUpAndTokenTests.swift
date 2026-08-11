import Testing
import Foundation
@testable import MeetGPT

@Suite("Follow-up suggestions parser")
struct FollowUpServiceTests {
    @Test("parses a clean JSON array into prompts")
    func parsesClean() {
        let raw = """
        [{"icon":"📧","title":"Draft the email","prompt":"Draft a follow-up email covering the decisions."},
         {"icon":"⚠️","title":"Probe the risk","prompt":"List open questions about the migration risk."}]
        """
        let prompts = FollowUpService.parse(raw)
        #expect(prompts.count == 2)
        #expect(prompts[0].title == "Draft the email")
        #expect(prompts[0].icon == "📧")
        #expect(prompts[1].prompt.contains("migration risk"))
        #expect(prompts.allSatisfy { $0.id.hasPrefix("followup-") })
    }

    @Test("tolerates code fences and prose around the array")
    func toleratesWrapping() {
        let raw = """
        Here are the suggestions:
        ```json
        [{"title":"Next steps","prompt":"Turn the answer into next steps."}]
        ```
        """
        let prompts = FollowUpService.parse(raw)
        #expect(prompts.count == 1)
        #expect(prompts[0].icon == "↩️")   // missing icon gets the default
    }

    @Test("drops malformed entries and caps at three")
    func dropsAndCaps() {
        let raw = """
        [{"title":"","prompt":"no title"},
         {"title":"ok 1","prompt":"p1"},{"title":"ok 2","prompt":"p2"},
         {"title":"ok 3","prompt":"p3"},{"title":"ok 4","prompt":"p4"}]
        """
        let prompts = FollowUpService.parse(raw)
        #expect(prompts.count == 3)
    }

    @Test("garbage yields empty, never crashes")
    func garbage() {
        #expect(FollowUpService.parse("no json here").isEmpty)
        #expect(FollowUpService.parse("[not, valid").isEmpty)
        #expect(FollowUpService.parse("").isEmpty)
    }
}

@Suite("Token estimate")
struct TokenEstimateTests {
    @Test("chars convert to tokens at ~4:1, rounded up")
    func conversion() {
        #expect(TokenEstimate.tokens(0) == 0)
        #expect(TokenEstimate.tokens(-5) == 0)
        #expect(TokenEstimate.tokens(1) == 1)
        #expect(TokenEstimate.tokens(4) == 1)
        #expect(TokenEstimate.tokens(5) == 2)
        #expect(TokenEstimate.tokens(4_000) == 1_000)
    }

    @Test("total sums all ingredients")
    func total() {
        let estimate = TokenEstimate(transcriptChars: 8_000, contextChars: 2_000,
                                     sourcesChars: 6_000, instructionsChars: 400)
        #expect(estimate.totalTokens == 2_000 + 500 + 1_500 + 100)
    }

    @Test("labels are compact at every magnitude")
    func labels() {
        #expect(TokenEstimate.label(980) == "980")
        #expect(TokenEstimate.label(12_400) == "12.4k")
        #expect(TokenEstimate.label(150_000) == "150k")
        #expect(TokenEstimate.label(1_240_000) == "1.2M")
    }

    @Test("budget rail is absolute against the 6k base-credit input")
    func baseCreditThreshold() {
        let half = TokenEstimate(transcriptChars: 12_000)
        #expect(half.totalTokens == 3_000)
        #expect(half.baseCreditInputFraction == 0.5)
        #expect(half.tokensAboveBaseCreditInput == 0)

        let boundary = TokenEstimate(transcriptChars: 24_000)
        #expect(boundary.totalTokens == TokenEstimate.baseCreditInputTokens)
        #expect(boundary.baseCreditInputFraction == 1)
        #expect(boundary.tokensAboveBaseCreditInput == 0)

        let over = TokenEstimate(transcriptChars: 24_004)
        #expect(over.totalTokens == 6_001)
        #expect(over.baseCreditInputFraction == 1)
        #expect(over.tokensAboveBaseCreditInput == 1)
    }
}

@MainActor
@Suite("Compute usage refresh signaling")
struct ComputeUsageRefreshTests {
    @Test("automatic follow-up completion publishes a credit refresh revision")
    func followUpPublishesRevision() async {
        let llm = MockLLMGateway(response: "A useful answer")
        let state = AppState(llm: llm)
        state.runPrompt(.custom(icon: "✨", title: "Test", prompt: "Summarize this."))

        await state.aiTask?.value
        for _ in 0..<200 where state.computeUsageRevision == 0 { await Task.yield() }

        #expect(llm.calls.count >= 2)
        #expect(state.computeUsageRevision == 1)
    }
}
