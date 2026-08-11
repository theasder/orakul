import Foundation

/// The ceiling on a model's OUTPUT tokens for one call.
///
/// Every provider path used a hard-coded 1200. That is a sensible answer length
/// and far too small for the one feature that must emit a whole document: the
/// Fireflies transcript merge asks the model to return the entire reconciled
/// transcript as JSON, so the response was cut off mid-object and failed to
/// parse — the feature could not succeed in any mode, direct or managed.
///
/// The ceiling is bounded rather than open: output is the expensive half of a
/// completion. Managed calls reserve against this requested ceiling, so callers
/// may deliberately buy a complete answer without creating an unmetered lever.
enum OutputTokenBudget {
    /// What an ordinary answer gets. Was 1200, which clipped a structured
    /// digest (tables + task list) mid-sentence — reported as "answer wasn't
    /// printed till the end", indistinguishable in the UI from a rendering
    /// bug. Sized so a full structured answer finishes; still bounded, because
    /// output is the expensive half of a completion.
    static let standard = 2_048
    /// The most any single call may request. Sized to cover a full transcript
    /// merge, whose inputs are themselves clipped (14k + 18k characters), so
    /// the merged output cannot meaningfully exceed this.
    static let maximum = 8_000
    /// A user explicitly asked for this answer and sees it as the terminal
    /// result. Drafts, refinements, structured buttons, and council chairman
    /// synthesis use the full tariffed ceiling; silent/background work does not.
    static let explicitUserFacing = maximum
    static let minimum = 256

    /// Resolve a requested ceiling: nil keeps the standard budget, anything
    /// else is clamped into range so a client cannot ask for an unbounded one.
    static func clamp(_ requested: Int?) -> Int {
        guard let requested else { return standard }
        return min(max(requested, minimum), maximum)
    }
}
