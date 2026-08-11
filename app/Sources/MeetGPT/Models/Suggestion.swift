import Foundation

/// One proactive blind-spot suggestion from the brainstormer.
struct Suggestion: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let detail: String
    let kind: SuggestionKind
    /// The transcript phrase this is about, already verified to appear in the
    /// recognized transcript by `SuggestionGrounding`. It was parsed and
    /// checked but then DROPPED, so every card commented on a phrase without
    /// ever showing it. Optional so older encoded suggestions still decode.
    let evidence: String?

    // MARK: Hypothesis-only fields
    //
    // A hypothesis is the one kind that is not an observation: it claims
    // something the call has NOT said and offers a way to settle it. These three
    // arrive only with `kind == .hypothesis`.
    //
    // ALL OPTIONAL, and not merely for tidiness. `Suggestion` is persisted inside
    // saved sessions, and a non-optional property with a default is ignored by
    // Codable's synthesized init — adding one silently fails to decode every
    // session recorded before it existed, taking the whole session with it.

    /// What is probably true but unstated.
    let claim: String?
    /// One thing the user can actually say to settle the claim inside the call.
    /// Without it a claim is a hunch, so the server refuses to label it a
    /// hypothesis at all — which makes this non-nil whenever the kind is.
    let cheapTest: String?
    /// What being wrong about the claim costs. Optional even for a hypothesis:
    /// an unstated cost is a weaker item, not a broken one.
    let costOfMissing: String?

    init(id: UUID = UUID(), title: String, detail: String,
         kind: SuggestionKind, evidence: String? = nil,
         claim: String? = nil, cheapTest: String? = nil, costOfMissing: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
        self.evidence = evidence
        self.claim = claim
        self.cheapTest = cheapTest
        self.costOfMissing = costOfMissing
    }

    /// A hypothesis is only usable when it carries something to test. The kind
    /// alone is not enough — an older session may hold a hypothesis decoded
    /// before these fields existed, and rendering it as one would show a card
    /// with a heading and nothing under it.
    var isTestableHypothesis: Bool {
        kind == .hypothesis
            && !(claim ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(cheapTest ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One-line rendering for exports (Word / Google Docs): "Risk: Title — detail".
    /// A hypothesis exports its test too — that is the part a reader can act on,
    /// and a claim without it reads as an assertion the tool is making.
    var exportLine: String {
        let head = "\(kind.label): \(title)".trimmingCharacters(in: .whitespaces)
        let body = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = body.isEmpty ? head : "\(head) — \(body)"
        if isTestableHypothesis, let cheapTest {
            line += " · Test: \(cheapTest)"
        }
        return line
    }
}

enum SuggestionKind: String, Codable {
    case question, risk, missingInfo = "missing_info", advice, hypothesis

    var label: String {
        switch self {
        case .question:    return "Ask"
        case .risk:        return "Risk"
        case .missingInfo: return "Missing"
        case .advice:      return "Advice"
        // "Hunch" rather than "Hypothesis": it has to read as a read the
        // co-pilot is offering, not a finding it is asserting.
        case .hypothesis:  return "Hunch"
        }
    }
    var systemImage: String {
        switch self {
        case .question:    return "questionmark.bubble"
        case .risk:        return "exclamationmark.triangle"
        case .missingInfo: return "magnifyingglass"
        case .advice:      return "lightbulb"
        // Not "dice": at 11pt it rasterises into an ambiguous dotted square that
        // reads as a glyph error rather than a category — confirmed by rendering
        // the card. Binoculars carry the right meaning at this size: something
        // spotted ahead, not yet confirmed.
        case .hypothesis:  return "binoculars.fill"
        }
    }
}

/// Automatic recommendations should wait for enough recognized speech to
/// distinguish a real discussion from a few short Whisper hallucinations.
enum CopilotTranscriptEligibility {
    struct Evaluation: Equatable {
        let canGenerate: Bool
        /// Diagnostic count used by the regression suite to keep this hot
        /// MainActor predicate bounded even when Instant emits cumulative rows.
        let inspectedScalars: Int
    }

    static let minimumEntries = 3
    static let minimumMaterialCharacters = 240
    private static let materialCharacters = CharacterSet.alphanumerics
    private static let whitespaceCharacters = CharacterSet.whitespacesAndNewlines

    static func canGenerateSuggestions(_ entries: [TranscriptEntry]) -> Bool {
        evaluate(entries).canGenerate
    }

    static func evaluate(_ entries: [TranscriptEntry]) -> Evaluation {
        var materialEntryCount = 0
        var materialCharacterCount = 0
        var inspectedScalars = 0
        // This runs on every ambient scheduler poll. Stop as soon as the fixed
        // threshold is met instead of trimming, joining, and rescanning an
        // entire multi-hour transcript on MainActor. Entry count and character
        // count are saturated independently: once enough characters came from
        // the first row, later rows need only prove that they are non-empty.
        // This matters for cumulative Instant rows, where even the first two
        // entries can each contain most of the call.
        for entry in entries {
            var hasVisibleContent = false
            for scalar in entry.text.unicodeScalars {
                inspectedScalars += 1
                if !whitespaceCharacters.contains(scalar) {
                    hasVisibleContent = true
                }
                if materialCharacterCount < minimumMaterialCharacters,
                   materialCharacters.contains(scalar) {
                    materialCharacterCount += 1
                }
                if hasVisibleContent,
                   materialCharacterCount >= minimumMaterialCharacters {
                    break
                }
            }
            guard hasVisibleContent else { continue }
            materialEntryCount += 1
            if materialEntryCount >= minimumEntries,
               materialCharacterCount >= minimumMaterialCharacters {
                return Evaluation(
                    canGenerate: true, inspectedScalars: inspectedScalars)
            }
        }
        return Evaluation(canGenerate: false, inspectedScalars: inspectedScalars)
    }
}

/// Verifies the model's supporting quote mechanically. Case, punctuation, and
/// whitespace may differ, but the same contiguous words must exist in the
/// recognized transcript.
enum SuggestionGrounding {
    static func contains(evidence: String?, in transcript: String) -> Bool {
        guard let evidence else { return false }
        let normalizedEvidence = normalize(evidence)
        let terms = normalizedEvidence.split(separator: " ")
        guard terms.count >= 3, normalizedEvidence.count >= 12 else { return false }
        return normalize(transcript).contains(normalizedEvidence)
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : " "
        }
        return scalars.joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
