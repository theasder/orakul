import Foundation
import MCP

/// A bounded agentic step: the model may ask to READ from a connected app
/// mid-answer, the result re-enters the answer, and writes stay staged.
///
/// Three things bound it, and each exists because of a specific failure.
///
/// **A per-turn budget.** Without one, a model that keeps not-quite-finding what
/// it wants will spend a user's connector quota and their patience on a single
/// question. The budget is per turn rather than per session so one expensive
/// answer cannot starve the next.
///
/// **A deadline, tighter on the live path.** A blind spot that arrives after the
/// topic has moved on is not late information, it is noise — the room has
/// already decided. So a call that cannot finish inside the remaining window is
/// refused before it starts rather than cancelled after it has cost the time.
///
/// **The existing read/write policy, not a second one.** `MCPImportToolPolicy`
/// already decides what counts as a read, fail-closed, and has been tuned
/// against real connector catalogues. A second classifier here would drift from
/// it, and the drift would be invisible until something wrote to a user's CRM.
/// Writes are not made safe by this step; they remain staged for confirmation.
///
/// Every call is attributed. An answer that quietly consulted someone's inbox
/// and did not say so is a worse product than one that could not consult it at
/// all.
enum AgenticReadStep {

    /// Reads one answer may make. Three is enough to look something up, follow
    /// one reference and check a second source; beyond that the model is
    /// usually searching rather than answering.
    static let maxCallsPerTurn = 3

    /// While a call is live. A copilot line is only useful in the ~15 seconds
    /// the topic stays current, and the answer still has to be generated after
    /// the tool returns.
    static let liveDeadline: TimeInterval = 4

    /// After the call, when nobody is waiting on the conversation.
    static let idleDeadline: TimeInterval = 20

    static func deadline(isRecording: Bool) -> TimeInterval {
        isRecording ? liveDeadline : idleDeadline
    }

    /// Why a requested call was not made. Every case is reported to the user
    /// rather than silently dropped: an answer that is missing information
    /// because a tool was refused reads as a worse answer unless it says so.
    enum Refusal: String, Equatable {
        case budgetSpent
        case notAReadTool
        case deadlinePassed
        case unknownTool

        var explanation: String {
            switch self {
            case .budgetSpent:
                return "reached this answer's limit of \(maxCallsPerTurn) lookups"
            case .notAReadTool:
                return "that tool can change data, so it is staged for confirmation instead"
            case .deadlinePassed:
                return "not enough time left in this turn to finish the lookup"
            case .unknownTool:
                return "no connected app offers that tool"
            }
        }
    }

    /// One call, recorded so the answer can name its sources.
    struct Attribution: Equatable {
        let tool: String
        let server: String
        /// False when the tool ran but returned nothing usable — distinct from
        /// a refusal, and worth distinguishing: "I looked and found nothing" is
        /// a different answer from "I did not look".
        let producedResult: Bool

        var line: String {
            producedResult ? "\(server) · \(tool)" : "\(server) · \(tool) (no result)"
        }
    }

    /// The decision for one requested call.
    enum Decision: Equatable {
        case allow
        case refuse(Refusal)

        var isAllowed: Bool { if case .allow = self { return true }; return false }
    }

    /// Running state for one answer.
    struct Turn: Equatable {
        private(set) var attributions: [Attribution] = []
        private(set) var refusals: [Refusal] = []
        /// Calls actually made, which is what the budget counts. A refusal costs
        /// nothing, so a model that asks for a write tool has not spent a lookup.
        var callsMade: Int { attributions.count }
        var remaining: Int { max(0, maxCallsPerTurn - callsMade) }

        init() {}

        mutating func record(_ attribution: Attribution) {
            attributions.append(attribution)
        }

        mutating func record(_ refusal: Refusal) {
            // Deduplicated: a model that asks three times for the same forbidden
            // tool should produce one note, not three.
            guard !refusals.contains(refusal) else { return }
            refusals.append(refusal)
        }

        /// The source list appended to the answer. Empty when nothing was
        /// consulted, so an ordinary answer gains no footer.
        var sourceNote: String {
            guard !attributions.isEmpty || !refusals.isEmpty else { return "" }
            var parts: [String] = []
            if !attributions.isEmpty {
                parts.append("Consulted: " + attributions.map(\.line).joined(separator: ", "))
            }
            if !refusals.isEmpty {
                parts.append("Not consulted: "
                             + refusals.map(\.explanation).joined(separator: "; "))
            }
            return parts.joined(separator: "\n")
        }
    }

    /// Whether a requested call may proceed.
    ///
    /// `elapsed` and `isRecording` decide the deadline; `tool` is nil when the
    /// model named something no connected server offers.
    static func decide(tool: Tool?,
                       turn: Turn,
                       elapsed: TimeInterval,
                       isRecording: Bool) -> Decision {
        guard let tool else { return .refuse(.unknownTool) }
        // Budget before policy: the cheapest check first, and a spent budget is
        // the more useful thing to tell the model.
        guard turn.remaining > 0 else { return .refuse(.budgetSpent) }
        // The same classifier the import sheet uses. Not a second one — a
        // divergence here would be invisible until it wrote to something.
        guard MCPImportToolPolicy.isSafeForImport(tool) else { return .refuse(.notAReadTool) }
        guard elapsed < deadline(isRecording: isRecording) else {
            return .refuse(.deadlinePassed)
        }
        return .allow
    }
}
