import Foundation
import Testing
@testable import MeetGPT

/// Removing secrets from text on its way to a model.
///
/// Roughly half of these tests assert that something is NOT redacted, and that
/// ratio is the point. This runs over meeting speech, which is full of ordinary
/// numbers — dates, prices, headcounts, room numbers, order ids. A filter that
/// eats those destroys the product in order to protect it, and the damage is
/// invisible: the answer just gets quietly worse.
///
/// Every detector therefore demands structural evidence — a Luhn check, a known
/// key prefix, a labelled field — never merely a shape.
@Suite("Outbound redactor")
struct OutboundRedactorTests {

    // MARK: - Payment cards

    @Test("redacts a card number that passes Luhn")
    func redactsRealCard() {
        // A well-known test card.
        let result = OutboundRedactor.redact("Charge it to 4532015112830366 today")
        #expect(result.didRedact)
        #expect(!result.text.contains("4532015112830366"))
        #expect(result.findings.first?.kind == .paymentCard)
    }

    @Test("redacts a card written with separators")
    func redactsSpacedCard() {
        #expect(OutboundRedactor.redact("card 4532-0151-1283-0366 ok").didRedact)
    }

    @Test("leaves a 16-digit number that fails Luhn alone")
    func keepsNonLuhnDigits() {
        // The check that makes this safe on speech: an order id or a reference
        // number of the same length is not a card.
        let result = OutboundRedactor.redact("Order 1234567812345678 shipped")
        #expect(!result.didRedact, "a non-Luhn digit run must survive")
        #expect(result.text.contains("1234567812345678"))
    }

    @Test("leaves ordinary meeting numbers alone", arguments: [
        "We agreed a budget of 40000 dollars",
        "The launch is on 2026-09-15 and the review is 2026-10-01",
        "Revenue grew 35 percent to 1200000 this quarter",
        "Meet in room 4021 at 14:30",
        "Ticket CRX-42 blocks the rollout",
        "We need 12 engineers, not 8",
    ])
    func keepsOrdinaryNumbers(sentence: String) {
        // The failure this guards is silent: a redacted figure makes the answer
        // wrong in a way nobody traces back to the filter.
        let result = OutboundRedactor.redact(sentence)
        #expect(!result.didRedact, "redacted ordinary speech: \(result.findings)")
        #expect(result.text == sentence)
    }

    @Test("a long word containing digits is not a card")
    func alphanumericIsNotACard() {
        #expect(!OutboundRedactor.redact("build 4532015112830366x passed").didRedact)
    }

    // MARK: - API keys

    @Test("redacts keys with known prefixes", arguments: [
        "sk-abcdefghijklmnopqrstuvwx",
        "ghp_abcdefghijklmnopqrstuvwxyz1234",
        "xoxb-1234567890-abcdefghijkl",
        "AKIAIOSFODNN7EXAMPLE",
        "glpat-abcdefghijklmnopqrst",
    ])
    func redactsKnownKeys(key: String) {
        let result = OutboundRedactor.redact("the token is \(key) please rotate")
        #expect(result.didRedact, "did not catch \(key)")
        #expect(!result.text.contains(key))
    }

    @Test("a prefix alone is not a key")
    func prefixAloneIsNotAKey() {
        // "sk-" appears in ordinary text; without a body it is not a secret.
        #expect(!OutboundRedactor.redact("the sk-1 flag").didRedact)
    }

    @Test("an ordinary word starting like a prefix survives")
    func lookalikeWordSurvives() {
        #expect(!OutboundRedactor.redact("skiing was great").didRedact)
    }

    // MARK: - Government IDs

    @Test("redacts a hyphenated SSN")
    func redactsSSN() {
        let result = OutboundRedactor.redact("his ssn is 123-45-6789 on file")
        #expect(result.findings.contains { $0.kind == .governmentID })
    }

    @Test("nine bare digits are not treated as an ID")
    func bareDigitsAreNotAnID() {
        // Far too common in speech — a phone number, an order id, a figure.
        #expect(!OutboundRedactor.redact("call 123456789 to confirm").didRedact)
    }

    @Test("never-issued ranges are not IDs", arguments: ["000-45-6789", "666-45-6789", "900-45-6789"])
    func excludesImpossibleRanges(candidate: String) {
        // Excluding these removes a slab of ordinary hyphenated number
        // sequences — part numbers, phone extensions — at no real cost.
        #expect(!OutboundRedactor.isGovernmentID(candidate))
    }

    @Test("a date is not an ID")
    func dateIsNotAnID() {
        #expect(!OutboundRedactor.redact("shipping on 2026-09-15 as agreed").didRedact)
    }

    // MARK: - Labelled credentials

    @Test("redacts a labelled password")
    func redactsLabelledPassword() {
        let result = OutboundRedactor.redact("password: hunter2xyz")
        #expect(result.didRedact)
        #expect(!result.text.contains("hunter2xyz"))
    }

    @Test("an unlabelled word is not a credential")
    func unlabelledWordSurvives() {
        // The label is the evidence. Without it "hunter2xyz" is a word.
        #expect(!OutboundRedactor.redact("hunter2xyz").didRedact)
    }

    @Test("a sentence mentioning passwords is not a credential")
    func discussionOfPasswordsSurvives() {
        // People talk ABOUT passwords on calls constantly. Redacting the
        // sentence would mangle the transcript of a security review.
        let sentence = "We should rotate the password before the audit"
        #expect(OutboundRedactor.redact(sentence).text == sentence)
    }

    // MARK: - User terms

    @Test("redacts a user-supplied term, case-insensitively")
    func redactsUserTerm() {
        let result = OutboundRedactor.redact("Project Falcon ships in May",
                                             userTerms: ["falcon"])
        #expect(result.didRedact)
        #expect(!result.text.lowercased().contains("falcon"))
        #expect(result.findings.first?.kind == .userTerm)
    }

    @Test("a very short user term is ignored")
    func shortTermsIgnored() {
        // A two-character term matches inside half the words in a transcript.
        let sentence = "The plan is on track"
        #expect(OutboundRedactor.redact(sentence, userTerms: ["on"]).text == sentence)
    }

    @Test("every occurrence of a user term goes")
    func redactsAllOccurrences() {
        let result = OutboundRedactor.redact("Falcon and Falcon again", userTerms: ["Falcon"])
        #expect(!result.text.contains("Falcon"))
        #expect(result.findings.count == 2)
    }

    // MARK: - Contract

    @Test("reports what was removed, so it can be corrected")
    func reportsFindings() {
        // The acceptance criterion: a redacted request is visibly marked, and
        // false positives are correctable. Neither is possible unless the
        // finding names what went.
        let result = OutboundRedactor.redact("card 4532015112830366")
        #expect(result.findings.first?.matched == "4532015112830366")
    }

    @Test("clean text is returned byte-identical")
    func cleanTextUnchanged() {
        // The common case by far. Any rewriting here — collapsed spacing,
        // normalised punctuation — would silently alter every prompt.
        let sentence = "Maria will send the contract by Friday, and legal signs it."
        let result = OutboundRedactor.redact(sentence)
        #expect(result.text == sentence)
        #expect(!result.didRedact)
    }

    @Test("empty input is not an error")
    func emptyInput() {
        #expect(OutboundRedactor.redact("").text == "")
        #expect(!OutboundRedactor.redact("").didRedact)
    }

    @Test("redaction never blocks — text always comes back")
    func neverBlocks() {
        // The decision: redact and proceed. A false positive costs a slightly
        // poorer answer, never a dead end.
        let result = OutboundRedactor.redact("card 4532015112830366 and key sk-abcdefghijklmnop")
        #expect(!result.text.isEmpty)
        #expect(result.text.contains(OutboundRedactor.marker))
    }

    @Test("surrounding punctuation and words survive a redaction")
    func preservesSurroundings() {
        let result = OutboundRedactor.redact("Use 4532015112830366, then confirm.")
        #expect(result.text.contains("Use "))
        #expect(result.text.contains("then confirm."))
    }
}

/// JWTs and PEM private-key blocks — added because both are bearer credentials
/// that arrive by PASTE (an auth-header dump, a debug log, a copied .pem) and
/// neither was caught. A session token or a private key reaching a model
/// provider is the exact leak the outbound filter exists to stop.
@Suite("Redactor — JWTs and private keys")
struct RedactorCredentialBlockTests {

    private let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFydGVtIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

    @Test("a JWT in the text is redacted")
    func redactsJWT() {
        let result = OutboundRedactor.redact("Here is my token: \(jwt) — use it.")
        #expect(!result.text.contains("eyJ"))
        #expect(result.text.contains(OutboundRedactor.marker))
        #expect(result.findings.contains { $0.kind == .credential })
    }

    @Test("isJWT accepts a real token and rejects lookalikes", arguments: [
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij", true),
        ("not.a.jwt", false),                       // segments too short, no eyJ
        ("eyJhbGci.short", false),                  // only two segments
        ("api.example.com", false),                 // a hostname
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.", true),  // unsigned: empty sig ok
    ])
    func jwtDetector(token: String, expected: Bool) {
        #expect(OutboundRedactor.isJWT(token) == expected)
    }

    @Test("a hostname with three dotted parts is never a JWT")
    func hostnameIsNotJWT() {
        // The nightmare false positive: redacting every "docs.google.com".
        let result = OutboundRedactor.redact("See docs.google.com and mail.proton.me")
        #expect(result.text.contains("docs.google.com"))
        #expect(result.findings.isEmpty)
    }

    @Test("a PEM private-key block is redacted whole")
    func redactsPEMBlock() {
        let pem = """
        Config below.

        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
        ZWQyNTUxOQAAACA+fake+key+material+that+should+never+leave+the+machine
        -----END OPENSSH PRIVATE KEY-----

        That's the deploy key.
        """
        let result = OutboundRedactor.redact(pem)
        #expect(!result.text.contains("PRIVATE KEY"))
        #expect(!result.text.contains("fake+key+material"))
        #expect(result.text.contains("Config below"), "surrounding prose is untouched")
        #expect(result.text.contains("That's the deploy key"))
        #expect(result.findings.contains { $0.kind == .credential })
    }

    @Test("an RSA private key block is also caught")
    func redactsRSABlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIabc123\n-----END RSA PRIVATE KEY-----"
        #expect(!OutboundRedactor.redact(pem).text.contains("MIIabc123"))
    }

    @Test("the words 'private key' without armour are left alone")
    func plainMentionUntouched() {
        // Talking ABOUT a private key is not pasting one.
        let text = "We should rotate the private key before the audit."
        #expect(OutboundRedactor.redact(text).text == text)
    }
}
