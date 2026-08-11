import Testing
import Foundation
@testable import MeetGPT

// Topic-routed glossary layered on the PM default. The load-bearing test is the
// collision audit: every entry rides GlossaryRestore (text-level), which recases
// tokens in the transcript, so a plain lowercase word would rewrite ordinary
// prose ("clause", "churn", "safe"). Every term must therefore be an acronym, a
// digit-bearing token, a CamelCase product, or a multi-word name — structurally
// distinct from prose. That, plus routing and no-dupes, is what these pin.
@Suite("Theme glossary")
struct ThemeGlossaryTests {

    /// A term is restore-safe only if it carries something prose does not: an
    /// uppercase letter, a digit, a hyphen, a slash, or a space. A plain
    /// lowercase word fails, and must never ship, because recasing it corrupts
    /// normal text.
    private func isRestoreSafe(_ term: String) -> Bool {
        term.contains(where: { $0.isUppercase || $0.isNumber })
            || term.contains("-") || term.contains("/") || term.contains(" ")
    }

    @Test("every term for every theme survives the collision audit")
    func everyTermIsRestoreSafe() {
        for theme in CallTheme.allCases {
            for term in ThemeGlossary.terms(for: theme) {
                #expect(isRestoreSafe(term), "\(theme).\"\(term)\" is a plain word — it would recase prose")
                #expect(!term.isEmpty)
            }
        }
    }

    @Test("no theme repeats a term within its own list")
    func noDuplicatesWithinATheme() {
        for theme in CallTheme.allCases {
            let list = ThemeGlossary.terms(for: theme)
            #expect(Set(list).count == list.count, "\(theme) has a duplicate term")
        }
    }

    @Test("the specialised themes actually carry vocabulary")
    func specialisedThemesAreNonEmpty() {
        // These are the calls whose jargon the PM default does not cover; an empty
        // list here would mean the routing buys nothing.
        for theme in [CallTheme.sales, .hiring, .engineering, .fundraising,
                      .customerSuccess, .legal] {
            #expect(!ThemeGlossary.terms(for: theme).isEmpty, "\(theme) should specialise")
        }
    }

    @Test("general has no specialised lexicon; product defers to the PM default")
    func coveredThemesAreEmpty() {
        #expect(ThemeGlossary.terms(for: .general).isEmpty)
        #expect(ThemeGlossary.terms(for: .product).isEmpty)
    }

    @Test("routing carries the protocol/infra vocabulary a PM default never had")
    func engineeringCarriesInfraVocab() {
        // The whole point: an engineering call loads terms the ICP PM lexicon
        // does not contain. (Kept independent of DomainLexicon so it builds on a
        // clean checkout; the layering happens at the call site, not in-file.)
        let engineering = ThemeGlossary.terms(for: .engineering)
        #expect(engineering.count >= 20, "engineering should be a substantial lexicon")
        for term in ["Kubernetes", "IPv6", "GraphQL", "OAuth", "gRPC"] {
            #expect(engineering.contains(term), "engineering missing \(term)")
        }
    }
}
