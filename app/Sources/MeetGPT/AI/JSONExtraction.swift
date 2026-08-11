import Foundation

/// Pull the JSON payload out of a model's reply.
///
/// Every service that asks a model for JSON has to cope with the model wrapping
/// it in prose ("Here's the JSON you asked for: {...} — let me know…") or in a
/// ```json fence. Eight services each carried their own private copy of the
/// same three lines to do it.
///
/// Eight copies of a parsing rule is eight places to fix when a model starts
/// answering slightly differently, and — as the CSV escaper showed — the
/// realistic outcome is that a fix lands in one copy and silently misses the
/// rest. One implementation, one set of tests.
enum JSONExtraction {

    /// The outermost `{…}` span in `text`, or nil when there is no plausible
    /// object. Deliberately span-based rather than brace-counting: model output
    /// is frequently truncated mid-object, and the widest span gives the
    /// decoder its best chance while still failing cleanly when it cannot parse.
    static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// The outermost `[…]` span — the array equivalent, for listing replies.
    static func firstArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// Decode `T` from whatever JSON object the reply contains. Returns nil
    /// rather than throwing: at every call site a malformed reply means "this
    /// pass produced nothing", never a crash and never a partial artifact.
    static func decodeObject<T: Decodable>(_ type: T.Type, from text: String,
                                           decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard let json = firstObject(in: text),
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
