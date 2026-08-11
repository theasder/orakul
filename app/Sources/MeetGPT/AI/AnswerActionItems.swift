import Foundation

/// Pulls discrete action items out of a free-form answer so a tracker chip can
/// file N tasks instead of one task containing the whole answer.
///
/// The structured Tasks button already produces a typed `TasksArtifact`; this is
/// the same idea for prose the model wrote without a contract. It reuses
/// `TasksArtifact.Item` deliberately — `TaskWriteback` already knows how to turn
/// one of those into a real tracker issue against a live schema, and a second
/// item type would mean a second mapping to keep in sync.
///
/// Parsing, not inference: an owner is only recorded when the answer states one.
/// Inventing an assignee creates a ticket someone did not agree to.
enum AnswerActionItems {

    /// Never file more than this from one answer. A runaway list is usually a
    /// mis-parse, and twenty accidental tickets is somebody's afternoon.
    static let maxItems = 12

    /// Markers that identify the owner/due portion of a bullet.
    private static let ownerPrefixes = ["owner:", "assigned to", "assignee:", "@"]
    private static let duePrefixes = ["due", "by ", "eod", "next week", "this week"]

    /// Parse the answer's list items into filable tasks. Returns [] when the
    /// answer is prose — nothing here guesses a task out of a paragraph.
    static func parse(_ answer: String) -> [TasksArtifact.Item] {
        var items: [TasksArtifact.Item] = []

        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let body = listItemBody(line) else { continue }
            guard body.count >= 6 else { continue }

            let parts = split(body)
            // A bullet with neither an owner nor a date is usually a statement,
            // not a commitment. Requiring one keeps explanatory lists out.
            guard parts.owner != nil || parts.due != nil || isCheckbox(line) else { continue }

            items.append(TasksArtifact.Item(
                task: parts.task,
                owner: parts.owner,
                due: parts.due,
                doneCheck: nil,
                dependency: nil,
                sourceRef: nil,
                tracked: false))
            if items.count == maxItems { break }
        }
        return items
    }

    // MARK: - Line shapes

    private static func isCheckbox(_ line: String) -> Bool {
        line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") || line.hasPrefix("* [ ]") || line.hasPrefix("* [x]")
    }

    /// The text of a markdown list item, or nil when the line is not one.
    private static func listItemBody(_ line: String) -> String? {
        for marker in ["- [ ]", "- [x]", "* [ ]", "* [x]"] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Split "Draft the pricing page — owner: Ana, due Friday" into its parts.
    /// The task keeps the speaker's wording; only the trailing metadata clause
    /// is peeled off.
    private static func split(_ body: String) -> (task: String, owner: String?, due: String?) {
        // Metadata conventionally follows an em/en dash or a parenthesis.
        let separators: [String] = [" — ", " – ", " -- ", " ("]
        var head = body
        var tail = ""
        for separator in separators {
            if let range = body.range(of: separator) {
                head = String(body[..<range.lowerBound])
                tail = String(body[range.upperBound...])
                break
            }
        }
        if tail.isEmpty {
            // No separator: metadata may still be inline ("Ana to draft by Friday").
            tail = body
        }
        let cleanedTail = tail.trimmingCharacters(in: CharacterSet(charactersIn: " )"))

        return (
            task: head.trimmingCharacters(in: .whitespaces),
            owner: value(in: cleanedTail, afterAnyOf: ownerPrefixes),
            due: value(in: cleanedTail, afterAnyOf: duePrefixes)
        )
    }

    /// The clause following a marker, up to the next comma or the end.
    private static func value(in text: String, afterAnyOf markers: [String]) -> String? {
        let lower = text.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            var rest = String(text[range.upperBound...])
            // "@ana" carries the name with no space; "owner: Ana" has one.
            if marker == "@" { rest = String(text[range.lowerBound...]).dropFirst().description }
            let clause = rest
                .components(separatedBy: CharacterSet(charactersIn: ",;"))
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let value = marker == "by " ? "\(marker)\(clause)" : clause
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.count <= 60 { return trimmed }
        }
        return nil
    }
}
