import Foundation
import Testing
@testable import MeetGPT

/// What glossary restore costs on a real recording.
///
/// It runs over the WHOLE transcript at the end of a call, and F7 just made
/// its vocabulary bigger: the ICP lexicon plus up to two vertical packs plus
/// the theme glossary plus the user's own terms. Restore is O(terms × text),
/// so "add more words" is exactly the change that turns a one-second pass into
/// a stall on the recording the user is waiting to read.
///
/// Env-gated (`CRUXWING_PERF=1`) and best-of-three, for the same reason as the
/// recall budgets: a developer machine is never quiet.
@Suite("Glossary restore — cost on a real transcript")
struct GlossaryRestorePerformanceTests {

    private var enabled: Bool { ProcessInfo.processInfo.environment["CRUXWING_PERF"] != nil }

    /// Two hours of talk at a normal speaking rate.
    private static let transcriptCharacters = 110_000
    /// The post-call pass already re-runs Whisper over the file; restore is the
    /// cheap step bolted onto the end and must stay that way.
    private static let budgetSeconds = 3.0

    private func longTranscript() -> String {
        let sentences = [
            "so our arr is up and cac came down after the pricing change",
            "the kyc review blocked the payments launch until the pci scope is agreed",
            "we need the prd before the qbr and the okr draft by friday",
            "posthog shows activation dropping for the b2b saas cohort",
            "engineering wants kubernetes and terraform before the migration",
        ]
        var text = ""
        var index = 0
        while text.count < Self.transcriptCharacters {
            text += sentences[index % sentences.count] + ". "
            index += 1
        }
        return text
    }

    private func fastest(_ runs: Int = 3, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<runs {
            let began = Date()
            body()
            best = min(best, Date().timeIntervalSince(began))
        }
        return best
    }

    @Test("a two-hour transcript restores inside the post-call budget")
    func restoreStaysCheap() {
        guard enabled else { return }
        let transcript = longTranscript()
        // The worst realistic vocabulary: ICP lexicon + the two packs this text
        // signals (payments and infrastructure) + a user glossary.
        let casingOnly = DomainLexicon.casingOnlyTerms(for: transcript)
        let userTerms = ["Cruxwing", "Wheespr", "Priya Raman", "Acme Robotics"]

        var restored = ""
        let elapsed = fastest {
            restored = GlossaryRestore.restore(transcript: transcript,
                                               glossary: userTerms,
                                               casingOnlyGlossary: casingOnly)
        }
        print(String(format: "restore over %d chars with %d terms: %.2fs (best of 3)",
                     transcript.count, casingOnly.count + userTerms.count, elapsed))

        #expect(restored.contains("ARR") && restored.contains("KYC"),
                "the pass must still do its job at this size")
        #expect(elapsed < Self.budgetSeconds,
                "restore took \(elapsed)s on a two-hour transcript — the user is waiting on this")
    }

    @Test("pack activation itself is not the expensive part")
    func packRoutingIsCheap() {
        guard enabled else { return }
        let transcript = longTranscript()
        let elapsed = fastest { _ = DomainLexicon.casingOnlyTerms(for: transcript) }
        print(String(format: "pack routing over %d chars: %.3fs (best of 3)", transcript.count, elapsed))
        #expect(elapsed < 0.25, "signal matching scans the transcript per pack — keep it linear")
    }
}
