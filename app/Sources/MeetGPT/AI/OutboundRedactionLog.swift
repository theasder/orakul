import Foundation

/// What the redactor removed this session, so the user can see it.
///
/// A redaction nobody can see is indistinguishable from the model simply
/// answering badly. The acceptance criteria ask for a visibly marked request
/// and correctable false positives, and both need the removals to survive the
/// call that produced them.
///
/// Session-scoped and in memory only: this holds the very strings that were
/// judged too sensitive to send, so writing them to disk would defeat the
/// filter that produced them.
@MainActor
final class OutboundRedactionLog: ObservableObject {
    static let shared = OutboundRedactionLog()

    /// Counts by kind, newest session only. Counts rather than the matched
    /// text for the summary line — "2 card numbers" is what a user needs to
    /// decide whether the filter is behaving.
    @Published private(set) var counts: [OutboundRedactor.Finding.Kind: Int] = [:]
    @Published private(set) var total = 0

    nonisolated func record(_ findings: [OutboundRedactor.Finding]) {
        guard !findings.isEmpty else { return }
        Task { @MainActor in
            for finding in findings {
                counts[finding.kind, default: 0] += 1
                total += 1
            }
        }
    }

    func reset() {
        counts = [:]
        total = 0
    }

    /// One line for the UI, or nil when nothing was removed — a marker shown on
    /// every request would train people to ignore it.
    var summary: String? {
        guard total > 0 else { return nil }
        let parts = counts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \(label(for: $0.key))" }
        return "Removed before sending: " + parts.joined(separator: ", ")
    }

    private func label(for kind: OutboundRedactor.Finding.Kind) -> String {
        switch kind {
        case .paymentCard: return "card number"
        case .apiKey: return "API key"
        case .governmentID: return "ID number"
        case .credential: return "credential"
        case .userTerm: return "blocked term"
        }
    }
}
