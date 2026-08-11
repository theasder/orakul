import Testing
import Foundation
@testable import MeetGPT

/// The prompt scaffold: how skill layers stack onto the base instructions, how
/// transcript entries render to one canonical line each, and how the user
/// message assembles transcript + context + request (with a rolling-digest
/// swap for long calls). All pure, deterministic string plumbing.
@Suite("System instructions")
struct SystemInstructionsTests {

    // MARK: - Helpers

    /// Build a transcript entry via the real initializer. A fixed timestamp
    /// keeps the rendered `HH:mm:ss` reproducible within a run.
    private func entry(_ text: String,
                       source: TranscriptSource = .system,
                       speaker: String? = nil,
                       timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TranscriptEntry {
        TranscriptEntry(source: source, text: text, timestamp: timestamp, speaker: speaker)
    }

    // MARK: - system(skills:)

    @Test("system always prefixes the base instructions")
    func systemPrefixesBase() {
        #expect(SystemInstructions.system(skills: []).hasPrefix(SystemInstructions.base))
        #expect(SystemInstructions.system(skills: ["Layer A"]).hasPrefix(SystemInstructions.base))
    }

    @Test("empty skill list yields exactly the base")
    func systemNoLayers() {
        #expect(SystemInstructions.system(skills: []) == SystemInstructions.base)
        // nil / whitespace-only layers collapse to the base too.
        #expect(SystemInstructions.system(skills: [nil, "   ", "\n\t "]) == SystemInstructions.base)
    }

    @Test("system drops nil and whitespace-only layers, keeps order, trims each")
    func systemDropsAndOrders() {
        let result = SystemInstructions.system(skills: ["  Layer A  ", nil, "", "   ", "Layer B"])
        #expect(result == SystemInstructions.base + "\n\nLayer A\n\nLayer B")
    }

    @Test("layers join with a blank line and preserve given order")
    func systemJoinsWithBlankLine() {
        let result = SystemInstructions.system(skills: ["First", "Second"])
        #expect(result == SystemInstructions.base + "\n\nFirst\n\nSecond")
        // Order is not sorted — reversing the input reverses the layers.
        let reversed = SystemInstructions.system(skills: ["Second", "First"])
        #expect(reversed == SystemInstructions.base + "\n\nSecond\n\nFirst")
    }

    // MARK: - formatEntries

    @Test("formatEntries renders timestamp, source, speaker, and text on one line")
    func formatEntriesWithSpeaker() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let expectedTime = formatter.string(from: ts)

        let line = SystemInstructions.formatEntries([
            entry("hello there", source: .system, speaker: "Alice", timestamp: ts)
        ])
        #expect(line == "[\(expectedTime)][system] Alice: hello there")
    }

    @Test("formatEntries omits the speaker segment when speaker is nil")
    func formatEntriesNoSpeaker() {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let expectedTime = formatter.string(from: ts)

        let line = SystemInstructions.formatEntries([
            entry("just the text", source: .mic, speaker: nil, timestamp: ts)
        ])
        #expect(line == "[\(expectedTime)][mic] just the text")
        // No stray speaker colon leaks in.
        #expect(!line.contains(": just the text"))
    }

    @Test("formatEntries joins multiple entries with newlines")
    func formatEntriesJoinsWithNewlines() {
        let rendered = SystemInstructions.formatEntries([
            entry("one", source: .system, speaker: "Alice"),
            entry("two", source: .mic, speaker: "Bob")
        ])
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(rendered.contains("][system] Alice: one"))
        #expect(rendered.contains("][mic] Bob: two"))
    }

    @Test("formatEntries on an empty list is the empty string")
    func formatEntriesEmpty() {
        #expect(SystemInstructions.formatEntries([]).isEmpty)
    }

    // MARK: - buildUserMessage

    @Test("empty transcript emits the empty marker")
    func buildEmptyTranscript() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [], additionalContext: nil, prompt: "Summarize.")
        #expect(message.contains("Transcript: (empty"))
        #expect(!message.contains("Transcript so far:"))
    }

    @Test("no additional context renders the (none) marker")
    func buildNoContext() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [entry("hi", speaker: "Alice")],
            additionalContext: nil, prompt: "Go.")
        #expect(message.contains("Additional context: (none)"))
        // Whitespace-only context is treated as absent.
        let blank = SystemInstructions.buildUserMessage(
            transcript: [entry("hi", speaker: "Alice")],
            additionalContext: "   \n ", prompt: "Go.")
        #expect(blank.contains("Additional context: (none)"))
    }

    @Test("additional context renders as a labeled block")
    func buildWithContext() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [entry("hi", speaker: "Alice")],
            additionalContext: "  Q3 renewal is at risk  ", prompt: "Advise.")
        #expect(message.contains("Additional context:\nQ3 renewal is at risk"))
        #expect(!message.contains("Additional context: (none)"))
    }

    @Test("the prompt is appended under the Request heading")
    func buildAppendsRequest() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [entry("hi", speaker: "Alice")],
            additionalContext: nil, prompt: "What are the risks?")
        #expect(message.contains("\n\nRequest:\nWhat are the risks?"))
        #expect(message.hasSuffix("Request:\nWhat are the risks?"))
    }

    @Test("populated transcript uses the Transcript so far heading")
    func buildTranscriptSoFar() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [entry("a decision was made", speaker: "Alice")],
            additionalContext: nil, prompt: "Recap.")
        #expect(message.contains("Transcript so far:"))
        #expect(message.contains("Alice: a decision was made"))
    }

    // MARK: - digest activation

    /// A single entry whose text alone pushes the formatted transcript well past
    /// the activation threshold.
    private func longTranscript() -> [TranscriptEntry] {
        let bigText = String(repeating: "the migration timeline slipped again ",
                             count: 500)   // ~19k chars, > digestActivationChars
        return [entry(bigText, source: .system, speaker: "Alice")]
    }

    @Test("a non-empty digest over the threshold switches to the rolling digest block")
    func buildDigestActivates() {
        let transcript = longTranscript()
        #expect(SystemInstructions.formatEntries(transcript).count > SystemInstructions.digestActivationChars)

        let message = SystemInstructions.buildUserMessage(
            transcript: transcript, additionalContext: nil,
            prompt: "Continue.", digest: "EARLIER: the team chose Postgres for prod.")
        #expect(message.contains("rolling digest"))
        #expect(message.contains("EARLIER: the team chose Postgres for prod."))
        #expect(message.contains("Recent transcript (verbatim):"))
        #expect(!message.contains("Transcript so far:"))
    }

    @Test("no digest keeps the full transcript even when long")
    func buildLongTranscriptNoDigest() {
        let message = SystemInstructions.buildUserMessage(
            transcript: longTranscript(), additionalContext: nil,
            prompt: "Continue.", digest: nil)
        #expect(message.contains("Transcript so far:"))
        #expect(!message.contains("rolling digest"))
    }

    @Test("a whitespace-only digest does not activate the digest block")
    func buildBlankDigestNoActivation() {
        let message = SystemInstructions.buildUserMessage(
            transcript: longTranscript(), additionalContext: nil,
            prompt: "Continue.", digest: "   \n  ")
        #expect(message.contains("Transcript so far:"))
        #expect(!message.contains("rolling digest"))
    }

    @Test("a digest under the threshold stays on the full transcript")
    func buildDigestUnderThreshold() {
        let message = SystemInstructions.buildUserMessage(
            transcript: [entry("short line", speaker: "Alice")],
            additionalContext: nil,
            prompt: "Continue.", digest: "EARLIER: nothing much yet.")
        #expect(message.contains("Transcript so far:"))
        #expect(!message.contains("rolling digest"))
    }
}
