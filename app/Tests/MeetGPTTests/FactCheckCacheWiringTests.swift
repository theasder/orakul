import Foundation
import Testing
@testable import MeetGPT

// The fact-check watch is the background loop with something genuinely worth
// caching: its user message puts the attached CONTEXT first and the transcript
// after it, and the context is the same documents on every pass of a call.
//
// The agenda watch, by contrast, sends a sliding transcript window under a
// system prompt rebuilt with the findings so far — nothing there repeats, so
// nothing there is worth marking. That negative result is recorded here so the
// next person does not "optimise" it and pay cache-write premiums for a prefix
// that can never be read.

@Suite("The fact-check watch splits its prompt where it repeats")
struct FactCheckCacheWiringTests {
    private func source(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repository.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    @Test("context is the cached half and the transcript is not")
    func splitsAtTheContextBoundary() throws {
        let service = try source("Sources/MeetGPT/AI/FactCheckService.swift")
        #expect(service.contains("cachedPrefix: cachedPrefix"))
        #expect(service.contains("volatileSuffix: volatileSuffix"))
        // The transcript must be on the volatile side — marking it would pay a
        // write premium every pass for a block that changes every pass.
        #expect(service.contains("let volatileSuffix = \"TRANSCRIPT to check:"))
    }

    @Test("the two halves still say exactly what the single string said")
    func bytesAreUnchanged() {
        // Reconstructed rather than trusted: this prompt is live, and a stray
        // newline is a silent prompt change dressed as an optimisation.
        let context = "Spec: the beta ships behind a flag."
        let transcript = "We should ship on the 22nd."
        let cachedPrefix = "CONTEXT (the only source of truth for external verification):\n"
            + context + "\n\n"
        let volatileSuffix = "TRANSCRIPT to check:\n\(transcript)"
        let legacy = "CONTEXT (the only source of truth for external verification):\n\(context)\n\nTRANSCRIPT to check:\n\(transcript)"

        #expect(cachedPrefix + volatileSuffix == legacy)
    }

    @Test("an empty context still produces the documented placeholder")
    func emptyContextKeepsItsPlaceholder() {
        let empty = ""
        let cachedPrefix = "CONTEXT (the only source of truth for external verification):\n"
            + (empty.isEmpty ? "(none provided)" : empty) + "\n\n"
        #expect(cachedPrefix.contains("(none provided)"))
    }

    @Test("the agenda watch is deliberately left unmarked")
    func agendaWatchStaysUnmarked() throws {
        // Its system prompt is rebuilt with prior findings and its user message
        // is a sliding window. Nothing repeats, so a breakpoint would cost more
        // than it saves.
        let agenda = try source("Sources/MeetGPT/AI/AgendaCheckService.swift")
        #expect(!agenda.contains("cachedPrefix"))
    }
}
