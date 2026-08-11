import Foundation
import Testing
@testable import MeetGPT

@Suite("Transcript enhancement")
struct TranscriptEnhancementTests {

    @Test("extractJSONObject tolerates fences and prose wrappers")
    func extractsObject() {
        let raw = """
        Sure.
        ```json
        {"summary":"ok","entries":[{"offsetSec":1,"speaker":"Ada","source":"system","text":"Hi"}]}
        ```
        """
        let json = TranscriptEnhancementService.extractJSONObject(raw)
        #expect(json?.contains("\"summary\":\"ok\"") == true)
    }

    @Test("enhance maps Fireflies+Whisper JSON into timed TranscriptEntry rows")
    func enhanceParsesEntries() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let whisper = [
            TranscriptEntry(source: .system, text: "we ship friday", timestamp: start.addingTimeInterval(12)),
            TranscriptEntry(source: .mic, text: "agreed", timestamp: start.addingTimeInterval(18), speaker: nil)
        ]
        let fireflies = FirefliesTranscript(
            title: "Sprint sync",
            text: "Ada: We ship Friday.\nYou: Agreed.")
        let llm = MockLLMGateway(response: """
        {"summary":"Aligned speakers and wording",
         "entries":[
           {"offsetSec":12,"speaker":"Ada","source":"system","text":"We ship Friday."},
           {"offsetSec":18,"speaker":"You","source":"mic","text":"Agreed."}
         ]}
        """)

        let grounding = [
            GroundingSnippet(serverName: "Notion", toolName: "notion-search",
                             text: "Project orakul ships Friday; owner Ada Lovelace.")
        ]
        let result = try await TranscriptEnhancementService.enhance(
            whisper: whisper,
            fireflies: fireflies,
            sessionStart: start,
            goal: "Ship Friday",
            grounding: grounding,
            llm: llm,
            model: LLMCatalog.model(id: "gpt-5.4-mini") ?? LLMCatalog.defaultModel(for: .free))

        #expect(llm.calls.contains(where: { $0.user.contains("SOURCE C") && $0.user.contains("orakul") }))
        #expect(result.entries.count == 2)
        #expect(result.entries[0].speaker == "Ada")
        #expect(result.entries[0].text == "We ship Friday.")
        #expect(result.entries[0].source == .system)
        #expect(abs(result.entries[0].timestamp.timeIntervalSince(start) - 12) < 0.01)
        #expect(result.entries[1].source == .mic)
        #expect(result.summary == "Aligned speakers and wording")
        #expect(result.firefliesTitle == "Sprint sync")
    }

    @Test("enhance rejects empty model payloads")
    func enhanceRejectsJunk() async {
        let start = Date()
        let llm = MockLLMGateway(response: "I cannot help with that.")
        await #expect(throws: TranscriptEnhancementError.self) {
            try await TranscriptEnhancementService.enhance(
                whisper: [TranscriptEntry(source: .system, text: "hi", timestamp: start)],
                fireflies: FirefliesTranscript(title: "x", text: "hi"),
                sessionStart: start,
                llm: llm,
                model: LLMCatalog.model(id: "gpt-5.4-mini") ?? LLMCatalog.defaultModel(for: .free))
        }
    }

    @Test("pickFirefliesMeeting prefers the listing closest to session start")
    func picksNearestMeeting() {
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)},
          {"id":"now","title":"This call","date":\(target.addingTimeInterval(120).timeIntervalSince1970)},
          {"id":"later","title":"Tomorrow","date":\(target.addingTimeInterval(86_400).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(from: list, near: target)
        #expect(pick.id == "now")
        #expect(pick.title == "This call")
    }

    @Test("a match window accepts the meeting that IS this call")
    func windowAcceptsTheSameCall() {
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)},
          {"id":"now","title":"This call","date":\(target.addingTimeInterval(120).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: list, near: target, within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == "now")
    }

    @Test("a match window rejects a call Fireflies never joined")
    func windowRejectsADifferentCall() {
        // Fireflies attends some meetings, not all. Without the window the
        // nearest-in-time rule handed this call yesterday's meeting and merged
        // another conversation's words into it.
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let list = """
        [
          {"id":"old","title":"Yesterday","date":\(target.addingTimeInterval(-86_400).timeIntervalSince1970)}
        ]
        """
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: list, near: target, within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == nil)
        #expect(pick.title == nil)
    }

    @Test("a match window needs dates — an undated listing is not a match")
    func windowRejectsUndatedListings() {
        let pick = MCPConnectionManager.pickFirefliesMeeting(
            from: #"[{"id":"x","title":"Some meeting"}]"#,
            near: Date(),
            within: MCPConnectionManager.firefliesMatchWindow)
        #expect(pick.id == nil)
    }
}
