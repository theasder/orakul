import Foundation
import SwiftUI

/// How large the READING surfaces are — the transcript and the assistant
/// answer, the two things people look at for an hour.
///
/// Deliberately not a global type scale. Growing every font would push the
/// chrome around: the sidebar is ~300pt with stacked cards, the composer and
/// the record controls are laid out against fixed heights, and at the smallest
/// supported window a uniform scale collides them. What someone means by
/// "bigger text" is the prose, so only the prose moves.
enum ReadingTextScale {

    /// Multipliers, not point sizes. `Typo.reading` is 15pt today and may be
    /// retuned; a scale expressed as a factor follows it, while a second table
    /// of absolute sizes would silently diverge.
    static let smallest = 0.85
    static let standard = 1.0
    static let largest = 1.6

    /// The steps the control offers. Small enough to feel like a nudge, few
    /// enough to be a segmented control rather than a slider nobody can land
    /// precisely.
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.45, 1.6]

    /// A stored value that may be anything — an old build, a hand-edited
    /// preference file, a NaN from a corrupted read.
    static func clamp(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return standard }
        return min(max(raw, smallest), largest)
    }

    /// Point size for a base size at a given scale, rounded to a whole point.
    ///
    /// Fractional sizes render but make line heights inconsistent between
    /// paragraphs that happen to round differently, which reads as uneven
    /// spacing rather than as a larger font.
    static func pointSize(base: Double, scale: Double) -> Double {
        (base * clamp(scale)).rounded()
    }

    /// The next step up or down, for the keyboard shortcuts. Returns the same
    /// value at the ends rather than wrapping — wrapping from largest to
    /// smallest on a repeated keypress is never what was meant.
    static func step(from current: Double, by direction: Int) -> Double {
        let clamped = clamp(current)
        let index = steps.firstIndex { abs($0 - clamped) < 0.001 }
            ?? steps.firstIndex { $0 >= clamped }
            ?? steps.count - 1
        let next = index + (direction >= 0 ? 1 : -1)
        return steps[min(max(next, 0), steps.count - 1)]
    }

    /// Short label for the control, e.g. "115%".
    static func label(for scale: Double) -> String {
        "\(Int((clamp(scale) * 100).rounded()))%"
    }
}


// MARK: - Environment

private struct ReadingTextScaleKey: EnvironmentKey {
    static let defaultValue = ReadingTextScale.standard
}

extension EnvironmentValues {
    /// Reading size for long-form prose. An environment value rather than a
    /// parameter so row views deep in a list do not each have to be handed it,
    /// and so nothing in the chrome accidentally picks it up.
    var readingTextScale: Double {
        get { self[ReadingTextScaleKey.self] }
        set { self[ReadingTextScaleKey.self] = newValue }
    }
}
