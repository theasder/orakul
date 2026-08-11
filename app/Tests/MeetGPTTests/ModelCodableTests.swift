import Testing
import Foundation
@testable import MeetGPT

/// Codable round-trips for the value-type models that persist to disk/backend,
/// plus the small pure computed properties (source counts, verdict labels,
/// token-skew expiry) the UI keys off. Encoding then decoding must preserve the
/// key fields; the derived helpers must be deterministic.
@Suite("Suggestion Codable")
struct SuggestionCodableTests {
    @Test("round-trips through JSON preserving every field")
    func roundTrip() throws {
        let original = Suggestion(id: UUID(), title: "Ask about the migration budget",
                                  detail: "They never named a number.", kind: .question)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Suggestion.self, from: data)
        #expect(decoded == original)   // Equatable includes the id
    }

    @Test("every SuggestionKind survives a round-trip")
    func allKindsRoundTrip() throws {
        for kind in [SuggestionKind.question, .risk, .missingInfo, .advice] {
            let s = Suggestion(title: "t", detail: "d", kind: kind)
            let decoded = try JSONDecoder().decode(Suggestion.self,
                                                   from: try JSONEncoder().encode(s))
            #expect(decoded.kind == kind)
        }
    }

    @Test("SuggestionKind raw values match the backend contract")
    func kindRawValues() {
        #expect(SuggestionKind.question.rawValue == "question")
        #expect(SuggestionKind.risk.rawValue == "risk")
        #expect(SuggestionKind.missingInfo.rawValue == "missing_info")
        #expect(SuggestionKind.advice.rawValue == "advice")
        #expect(SuggestionKind(rawValue: "missing_info") == .missingInfo)
        #expect(SuggestionKind(rawValue: "nope") == nil)
    }

    @Test("kind label and systemImage map each case")
    func kindPresentation() {
        #expect(SuggestionKind.question.label == "Ask")
        #expect(SuggestionKind.risk.label == "Risk")
        #expect(SuggestionKind.missingInfo.label == "Missing")
        #expect(SuggestionKind.advice.label == "Advice")
        #expect(SuggestionKind.question.systemImage == "questionmark.bubble")
        #expect(SuggestionKind.risk.systemImage == "exclamationmark.triangle")
        #expect(SuggestionKind.missingInfo.systemImage == "magnifyingglass")
        #expect(SuggestionKind.advice.systemImage == "lightbulb")
    }
}

@Suite("ContextSet Codable")
struct ContextSetCodableTests {
    private func sampleFile(name: String = "brief.md") -> ImportedContextFile {
        ImportedContextFile(name: name, text: "Q3 renewal context")
    }

    @Test("round-trips including nested files")
    func roundTrip() throws {
        let original = ContextSet(name: "Acme renewal",
                                  files: [sampleFile(), sampleFile(name: "notes.txt")],
                                  notes: "Push for annual.")
        let decoded = try JSONDecoder().decode(ContextSet.self,
                                               from: try JSONEncoder().encode(original))
        #expect(decoded == original)   // Equatable, so covers id/name/files/notes
    }

    @Test("sourceCount counts files plus a non-empty notes block")
    func sourceCountWithNotes() {
        let set = ContextSet(name: "s", files: [sampleFile(), sampleFile()],
                             notes: "some real notes")
        #expect(set.sourceCount == 3)   // 2 files + 1 notes block
    }

    @Test("sourceCount ignores blank or whitespace-only notes")
    func sourceCountBlankNotes() {
        #expect(ContextSet(name: "s", files: [sampleFile()], notes: "").sourceCount == 1)
        #expect(ContextSet(name: "s", files: [sampleFile()], notes: "   \n\t").sourceCount == 1)
        #expect(ContextSet(name: "s", files: [], notes: "").sourceCount == 0)
        #expect(ContextSet(name: "s", files: [], notes: "note").sourceCount == 1)
    }
}

@Suite("ImportedContextFile Codable")
struct ImportedContextFileCodableTests {
    @Test("round-trips and reports its character count")
    func roundTripAndCharCount() throws {
        let original = ImportedContextFile(name: "spec.md", text: "hello")
        let decoded = try JSONDecoder().decode(ImportedContextFile.self,
                                               from: try JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.charCount == 5)
        #expect(ImportedContextFile(name: "empty", text: "").charCount == 0)
    }
}

@Suite("WheesprSession Codable")
struct WheesprSessionCodableTests {
    private func session(expiry: Date, displayName: String? = "Ada") -> WheesprSession {
        WheesprSession(accessToken: "access", refreshToken: "refresh",
                       accessExpiry: expiry, email: "ada@example.com",
                       displayName: displayName)
    }

    @Test("round-trips tokens, email, and expiry through JSON")
    func roundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1_770_000_000)
        let original = session(expiry: expiry)
        let decoded = try JSONDecoder().decode(WheesprSession.self,
                                               from: try JSONEncoder().encode(original))
        #expect(decoded.accessToken == original.accessToken)
        #expect(decoded.refreshToken == original.refreshToken)
        #expect(decoded.email == original.email)
        #expect(decoded.displayName == original.displayName)
        #expect(abs(decoded.accessExpiry.timeIntervalSince1970
                    - expiry.timeIntervalSince1970) < 0.001)
    }

    @Test("nil displayName survives the round-trip")
    func nilDisplayName() throws {
        let original = session(expiry: Date(timeIntervalSince1970: 1_770_000_000),
                               displayName: nil)
        let decoded = try JSONDecoder().decode(WheesprSession.self,
                                               from: try JSONEncoder().encode(original))
        #expect(decoded.displayName == nil)
    }

    @Test("isAccessExpired treats past and near-future expiries as expired")
    func expiryLogic() {
        // Already elapsed → expired.
        #expect(session(expiry: Date(timeIntervalSinceNow: -3600)).isAccessExpired)
        // 30s out, inside the 60s skew guard → still treated as expired.
        #expect(session(expiry: Date(timeIntervalSinceNow: 30)).isAccessExpired)
        // Comfortably in the future → live.
        #expect(!session(expiry: Date(timeIntervalSinceNow: 3600)).isAccessExpired)
    }
}

/// FactClaim itself is not Codable (it carries a generated `id` and view-facing
/// verdicts), but its verdict enums back the fact-check UI labels, so pin them.
@Suite("FactClaim verdict presentation")
struct FactClaimVerdictTests {
    @Test("Status raw values match the backend verdict strings")
    func statusRawValues() {
        #expect(FactClaim.Status.verified.rawValue == "verified")
        #expect(FactClaim.Status.contradicted.rawValue == "contradicted")
        #expect(FactClaim.Status.needsContext.rawValue == "needs_context")
        #expect(FactClaim.Status.unverifiable.rawValue == "unverifiable")
        #expect(FactClaim.Status.inconsistent.rawValue == "inconsistent")
        #expect(FactClaim.Status(rawValue: "needs_context") == .needsContext)
        #expect(FactClaim.Status(rawValue: "inconsistent") == .inconsistent)
        #expect(FactClaim.Status(rawValue: "bogus") == nil)
    }

    @Test("Status label maps each verdict")
    func statusLabels() {
        #expect(FactClaim.Status.verified.label == "Verified")
        #expect(FactClaim.Status.contradicted.label == "Contradicted")
        #expect(FactClaim.Status.needsContext.label == "Needs source")
        #expect(FactClaim.Status.unverifiable.label == "Not checkable")
        // Internal numeric conflict: the call disagreeing with itself, which is a
        // different finding from the attached context disagreeing with the call.
        #expect(FactClaim.Status.inconsistent.label == "Doesn't add up")
    }

    @Test("Confidence label capitalizes its raw value")
    func confidenceLabels() {
        #expect(FactClaim.Confidence.high.label == "High")
        #expect(FactClaim.Confidence.medium.label == "Medium")
        #expect(FactClaim.Confidence.low.label == "Low")
        #expect(FactClaim.Confidence.high.rawValue == "high")
    }
}
