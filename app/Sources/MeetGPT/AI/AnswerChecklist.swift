import Foundation

/// Finds a checklist inside an answer.
///
/// When the assistant replies with a list of things to do, a generic "Do this"
/// chip row underneath reads as unrelated furniture — the answer already IS the
/// list. Naming the connection ("Turn these 5 into tasks") makes the button
/// belong to the thing above it instead of floating below it.
///
/// Deliberately conservative. A false positive renames the button after a list
/// that is not a checklist at all, which is worse than leaving the generic
/// label alone, so prose bullets and one-item lists do not count.
enum AnswerChecklist {

    /// Fewer than this is a sentence with a dash in front, not a checklist.
    static let minimumItems = 2

    /// A markdown checkbox item: `- [ ] text`, `* [x] text`. The strongest
    /// signal, because nothing writes `- [ ]` by accident.
    static func isCheckboxItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard let bullet = rest.first, "-*+".contains(bullet) else { return false }
        rest = rest.dropFirst().drop { $0 == " " }
        guard rest.first == "[" else { return false }
        rest = rest.dropFirst()
        guard let box = rest.first, box == " " || box == "x" || box == "X" else { return false }
        rest = rest.dropFirst()
        guard rest.first == "]" else { return false }
        rest = rest.dropFirst()
        // Requires a space then real text: "- []" alone is not an item.
        guard rest.first == " " else { return false }
        return rest.contains { !$0.isWhitespace }
    }

    /// An ordered step: `1. text`, `2) text`. A numbered list of actions is a
    /// checklist even without checkboxes.
    static func isOrderedItem(_ line: String) -> Bool {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        rest = rest.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return false }
        rest = rest.dropFirst()
        guard rest.first == " " else { return false }
        return rest.contains { !$0.isWhitespace }
    }

    /// Number of checklist items, or 0 when the answer has no checklist.
    static func itemCount(in answer: String) -> Int {
        let lines = answer.components(separatedBy: .newlines)

        let checkboxes = lines.filter(isCheckboxItem).count
        // Checkboxes are unambiguous, so they win outright and are not mixed
        // with the weaker ordered-list signal.
        if checkboxes >= minimumItems { return checkboxes }

        let ordered = lines.filter(isOrderedItem).count
        if ordered >= minimumItems { return ordered }

        return 0
    }

    static func contains(in answer: String) -> Bool {
        itemCount(in: answer) > 0
    }

    /// What the action group should be called above this answer.
    ///
    /// Returns nil when there is no checklist, so the caller keeps its default
    /// rather than this type inventing copy for the ordinary case.
    static func actionGroupTitle(forAnswer answer: String,
                                 hasTaskAction: Bool) -> String? {
        // Only worth renaming when the button actually creates tasks. Renaming
        // it above a "Draft an email" action would describe the wrong thing.
        guard hasTaskAction else { return nil }
        let count = itemCount(in: answer)
        guard count >= minimumItems else { return nil }
        return "Turn these \(count) into tasks"
    }
}
