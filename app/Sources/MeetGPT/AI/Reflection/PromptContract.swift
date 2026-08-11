import Foundation

/// The output shape a quick prompt asks for, read out of the prompt itself.
///
/// The prompts already declare their register in prose — "Return a ranked list:
/// Issue • status • owner • next step • target date" — and nothing checked that
/// the answer honoured it. The commonest real failure is not a hallucination but
/// a shrug: three paragraphs where a structured register was requested, which no
/// grounding rule can see because every sentence is perfectly well supported.
///
/// Deliberately blunt. Header matching cannot recognise a field the model
/// renamed, so this under-reports rather than inventing violations — the same
/// stance as the Jaccard duplicate rule.
enum PromptContract {
    /// Fields are separated by "•" in every prompt that declares a shape.
    private static let separator: Character = "•"

    /// A declared register needs at least this many fields before it is worth
    /// judging. Two nouns in a sentence are not a contract.
    static let minimumFields = 3

    /// Below this, an answer is a refusal or a one-liner rather than an attempt
    /// at the register — "no decision has been made yet" is the correct answer
    /// to a decision prompt in a call that has not decided anything.
    static let minimumSubstantiveAnswerChars = 200

    /// Share of the register that must be missing before the answer counts as
    /// having ignored it. At least half, because paraphrase is invisible here.
    static let missingShareToFlag = 0.5

    /// Field names declared by a prompt, lowercased.
    ///
    /// Everything after the last colon of the declaring clause is the register;
    /// each "•"-separated segment names one field, with parentheticals and brace
    /// enumerations stripped as qualifiers rather than names.
    static func declaredFields(in prompt: String) -> [String] {
        guard prompt.contains(separator) else { return [] }
        let segments = prompt.split(separator: separator).map(String.init)
        guard segments.count >= minimumFields else { return [] }

        var fields: [String] = []
        for (index, rawSegment) in segments.enumerated() {
            var segment = rawSegment
            // The first segment carries the lead-in ("Return a ranked list: Issue").
            if index == 0, let colon = segment.lastIndex(of: ":") {
                segment = String(segment[segment.index(after: colon)...])
            }
            // The last carries whatever sentence follows the register.
            if index == segments.count - 1, let stop = segment.firstIndex(of: ".") {
                segment = String(segment[..<stop])
            }
            if let name = fieldName(segment) { fields.append(name) }
        }
        return fields.count >= minimumFields ? fields : []
    }

    /// Which declared fields the answer does not mention.
    static func missingFields(in answer: String, declared: [String]) -> [String] {
        guard !declared.isEmpty else { return [] }
        let haystack = normalize(answer)
        return declared.filter { field in
            // A multi-word field also counts as present under its head noun,
            // which is how models usually shorten "target date" to "date".
            let head = field.split(separator: " ").last.map(String.init) ?? field
            return !haystack.contains(field) && !haystack.contains(head)
        }
    }

    /// True when the answer plainly ignored the register it was given.
    static func ignoresContract(answer: String, promptText: String) -> Bool {
        let declared = declaredFields(in: promptText)
        guard !declared.isEmpty else { return false }
        guard answer.trimmingCharacters(in: .whitespacesAndNewlines).count
                >= minimumSubstantiveAnswerChars else { return false }
        let missing = missingFields(in: answer, declared: declared)
        return Double(missing.count) / Double(declared.count) >= missingShareToFlag
    }

    // MARK: - Internals

    /// Strips qualifiers and punctuation, keeping the field's name.
    private static func fieldName(_ segment: String) -> String? {
        var text = segment
        // "(calibrated %, note the base rate)" and "{a | b}" qualify a field;
        // they are not part of its name.
        text = text.replacingOccurrences(
            of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\{[^}]*\\}", with: " ", options: .regularExpression)
        let name = normalize(text)
        // One to three words is a field name; longer is a sentence that happened
        // to contain a bullet.
        let words = name.split(separator: " ")
        guard (1...3).contains(words.count), !name.isEmpty else { return nil }
        return name
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " ? String($0) : " "
        }
        return scalars.joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
