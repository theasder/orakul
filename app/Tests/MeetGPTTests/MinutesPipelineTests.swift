import Foundation
import Testing
@testable import MeetGPT

/// Returns a fixed artifact JSON, so the test exercises the pipeline rather
/// than a model.
private struct ScriptedGateway: LLMGateway, @unchecked Sendable {
    let reply: String
    func streamChat(system: String,
                    user: String,
                    images: [Data],
                    model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        onDelta(reply)
        return reply
    }
}

/// F4 and F10 where they actually apply.
///
/// Both are unit-tested on their own, and both are wired into
/// `MeetingArtifactService.decode`. Nothing proved the wiring runs: a decode
/// that forgot `.ranked()` would leave every ConsequenceRanker test green while
/// shipping unranked minutes. This drives the real entry point with a scripted
/// model reply and asserts on the artifact a user would receive.
@Suite("Minutes pipeline")
struct MinutesPipelineTests {

    private let modelJSON = """
    {
      "title": "Weekly product sync",
      "decisions": [
        "Team lunch moves to Thursdays",
        "We are sunsetting the legacy API in June",
        "Raise the enterprise plan to $499"
      ],
      "actionItems": [
        {"task": "Collect competitor pricing"},
        {"task": "Draft the migration plan", "owner": "Priya", "due": "Friday"}
      ],
      "nextSteps": ["Book the follow-up"]
    }
    """

    private let transcript = """
    We agreed to sunset the legacy API in June, and to raise the enterprise
    plan to $499. Team lunch moves to Thursdays. Priya will draft the migration
    plan by Friday, and somebody should collect competitor pricing.
    """

    private func minutes(from json: String, transcript: String) async throws -> MinutesArtifact {
        let artifact = try await MeetingArtifactService.generate(
            skill: SkillLibrary.minutes, goal: "Ship safely", transcript: transcript,
            gateway: ScriptedGateway(reply: json))
        guard case .minutes(let minutes) = artifact else {
            Issue.record("expected minutes, got \(artifact.kind)")
            throw MeetingArtifactError.unparseable("wrong kind")
        }
        return minutes
    }

    @Test("the artifact a user receives is consequence-ordered, not model-ordered")
    func rankingRunsInThePipeline() async throws {
        let minutes = try await minutes(from: modelJSON, transcript: transcript)
        // The model listed lunch first. Nobody should read it first.
        #expect(minutes.decisions?.first?.contains("sunsetting the legacy API") == true)
        #expect(minutes.decisions?.last?.contains("Team lunch") == true)
        // The owned, dated commitment leads the wish.
        #expect(minutes.actionItems?.first?.owner == "Priya")
        #expect(minutes.markdown.contains("### Нужен владелец"))
    }

    @Test("a figure the room never said is flagged on the way out")
    func numbersGuardRunsInThePipeline() async throws {
        let invented = modelJSON.replacingOccurrences(of: "Book the follow-up",
                                                      with: "Target 40% activation by Q3")
        let minutes = try await minutes(from: invented, transcript: transcript)
        #expect(minutes.markdown.contains("Проверьте эти цифры"))
        #expect(minutes.unverifiedFigures?.contains("40%") == true)
        // The figure the transcript DOES contain must not be flagged.
        #expect(minutes.unverifiedFigures?.contains("$499") != true)
    }

    @Test("a clean artifact carries no warning at all")
    func noFalseWarning() async throws {
        let minutes = try await minutes(from: modelJSON, transcript: transcript)
        #expect(minutes.unverifiedFigures == nil)
        #expect(!minutes.markdown.contains("Проверьте эти цифры"))
    }
}
