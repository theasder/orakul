import Foundation

/// Accounts the UNION of time in which at least one automatic co-pilot watch
/// is enabled during a recording.
///
/// A boolean-at-Stop cannot represent a call where Settings changed halfway
/// through: enabling at the end used to bill the whole call, while disabling
/// at the end discarded time already used. This small value type makes every
/// transition explicit and keeps the arithmetic deterministic under a fake
/// clock in tests.
struct CopilotActiveTimeMeter: Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var activeSince: Date?

    mutating func begin(enabled: Bool, at date: Date) {
        accumulated = 0
        activeSince = enabled ? date : nil
    }

    mutating func transition(to enabled: Bool, at date: Date) {
        if enabled {
            if activeSince == nil { activeSince = date }
        } else if let start = activeSince {
            accumulated += max(0, date.timeIntervalSince(start))
            activeSince = nil
        }
    }

    func seconds(at date: Date) -> Int {
        let open = activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return max(0, Int(floor(accumulated + open)))
    }

    mutating func finish(at date: Date) -> Int {
        transition(to: false, at: date)
        return seconds(at: date)
    }

    mutating func reset() {
        accumulated = 0
        activeSince = nil
    }
}
