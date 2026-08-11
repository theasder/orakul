import Testing
@testable import MeetGPT

@Suite("Blind-spot context compressor")
struct BlindSpotContextCompressorTests {
    @Test("system prompt bounds output and forbids invention")
    func systemPrompt() {
        let prompt = BlindSpotContextCompressor.systemPrompt(goal: "Close renewal", probe: "risks")
        #expect(prompt.contains("Close renewal"))
        #expect(prompt.contains("risks"))
        #expect(prompt.contains("Do NOT invent"))
        #expect(prompt.contains("\(BlindSpotContextCompressor.maxBullets)"))
    }

    @Test("parseBullets normalizes dashes and numbered lines")
    func parseBullets() {
        let raw = """
        Here you go:
        - CRM says budget is $40k [workflow:risks · HubSpot]
        2. Open Linear ticket ENG-12 blocks launch
        • Duplicate of first
        short
        """
        let bullets = BlindSpotContextCompressor.parseBullets(raw, limit: 3)
        #expect(bullets.count == 3)
        #expect(bullets[0].hasPrefix("- "))
        #expect(bullets[0].contains("budget"))
        #expect(bullets[1].contains("ENG-12"))
    }

    @Test("pack respects the character cap")
    func packCap() {
        let bullets = (0..<8).map { "- fact \($0) " + String(repeating: "x", count: 80) }
        let packed = BlindSpotContextCompressor.pack(bullets, cap: 200)
        #expect(packed.count <= 200)
        #expect(packed.contains("- fact 0"))
    }

    @Test("user payload includes sources and a transcript relevance slice")
    func userPayload() {
        let user = BlindSpotContextCompressor.userPayload(
            rawContext: "[workflow:risks · Sentry] error spike",
            recentTranscript: "We are worried about reliability."
        )
        #expect(user.contains("Sources:"))
        #expect(user.contains("Sentry"))
        #expect(user.contains("Recent transcript"))
        #expect(user.contains("reliability"))
    }

    @Test("fallbackPack truncates without requiring an LLM")
    func fallback() {
        let raw = String(repeating: "a", count: 5_000)
        let packed = BlindSpotContextCompressor.fallbackPack(raw, cap: 100)
        #expect(packed.count == 100)
    }

    @Test("source-aware packing preserves bounded connector evidence without a generic chat call")
    func deterministicPackingDoesNotSpendChatCredits() async throws {
        let gateway = MockLLMGateway(response: "this must never be requested")
        let raw = """
        [workflow:risks · Sentry] Checkout latency breached 900 ms after deploy 42.

        [workflow:whattoask · HubSpot] Renewal budget is capped at $40k pending legal review.

        [workflow:competition · Notion] The prior decision says launch requires a rollback plan.
        """
        let model = LLMModel(
            id: "gpt-4o-mini", label: "mini", provider: .openAI,
            minTier: .free, supportsVision: false)

        let packed = try #require(await BlindSpotContextCompressor.compress(
            goal: "Resolve renewal risk and latency",
            probe: "risks",
            rawContext: raw,
            recentTranscript: "The renewal depends on latency and legal approval.",
            llm: gateway,
            model: model))

        #expect(gateway.calls.isEmpty, "compression must not reserve generic chat before brainstorm")
        #expect(packed.count <= BlindSpotContextCompressor.maxOutputChars)
        #expect(packed.contains("[workflow:risks · Sentry]"))
        #expect(packed.contains("Checkout latency breached 900 ms"))
        #expect(packed.contains("[workflow:whattoask · HubSpot]"))
        #expect(packed.contains("Renewal budget is capped at $40k"))
    }

    @Test("packing distributes its cap across sources and ranks literal relevance first")
    func deterministicPackingIsBoundedAndBroad() {
        let filler = String(repeating: "unrelated boilerplate ", count: 80)
        let raw = [
            "[workflow:other · A] \(filler)",
            "[workflow:risks · B] launch rollback blocks the customer migration \(filler)",
            "[workflow:other · C] a distinct source must remain visible \(filler)",
        ].joined(separator: "\n\n")

        let packed = BlindSpotContextCompressor.sourceAwarePack(
            goal: "Protect the launch migration",
            probe: "risks",
            rawContext: raw,
            recentTranscript: "We need a rollback before customer migration.",
            cap: 300)

        #expect(packed.count <= 300)
        #expect(packed.hasPrefix("- [workflow:risks · B]"))
        #expect(packed.contains("[workflow:other · A]"))
        #expect(packed.contains("[workflow:other · C]"))
    }

    @Test("mirrored connector facts are sent once even when source tags differ")
    func mirroredFactsAreDeduplicated() {
        let repeated = "CRX-42 blocks the launch until the rollback plan is approved."
        let raw = """
        [workflow:risks · Linear] \(repeated)

        [workflow:risks · Slack] \(repeated)

        [workflow:risks · Notion] Canary rollout is required by the launch spec.
        """

        let blocks = BlindSpotContextCompressor.rankedSourceBlocks(
            goal: "Unblock launch", probe: "risks", rawContext: raw,
            recentTranscript: "We need the rollback plan.")
        let packed = BlindSpotContextCompressor.sourceAwarePack(
            goal: "Unblock launch", probe: "risks", rawContext: raw,
            recentTranscript: "We need the rollback plan.")

        #expect(blocks.count == 2)
        #expect(packed.components(separatedBy: repeated).count == 2)
        #expect(packed.contains("Canary rollout"))
    }

    @Test("bounded packing clips on a word boundary")
    func clippingKeepsWordsWhole() {
        let packed = BlindSpotContextCompressor.sourceAwarePack(
            goal: "launch",
            probe: "risks",
            rawContext: "[workflow:risks · Linear] launch migration supercalifragilistic",
            recentTranscript: "",
            cap: 50)

        #expect(packed.count <= 50)
        #expect(packed.hasSuffix("…"))
        #expect(!packed.hasSuffix("supercalifragi…"))
    }
}
