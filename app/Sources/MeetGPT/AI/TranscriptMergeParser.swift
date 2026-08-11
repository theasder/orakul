import Foundation

/// Reads the transcript-merge model output leniently.
///
/// Strict `JSONDecoder` on the whole document was an all-or-nothing bet, and it
/// lost in two different ways in practice:
///
///  1. **Truncation.** The merge emits the entire reconciled transcript, so it
///     is the longest output the app ever asks for. Whenever it exceeded the
///     output budget the JSON simply stopped mid-object and NOTHING survived —
///     not even the summary the model had already finished writing.
///  2. **A malformed separator.** Real output has arrived as
///     `{"summary":"…" "entries":[…]}` — no comma between the two members.
///     Strict parsing rejects the entire document over one byte.
///
/// So each member is located and read independently, and `entries` is collected
/// object by object. A truncated array yields every complete object before the
/// cut, and a broken separator costs nothing at all.
enum TranscriptMergeParser {
    struct Item: Decodable {
        let offsetSec: Double?
        let speaker: String?
        let source: String?
        let text: String?
    }

    struct Parsed: Equatable {
        let summary: String?
        let items: [Item]
        /// True when the `entries` array never closed — the output ran out of
        /// room. The caller must NOT treat such a merge as the whole meeting.
        let isTruncated: Bool

        static func == (lhs: Parsed, rhs: Parsed) -> Bool {
            lhs.summary == rhs.summary
                && lhs.isTruncated == rhs.isTruncated
                && lhs.items.count == rhs.items.count
        }
    }

    static func parse(_ raw: String) -> Parsed {
        let scalars = Array(raw)
        return Parsed(
            summary: stringValue(forKey: "summary", in: scalars),
            items: entries(in: scalars).items,
            isTruncated: !entries(in: scalars).closed
        )
    }

    // MARK: - Members

    /// The string value of a top-level key, read directly rather than via a
    /// whole-document parse, so a neighbouring syntax error cannot hide it.
    static func stringValue(forKey key: String, in scalars: [Character]) -> String? {
        guard let keyEnd = indexAfterKey(key, in: scalars) else { return nil }
        var index = keyEnd
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\n" { index += 1 }
        guard index < scalars.count, scalars[index] == "\"" else { return nil }
        index += 1

        var value = ""
        while index < scalars.count {
            let character = scalars[index]
            if character == "\\", index + 1 < scalars.count {
                // Preserve the escape pair; JSONSerialization decodes it below.
                value.append(character)
                value.append(scalars[index + 1])
                index += 2
                continue
            }
            if character == "\"" { break }
            value.append(character)
            index += 1
        }
        return unescape(value)
    }

    /// Every COMPLETE `{…}` object inside the `entries` array, plus whether the
    /// array closed. Objects are decoded one at a time so a single malformed
    /// entry costs only itself.
    static func entries(in scalars: [Character]) -> (items: [Item], closed: Bool) {
        guard let keyEnd = indexAfterKey("entries", in: scalars) else { return ([], true) }
        var index = keyEnd
        while index < scalars.count, scalars[index] != "[" {
            // Bail out if the array never starts (nothing usable follows).
            if scalars[index] == "}" { return ([], true) }
            index += 1
        }
        guard index < scalars.count else { return ([], false) }
        index += 1

        var items: [Item] = []
        var closed = false
        let decoder = JSONDecoder()

        while index < scalars.count {
            if scalars[index] == "]" { closed = true; break }
            guard scalars[index] == "{" else { index += 1; continue }
            guard let end = indexAfterObject(startingAt: index, in: scalars) else {
                break   // object never closed — the output was cut here
            }
            let object = String(scalars[index..<end])
            if let data = object.data(using: .utf8),
               let item = try? decoder.decode(Item.self, from: data) {
                items.append(item)
            }
            index = end
        }
        return (items, closed)
    }

    // MARK: - Scanning

    private static func indexAfterKey(_ key: String, in scalars: [Character]) -> Int? {
        let needle = Array("\"\(key)\"")
        guard scalars.count > needle.count else { return nil }
        for start in 0...(scalars.count - needle.count) {
            guard Array(scalars[start..<(start + needle.count)]) == needle else { continue }
            var index = start + needle.count
            while index < scalars.count, scalars[index] == " " { index += 1 }
            guard index < scalars.count, scalars[index] == ":" else { continue }
            return index + 1
        }
        return nil
    }

    /// Index just past the balanced object beginning at `start`, or nil when it
    /// never closes. String-aware so a brace inside an utterance cannot end it.
    private static func indexAfterObject(startingAt start: Int, in scalars: [Character]) -> Int? {
        var depth = 0
        var index = start
        var inString = false
        while index < scalars.count {
            let character = scalars[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        guard let data = "\"\(value)\"".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]) as? String else {
            return value
        }
        return decoded
    }
}
