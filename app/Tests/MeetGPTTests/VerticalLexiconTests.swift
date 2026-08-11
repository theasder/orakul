import Foundation
import Testing
@testable import MeetGPT

/// F7: vertical lexicon packs on top of the ICP lexicon.
///
/// Same measured law as `DomainLexicon.productManagement`: packs ride
/// GlossaryRestore as CASING-ONLY vocabulary. Fuzzy repair at lexicon scale
/// cost +0.4 WER per tier (GAC→CAC, IDN→IDE), so a pack may never widen the
/// fuzzy set — it only teaches restore how a word is spelled once it has been
/// heard correctly. A pack loads only when the meeting is visibly about that
/// vertical, because a fintech pack in a healthcare call is pure risk.
@Suite("Vertical lexicon packs")
struct VerticalLexiconTests {

    private func norm(_ term: String) -> String {
        String(term.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    @Test("every pack entry is restore-actionable, never a plain word")
    func entriesAreActionable() {
        for pack in DomainLexicon.verticalPacks {
            for term in pack.terms {
                let actionable = term.contains(where: { $0.isUppercase || $0.isNumber })
                    || term.contains("-") || term.contains(" ")
                #expect(actionable, "[\(pack.id)] '\(term)' is a plain word restore can never act on")
            }
        }
    }

    @Test("no pack entry collapses onto a common English word")
    func noCommonWordCollisions() {
        // The audit that keeps a lexicon from recasing prose. Words here are
        // ones a meeting says constantly in their ordinary sense.
        let commonWords: Set<String> = [
            "safe", "sam", "it", "us", "rest", "linear", "zoom", "loom", "segment",
            "whisper", "goat", "copilot", "care", "claim", "plan", "cash", "check",
            "bank", "card", "risk", "stack", "build", "ship", "cloud", "chain",
            "order", "cart", "lead", "close", "scale", "gross", "net", "hold",
        ]
        for pack in DomainLexicon.verticalPacks {
            for term in pack.terms {
                #expect(!commonWords.contains(norm(term)),
                        "[\(pack.id)] '\(term)' would recase ordinary prose")
            }
        }
    }

    @Test("packs do not fight each other or the base lexicon over one spelling")
    func noCrossPackCollisions() {
        var owner: [String: String] = [:]
        for term in DomainLexicon.productManagement { owner[norm(term)] = "base:\(term)" }
        for pack in DomainLexicon.verticalPacks {
            for term in pack.terms {
                let key = norm(term)
                if let existing = owner[key] {
                    // Same spelling in two places is fine; two DIFFERENT
                    // spellings of one norm means restore would flip-flop.
                    #expect(existing.hasSuffix(term),
                            "[\(pack.id)] '\(term)' collides with \(existing)")
                } else {
                    owner[key] = "\(pack.id):\(term)"
                }
            }
        }
    }

    @Test("each pack stays a lexicon, not a dictionary")
    func packsAreBounded() {
        #expect(DomainLexicon.verticalPacks.count >= 3)
        for pack in DomainLexicon.verticalPacks {
            #expect(pack.terms.count >= 15, "[\(pack.id)] too thin to be worth loading")
            #expect(pack.terms.count <= 120, "[\(pack.id)] is becoming a dictionary")
            #expect(!pack.signals.isEmpty, "[\(pack.id)] can never activate")
        }
    }

    // MARK: activation

    @Test("a pack activates only when the meeting is visibly about that vertical")
    func activationRequiresSignal() {
        let fintech = DomainLexicon.activePacks(for: "reviewing the chargeback flow and PCI scope for the payments launch")
        #expect(fintech.contains { $0.id == "fintech" })

        let generic = DomainLexicon.activePacks(for: "weekly sync about the roadmap and hiring")
        #expect(generic.isEmpty, "an ordinary product meeting must load no vertical pack")
    }

    @Test("at most two packs load, the strongest signals first")
    func activationIsCapped() {
        let everything = DomainLexicon.verticalPacks
            .flatMap(\.signals)
            .joined(separator: " ")
        #expect(DomainLexicon.activePacks(for: everything).count <= 2)
    }

    @Test("the casing-only vocabulary is the base lexicon plus whatever activated")
    func casingOnlyVocabulary() {
        let base = DomainLexicon.casingOnlyTerms(for: "generic roadmap sync")
        #expect(base.count == DomainLexicon.productManagement.count)

        let withPack = DomainLexicon.casingOnlyTerms(for: "PCI scope, chargeback rate and the KYC vendor")
        #expect(withPack.count > base.count)
        #expect(Set(base).isSubset(of: Set(withPack)), "activating a pack must never drop base terms")
        #expect(Set(withPack).count == withPack.count, "duplicate terms would double-apply restore")
    }

    // MARK: measured behaviour

    @Test("an activated pack restores its own casing and leaves prose alone")
    func restoresVerticalCasing() {
        let terms = DomainLexicon.casingOnlyTerms(for: "the kyc and pci review with the payments team")
        #expect(GlossaryRestore.restore(transcript: "the kyc review blocked our pci scope",
                                        glossary: [], casingOnlyGlossary: terms)
                == "the KYC review blocked our PCI scope")
    }

    @Test("a pack that never activated cannot touch the transcript")
    func inactivePackIsInert() {
        let terms = DomainLexicon.casingOnlyTerms(for: "weekly product roadmap sync")
        // "snomed" exists ONLY in the health pack, which this meeting never
        // signals. (HIPAA would not prove anything — it is base vocabulary,
        // because every PM hits it in a compliance conversation.)
        #expect(GlossaryRestore.restore(transcript: "somebody said snomed once in passing",
                                        glossary: [], casingOnlyGlossary: terms)
                == "somebody said snomed once in passing")
        // …and the same sentence in a clinical meeting does get fixed.
        let clinical = DomainLexicon.casingOnlyTerms(for: "clinical data mapping for the patient record")
        #expect(GlossaryRestore.restore(transcript: "somebody said snomed once in passing",
                                        glossary: [], casingOnlyGlossary: clinical)
                == "somebody said SNOMED once in passing")
    }
}
