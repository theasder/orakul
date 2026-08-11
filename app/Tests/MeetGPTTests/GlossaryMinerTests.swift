import Foundation
import Testing
@testable import MeetGPT

/// Mining glossary candidates from text the user supplied.
///
/// The measured prize is large — the right terms in the decoder moved term
/// recall from 0.53 to 0.93 on an accented IETF call — but the cost of a bad
/// candidate is a user asked to approve noise, and a diluted prompt. These
/// tests weight refusing over finding.
@Suite("Glossary mining")
struct GlossaryMinerTests {

    private func terms(_ text: String, existing: [String] = []) -> [String] {
        GlossaryMiner.candidates(in: text, existing: existing).map(\.term)
    }

    @Test("finds the acronyms that actually broke on the work calls")
    func findsAcronyms() {
        let found = terms("Agenda: PCEP and BGP interaction, plus IGP metrics for CATS")
        #expect(found.contains("PCEP"))
        #expect(found.contains("BGP"))
        #expect(found.contains("IGP"))
        #expect(found.contains("CATS"))
    }

    @Test("finds hyphenated technical compounds")
    func findsHyphenated() {
        let found = terms("Covers MPLS-TE, sub-TLV encoding and SR-Policy")
        #expect(found.contains("MPLS-TE"))
        #expect(found.contains("sub-TLV"))
        #expect(found.contains("SR-Policy"))
    }

    @Test("finds product names and mixed-case identifiers")
    func findsProperNouns() {
        let found = terms("Migrate the Postgres cluster and enable IPv6 on Kubernetes")
        #expect(found.contains("Postgres"))
        #expect(found.contains("IPv6"))
        #expect(found.contains("Kubernetes"))
    }

    @Test("does not propose a capitalised sentence opener")
    func refusesSentenceOpeners() {
        // "This", "The", "We" start sentences constantly. Proposing them as
        // vocabulary is pure noise in a list the user has to read.
        let found = terms("This is the agenda. We will cover the rollout. There are risks.")
        #expect(found.isEmpty, "\(found)")
    }

    @Test("does not propose everyday initialisms")
    func refusesEverydayInitialisms() {
        let found = terms("FYI the call is 3 PM, ASAP please, in the US and UK")
        #expect(found.isEmpty, "\(found)")
    }

    @Test("does not propose ordinary prose")
    func refusesOrdinaryProse() {
        let found = terms("we should talk about the delivery date and the open risk before friday")
        #expect(found.isEmpty, "\(found)")
    }

    @Test("skips terms already in the glossary")
    func skipsKnownTerms() {
        // Re-proposing what the user already added is a list they have to
        // dismiss every time.
        let found = terms("PCEP and BGP and YANG", existing: ["pcep", "BGP"])
        #expect(found == ["YANG"])
    }

    @Test("deduplicates case-insensitively")
    func dedupes() {
        #expect(terms("BGP bgp BGP").count == 1)
    }

    @Test("strips trailing punctuation from a candidate")
    func stripsPunctuation() {
        // "PCEP," entering the prompt as a distinct token would waste a slot
        // and bias toward the comma.
        #expect(terms("We discussed PCEP, BGP.").sorted() == ["BGP", "PCEP"])
    }

    @Test("strongest evidence survives truncation")
    func ordersByStrength() {
        // Long agendas exceed the cap. Acronyms are the terms that actually
        // break, so they must not be crowded out by capitalised names.
        let names = (1...60).map { "Personname\($0)" }.joined(separator: " ")
        let found = terms(names + " PCEP")
        #expect(found.first == "PCEP")
        #expect(found.count <= GlossaryMiner.maximumCandidates)
    }

    @Test("merges several sources without repeating a term")
    func mergesSources() {
        let merged = GlossaryMiner.candidates(inSources: [
            "Agenda: PCEP design",
            "Notes on PCEP and MPLS-TE",
        ]).map(\.term)
        #expect(merged.filter { $0 == "PCEP" }.count == 1)
        #expect(merged.contains("MPLS-TE"))
    }

    @Test("every candidate explains itself")
    func candidatesCarryReasons() {
        // A suggestion the user cannot account for gets dismissed, and the
        // whole feature with it.
        let candidates = GlossaryMiner.candidates(in: "PCEP and MPLS-TE on Kubernetes")
        #expect(candidates.allSatisfy { !$0.reason.isEmpty })
        #expect(candidates.first { $0.term == "PCEP" }?.reason == "Acronym")
        #expect(candidates.first { $0.term == "MPLS-TE" }?.reason == "Technical term")
    }

    @Test("empty and whitespace input yields nothing")
    func handlesEmptyInput() {
        #expect(terms("").isEmpty)
        #expect(terms("   \n  ").isEmpty)
    }

    @Test("recovers the exact terms the measured fixtures needed")
    func recoversMeasuredFixtureTerms() {
        // The vocabulary from fixtures 14 and 15, as it would appear in an
        // agenda or a context document.
        let agenda = """
        IETF 125 PCE working group — PCEP extensions for BFD.
        Topics: PCE, PCC, MPLS-TE tunnels, sub-TLV encoding, LSP liveness.
        CATS design team: YANG model, IGP and BGP signalling, OAM.
        """
        let found = terms(agenda)
        for expected in ["PCEP", "PCE", "PCC", "MPLS-TE", "sub-TLV", "LSP", "YANG", "IGP", "BGP", "OAM"] {
            #expect(found.contains(expected), "missing \(expected) from \(found)")
        }
    }
}
