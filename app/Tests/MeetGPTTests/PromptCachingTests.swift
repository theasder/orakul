import Foundation
import Testing
@testable import MeetGPT

// Prompt caching has one prerequisite the code did not meet: the parts of a
// request that stay the same must come BEFORE the parts that change. The
// transcript grows every few seconds, so anything placed after it can never be
// cached — and the attached context, the largest stable block, sat there.
//
// The second half is the grounding cache. Its key carried the prompt ID, so five
// background watches asking the same question of the same sources each missed
// the others' entry. The ID is not what shapes the result; the workflow is.

@Suite("Prompt assembly is cache-friendly")
struct PromptOrderingTests {
    private let transcript = [
        TranscriptEntry(source: .system, text: "We should ship on the 22nd."),
    ]

    private func message(context: String?) -> String {
        SystemInstructions.buildUserMessage(
            transcript: transcript,
            additionalContext: context,
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting. Treat it as a meeting.")
    }

    @Test("stable blocks precede the growing transcript")
    func stableBeforeVolatile() {
        let text = message(context: "Project brief: the mobile beta ships behind a flag.")
        let contextAt = text.range(of: "Additional context")!.lowerBound
        let transcriptAt = text.range(of: "Transcript so far")!.lowerBound

        // Attached context is the same on every pass of a call; the transcript
        // is not. A cached prefix breaks at the first byte that differs, so this
        // ordering is the difference between caching everything above the
        // transcript and caching nothing at all.
        #expect(contextAt < transcriptAt)
    }

    @Test("the request stays last, after everything it refers to")
    func requestIsLast() {
        let text = message(context: "Some brief.")
        let requestAt = text.range(of: "Request:")!.lowerBound
        #expect(text.range(of: "Transcript so far")!.lowerBound < requestAt)
        #expect(text.range(of: "Additional context")!.lowerBound < requestAt)
    }

    @Test("the recording type still leads")
    func recordingTypeLeads() {
        // Existing contract: the type orients everything after it, so it comes
        // first — and it is stable, so it costs nothing to keep there.
        #expect(message(context: "brief").hasPrefix("Recording type: Meeting."))
    }

    @Test("two passes of one call share the longest possible prefix")
    func consecutivePassesShareAPrefix() {
        // What the cache actually needs: appending a transcript line must leave
        // everything above the transcript byte-identical.
        let brief = "Project brief: the mobile beta ships behind a flag."
        let first = message(context: brief)
        let second = SystemInstructions.buildUserMessage(
            transcript: transcript + [
                TranscriptEntry(source: .mic, text: "Agreed, flag off by default."),
            ],
            additionalContext: brief,
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting. Treat it as a meeting.")

        let shared = first.commonPrefix(with: second)
        #expect(shared.contains("Additional context"))
        #expect(shared.contains("Project brief"))
    }
}

@Suite("The stable half of a message is nameable")
struct MessagePartsTests {
    private let transcript = [
        TranscriptEntry(source: .system, text: "We should ship on the 22nd."),
    ]

    private func parts(context: String?) -> (stable: String, volatile: String) {
        SystemInstructions.buildUserMessageParts(
            transcript: transcript,
            additionalContext: context,
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting. Treat it as a meeting.")
    }

    @Test("the parts rebuild the message exactly")
    func partsAreTheMessage() {
        // The split is where the cache breakpoint goes, so it must not change a
        // single byte of what the model receives.
        let split = parts(context: "Project brief.")
        #expect(split.stable + split.volatile == SystemInstructions.buildUserMessage(
            transcript: transcript,
            additionalContext: "Project brief.",
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting. Treat it as a meeting."))
    }

    @Test("the stable half holds what does not change during a call")
    func stableHoldsContext() {
        let split = parts(context: "Project brief: ships behind a flag.")
        #expect(split.stable.contains("Recording type: Meeting"))
        #expect(split.stable.contains("Project brief"))
        // The transcript and the request are what change every pass.
        #expect(!split.stable.contains("Transcript so far"))
        #expect(split.volatile.contains("Transcript so far"))
        #expect(split.volatile.contains("Request:"))
    }

    @Test("the stable half is byte-identical as the transcript grows")
    func stableSurvivesNewLines() {
        let brief = "Project brief: ships behind a flag."
        let first = parts(context: brief)
        let second = SystemInstructions.buildUserMessageParts(
            transcript: transcript + [
                TranscriptEntry(source: .mic, text: "Agreed, flag off by default."),
            ],
            additionalContext: brief,
            prompt: "What did we decide?",
            recordingContext: "Recording type: Meeting. Treat it as a meeting.")
        // This is the whole property a cache read depends on.
        #expect(first.stable == second.stable)
        #expect(first.volatile != second.volatile)
    }
}

@Suite("Anthropic request marks its cacheable prefix")
struct AnthropicCacheControlTests {
    private func body(cachedPrefix: String?) -> [String: Any] {
        AnthropicClient.requestBody(
            system: String(repeating: "You are a meeting co-pilot. ", count: 60),
            user: "Recent tail and the request.",
            cachedPrefix: cachedPrefix,
            images: [],
            model: "claude-sonnet-4-5",
            outputCap: 1024)
    }

    @Test("the system block is marked only when the caller opted into caching")
    func systemIsCacheableWhenOptedIn() {
        // Marking is not free. A block that is never read still bills its write
        // at a premium, so a caller whose system prompt CHANGES every pass —
        // the agenda watch rebuilds it with the findings surfaced so far — would
        // pay extra for a cache nothing can hit.
        let optedIn = body(cachedPrefix: "stable context")["system"] as? [[String: Any]]
        #expect((optedIn?.first?["cache_control"] as? [String: String])?["type"]
                == "ephemeral")

        let notOptedIn = body(cachedPrefix: nil)["system"] as? [[String: Any]]
        #expect(notOptedIn?.first?["cache_control"] == nil)
    }

    @Test("an unmarked system block is still a plain string the API accepts")
    func unmarkedSystemStaysValid() {
        let system = body(cachedPrefix: nil)["system"]
        #expect(system is String || system is [[String: Any]])
    }

    @Test("a stable user prefix becomes its own cached block")
    func prefixBecomesACachedBlock() {
        let payload = body(cachedPrefix: "Attached context that does not change.")
        let messages = payload["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]

        #expect(content?.count == 2)
        #expect(content?.first?["text"] as? String == "Attached context that does not change.")
        #expect((content?.first?["cache_control"] as? [String: String])?["type"] == "ephemeral")
        // The volatile half must NOT be marked: caching a block that changes
        // every pass pays the write premium for a cache nothing can read.
        #expect(content?.last?["cache_control"] == nil)
        #expect(content?.last?["text"] as? String == "Recent tail and the request.")
    }

    private func userBlocks(_ payload: [String: Any]) -> [[String: Any]]? {
        let messages = payload["messages"] as? [[String: Any]]
        return messages?.first?["content"] as? [[String: Any]]
    }

    @Test("without a stable prefix the user message stays one plain block")
    func noPrefixKeepsOneBlock() {
        let content = userBlocks(body(cachedPrefix: nil))
        #expect(content?.count == 1)
        #expect(content?.first?["cache_control"] == nil)
    }

    @Test("an empty prefix is treated as no prefix")
    func blankPrefixIsIgnored() {
        // A breakpoint around an empty block would spend a cache write on
        // nothing at all.
        #expect(userBlocks(body(cachedPrefix: "   "))?.count == 1)
    }

    @Test("images still ride along after the text")
    func imagesSurvive() {
        let payload = AnthropicClient.requestBody(
            system: "s", user: "u", cachedPrefix: "stable",
            images: [Data([0x89, 0x50, 0x4E, 0x47])],
            model: "claude-sonnet-4-5", outputCap: 512)
        let content = userBlocks(payload)
        #expect(content?.count == 3)
        #expect(content?.last?["type"] as? String == "image")
    }
}

@Suite("Grounding cache is shared by shape, not by prompt name")
struct GroundingCacheKeyTests {
    private func workflow(servers: Set<String> = ["notion"],
                          includeLedger: Bool = false,
                          includeTeam: Bool = false,
                          maxChars: Int = 1_200,
                          strategy: PromptWorkflow.QueryStrategy = .goal) -> PromptWorkflow {
        PromptWorkflow(
            servers: servers,
            includeTeam: includeTeam,
            includeLedger: includeLedger,
            queryStrategy: strategy,
            maxCharsPerSource: maxChars,
            sourceIntents: [.documents])
    }

    @Test("two prompts that would retrieve identically share one key")
    func identicalShapesShare() {
        // Blind spot, agenda and fact-check can all ask the same question of the
        // same sources. Keying on the prompt ID made each of them re-query.
        #expect(workflow().groundingShapeKey == workflow().groundingShapeKey)
    }

    @Test("anything that changes the retrieved text changes the key")
    func shapingFieldsSeparateKeys() {
        let base = workflow().groundingShapeKey
        #expect(workflow(servers: ["linear"]).groundingShapeKey != base)
        #expect(workflow(includeLedger: true).groundingShapeKey != base)
        #expect(workflow(includeTeam: true).groundingShapeKey != base)
        // The per-source character cap decides how much of each hit survives, so
        // a smaller cap must not be served a larger cap's cached snippets.
        #expect(workflow(maxChars: 400).groundingShapeKey != base)
        // The strategy decides what is actually searched for.
        #expect(workflow(strategy: .topics).groundingShapeKey != base)
    }

    @Test("server order does not invent a new key")
    func keyIsOrderIndependent() {
        #expect(workflow(servers: ["notion", "linear"]).groundingShapeKey
                == workflow(servers: ["linear", "notion"]).groundingShapeKey)
    }
}
