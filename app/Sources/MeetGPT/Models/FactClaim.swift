import Foundation

/// One fact-checked claim pulled from the transcript and verified against the
/// call's user-provided context.
///
/// Codable so a checked call keeps its verdicts. Until it was, fact-checking
/// was the one workflow whose output vanished at the end of the meeting: not
/// reviewable from History, and invisible to the reflection eval, which can
/// only judge what a session persists.
struct FactClaim: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case verified                       // context supports it
        case contradicted                   // context contradicts it
        case needsContext = "needs_context" // checkable, but context doesn't cover it
        case unverifiable                   // opinion / prediction / too vague
        /// The CALL contradicts itself, or the stated arithmetic does not work.
        /// Distinct from `contradicted`, which means the attached context
        /// disagrees: this one needs no context at all, and its `source` quotes
        /// the transcript rather than a document. Kept separate because the
        /// backend only accepts a context-grounded source for verified /
        /// contradicted, and would otherwise downgrade every internal finding.
        case inconsistent

        var label: String {
            switch self {
            case .verified:     return "Verified"
            case .contradicted: return "Contradicted"
            case .needsContext: return "Needs source"
            case .unverifiable: return "Not checkable"
            case .inconsistent: return "Doesn't add up"
            }
        }
    }

    /// How solid the verdict is, given the evidence at hand.
    enum Confidence: String, Codable {
        case high, medium, low

        var label: String { rawValue.capitalized }
    }

    let id = UUID()
    let text: String
    let status: Status
    let explanation: String
    /// The context snippet that supports/contradicts the claim, when applicable.
    let source: String?
    /// Verdict confidence (nil when the checker didn't rate it — e.g. legacy backend).
    let confidence: Confidence?
    /// The sharpest question to ask the speaker to confirm or falsify the claim.
    let counterQuestion: String?
    /// Where the verdict's evidence came from — "attached" (a document the user
    /// added), "web" (a retrieved page, item 11), or "none". Optional so every
    /// session saved before the web lane still decodes; a String rather than an
    /// enum so an unknown future provenance degrades to "not web" instead of
    /// failing the whole session decode.
    let provenance: String?
    /// The retrieved page behind a web-checked verdict. Set only when
    /// `provenance == "web"`; the reader must be able to reach the source or
    /// the verdict is worth less than no verdict.
    let sourceUrl: String?
    let sourceTitle: String?

    init(text: String, status: Status, explanation: String, source: String?,
         confidence: Confidence? = nil, counterQuestion: String? = nil,
         provenance: String? = nil, sourceUrl: String? = nil, sourceTitle: String? = nil) {
        self.text = text
        self.status = status
        self.explanation = explanation
        self.source = source
        self.confidence = confidence
        self.counterQuestion = counterQuestion
        self.provenance = provenance
        self.sourceUrl = sourceUrl
        self.sourceTitle = sourceTitle
    }

    /// True when this verdict was grounded in a retrieved web page.
    var isWebChecked: Bool { provenance == "web" }

    /// `id` is deliberately absent: it is a fresh UUID per instance for
    /// SwiftUI's benefit, not identity worth persisting, and a `let` with an
    /// initial value cannot be assigned by a synthesized decoder anyway.
    private enum CodingKeys: String, CodingKey {
        case text, status, explanation, source, confidence, counterQuestion
        case provenance, sourceUrl, sourceTitle
    }
}
