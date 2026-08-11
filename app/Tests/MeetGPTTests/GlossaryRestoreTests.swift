import Testing
@testable import MeetGPT

/// Text-level glossary restoration on the FINAL transcript.
///
/// Exists because the decoder-prompt glossary was measured to be unusable on
/// the whole-file pass: it bought term recall by deleting speech — small went
/// D 125 → 356, large collapsed to WER 0.95 with 2757 deletions. The recall
/// headroom is real (off → answer-key: base 0.50 → 0.95, small 0.64 → 0.91),
/// so the terms have to come back OUTSIDE the decoder, where a mistake can
/// only ever touch one token and never make words disappear.
@Suite("Glossary restore")
struct GlossaryRestoreTests {

    // MARK: - Casing restore (identical modulo case and punctuation)

    @Test("restores canonical casing of a term the decoder spelled right")
    func restoresCasing() {
        #expect(GlossaryRestore.restore(transcript: "we discussed pcep at length",
                                        glossary: ["PCEP"])
                == "we discussed PCEP at length")
    }

    @Test("restores a multi-word term's casing")
    func restoresMultiWordCasing() {
        #expect(GlossaryRestore.restore(transcript: "the yang model needs review",
                                        glossary: ["YANG model"])
                == "the YANG model needs review")
    }

    @Test("leaves a term already canonical untouched")
    func alreadyCanonical() {
        let text = "the PCEP session stayed up"
        #expect(GlossaryRestore.restore(transcript: text, glossary: ["PCEP"]) == text)
    }

    // MARK: - Garble restore (fuzzy, gated hard)

    @Test("repairs a non-word garble one edit from the term")
    func repairsGarble() {
        #expect(GlossaryRestore.restore(transcript: "the PSEP extension passed",
                                        glossary: ["PCEP"])
                == "the PCEP extension passed")
    }

    @Test("repairs a vowelless garble of a hyphenated term")
    func repairsHyphenatedGarble() {
        #expect(GlossaryRestore.restore(transcript: "MPLST tunnels carry it",
                                        glossary: ["MPLS-TE"])
                == "MPLS-TE tunnels carry it")
    }

    @Test("repairs an acronym-shaped near-miss")
    func repairsAcronymNearMiss() {
        #expect(GlossaryRestore.restore(transcript: "the OEM tooling was flaky",
                                        glossary: ["OAM"])
                == "the OAM tooling was flaky")
    }

    // MARK: - What must never happen

    @Test("never rewrites ordinary prose into a term")
    func leavesProseAlone() {
        // "piece" IS how the decoder mishears PCE — and it is also an
        // ordinary English word that appears in ordinary sentences. A text
        // pass cannot tell those apart, so it must not try.
        let text = "a piece of the code was missing"
        #expect(GlossaryRestore.restore(transcript: text, glossary: ["PCE"]) == text)
    }

    @Test("never rewrites one glossary term into another")
    func respectsRivalTerms() {
        let text = "the OEM firmware shipped late"
        #expect(GlossaryRestore.restore(transcript: text, glossary: ["OAM", "OEM"]) == text)
    }

    @Test("never fires on a distant token even if it looks like jargon")
    func distanceBounded() {
        let text = "the BGP4 session flapped"
        #expect(GlossaryRestore.restore(transcript: text, glossary: ["PCEP"]) == text)
    }

    @Test("ignores one- and two-character glossary entries for fuzzy repair")
    func shortTermsCasingOnly() {
        // Two letters reach half the alphabet within one edit; fuzzy matching
        // at that length rewrites the transcript, not restores it.
        let text = "we go to the market"
        #expect(GlossaryRestore.restore(transcript: text, glossary: ["GT"]) == text)
    }

    @Test("a sentence-start capital does not make prose a garble")
    func sentenceStartCapitalStaysProse() {
        // Every sentence starts with a capital. "Can" sits one edit from
        // "CAT" and "It" one edit from "Git"; both must survive.
        #expect(GlossaryRestore.restore(transcript: "Can we ship it today",
                                        glossary: ["CAT"])
                == "Can we ship it today")
        #expect(GlossaryRestore.restore(transcript: "It builds fine locally",
                                        glossary: ["Git"])
                == "It builds fine locally")
    }

    @Test("vowelless y-words are prose, not garbles")
    func yWordsAreProse() {
        #expect(GlossaryRestore.restore(transcript: "why it failed is unclear",
                                        glossary: ["PHY"])
                == "why it failed is unclear")
    }

    @Test("Cyrillic prose is prose — Russian vowels count")
    func cyrillicProseUntouched() {
        // Without Cyrillic vowels in the gate, every Russian word looks
        // "vowelless" and becomes fuzzy-repair fodder for any near term:
        // "мост" is one edit from a "МОСТ-2" project name, "погода" one from
        // "ПОГОДА-1". Both must stay exactly as spoken.
        let bridge = "мы обсудили мост и сроки проекта"
        #expect(GlossaryRestore.restore(transcript: bridge, glossary: ["МОСТ-2"]) == bridge)
        let weather = "погода была хорошая"
        #expect(GlossaryRestore.restore(transcript: weather, glossary: ["ПОГОДА-1"]) == weather)
        // Casing restore must still work on a Cyrillic term spelled right.
        #expect(GlossaryRestore.restore(transcript: "проект яндекса запущен",
                                        glossary: ["Яндекса"])
                == "проект Яндекса запущен")
    }

    @Test("a plural keeps its s and gains the term's casing")
    func pluralsAreInflectionsNotGarbles() {
        // The corpus caught this: "RSPs" and "gTLDs" were being stripped to
        // the singular — nine fresh substitutions on one CART fixture.
        #expect(GlossaryRestore.restore(transcript: "the RSPs signed on",
                                        glossary: ["RSP"])
                == "the RSPs signed on")
        #expect(GlossaryRestore.restore(transcript: "new gtlds are coming",
                                        glossary: ["gTLD"])
                == "new gTLDs are coming")
    }

    @Test("a possessive is left exactly as written")
    func possessivesUntouched() {
        #expect(GlossaryRestore.restore(transcript: "ICANN's next round opens soon",
                                        glossary: ["ICANN"])
                == "ICANN's next round opens soon")
    }

    // MARK: - Mechanics

    @Test("preserves surrounding punctuation")
    func preservesPunctuation() {
        #expect(GlossaryRestore.restore(transcript: "then PSEP, as expected, held",
                                        glossary: ["PCEP"])
                == "then PCEP, as expected, held")
    }

    @Test("empty glossary is the identity")
    func emptyGlossaryIdentity() {
        let text = "nothing should change here"
        #expect(GlossaryRestore.restore(transcript: text, glossary: []) == text)
    }

    @Test("restore is idempotent")
    func idempotent() {
        let once = GlossaryRestore.restore(transcript: "the PSEP and pcep results",
                                           glossary: ["PCEP"])
        let twice = GlossaryRestore.restore(transcript: once, glossary: ["PCEP"])
        #expect(once == twice)
        #expect(once == "the PCEP and PCEP results")
    }
}
