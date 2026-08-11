import Foundation
import Testing
@testable import MeetGPT

/// The built-in domain lexicon: the ICP's vocabulary, shipped.
///
/// A product manager at a VC-backed company says "ARR", "Jira" and "RAG" in
/// the first ten minutes of any call, before any glossary is configured.
/// These terms ride `GlossaryRestore` — text-level, measured safe at scale —
/// never the decoder prompt, which collapses at 25 terms.
@Suite("Domain lexicon")
struct DomainLexiconTests {

    @Test("every entry is restore-actionable, never a plain word")
    func entriesAreRestoreActionable() {
        // Restore can only fix casing and garbles. A pure-lowercase word like
        // "roadmap" is a no-op that dilutes nothing but proves the list was
        // not curated. Every entry must carry a capital, a digit, or a
        // separator — the shapes restore acts on.
        for term in DomainLexicon.productManagement {
            let actionable = term.contains(where: { $0.isUppercase || $0.isNumber })
                || term.contains("-") || term.contains(" ")
            #expect(actionable, "'\(term)' is a plain word restore can never act on")
        }
    }

    @Test("no duplicate entries at the matching level")
    func noDuplicates() {
        let norms = DomainLexicon.productManagement.map { term in
            String(term.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            })
        }
        #expect(Set(norms).count == norms.count, "two entries collapse to one norm")
    }

    @Test("the list stays a lexicon, not a dictionary")
    func sizeIsBounded() {
        #expect(DomainLexicon.productManagement.count >= 120)
        #expect(DomainLexicon.productManagement.count <= 400)
    }

    @Test("restores the ICP's metric casing")
    func restoresMetricCasing() {
        #expect(GlossaryRestore.restore(transcript: "our arr doubled and cac fell",
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement)
                == "our ARR doubled and CAC fell")
    }

    @Test("restores product-name casing")
    func restoresProductCasing() {
        // Linear is deliberately NOT in the lexicon — "linear growth" is
        // prose, and a text pass cannot tell the tool from the adjective.
        #expect(GlossaryRestore.restore(transcript: "moved from jira to posthog last sprint",
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement)
                == "moved from Jira to PostHog last sprint")
        #expect(GlossaryRestore.restore(transcript: "the linear roadmap stays linear",
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement)
                == "the linear roadmap stays linear")
    }

    @Test("AI slang keeps its shapes")
    func aiSlang() {
        #expect(GlossaryRestore.restore(transcript: "we ran rag over sota llms",
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement)
                == "we ran RAG over SOTA LLMs")
        #expect(GlossaryRestore.restore(transcript: "wired n8n into claude code",
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement)
                == "wired n8n into Claude Code")
    }

    @Test("acronym families protect each other from fuzzy repair")
    func acronymFamiliesAreMutuallyProtected() {
        // "CTO" sits one edit from "CTR". With both in the lexicon, neither
        // can be rewritten into the other — the rival-term rule holds. This
        // is why families ship together even when one member seems obscure.
        let text = "the CTO reviewed CTR and CPC with the CFO"
        #expect(GlossaryRestore.restore(transcript: text,
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement) == text)
    }

    @Test("prose stays prose under the full lexicon")
    func proseSurvivesFullLexicon() {
        let text = "we can ship it and see what the market says about pricing"
        #expect(GlossaryRestore.restore(transcript: text,
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement) == text)
    }

    @Test("out-of-lexicon acronyms are never pulled to a lexicon neighbour")
    func outOfLexiconAcronymsSurvive() {
        // The 230-term corpus run caught fuzzy repair rewriting acronyms the
        // lexicon does NOT contain into their one-edit neighbours that it
        // does: GAC→CAC, IDN→IDE, PTI→PTO, +0.4 WER on every tier. The
        // lexicon is casing-only precisely so this class cannot exist.
        let text = "the GAC asked about IDN adoption and PTI operations"
        #expect(GlossaryRestore.restore(transcript: text,
                                        glossary: [], casingOnlyGlossary: DomainLexicon.productManagement) == text)
    }

    @Test("the user's own glossary still repairs garbles alongside the lexicon")
    func userGlossaryKeepsFuzzy() {
        #expect(GlossaryRestore.restore(transcript: "the PSEP session and our arr",
                                        glossary: ["PCEP"],
                                        casingOnlyGlossary: DomainLexicon.productManagement)
                == "the PCEP session and our ARR")
    }
}
