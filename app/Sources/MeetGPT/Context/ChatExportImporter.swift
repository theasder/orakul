import Foundation

/// Turns a ChatGPT or Claude **data export** into readable meeting context.
///
/// Neither vendor exposes an API to read a user's conversations — the only
/// sanctioned route is the user exporting their own data (ChatGPT: Settings →
/// Data controls → Export; Claude: Settings → Account → Export), which arrives
/// as a zip containing `conversations.json`. This parses that file.
///
/// **Why it caps rather than importing everything.** A full export is mostly
/// noise for any given meeting — debugging, drafts, one-off questions — and the
/// prompt budget charges for size past a 6k-token baseline, so a bulk dump costs
/// credits *and* makes answers worse by burying the transcript. Only the most
/// recent conversations are kept, under a hard character budget, and the header
/// states exactly what was dropped. Silent truncation would be worse than the
/// cap: the user needs to know their old threads are not in there.
enum ChatExportImporter {
    /// Newest N conversations. Recency is the only ranking signal available at
    /// import time — the workflow layer does the real relevance work later.
    static let maxConversations = 40
    /// Hard ceiling on the produced text. Roughly 15k tokens: large enough to be
    /// useful, small enough that one import cannot dominate a prompt.
    static let maxCharacters = 60_000
    /// Per-message clip. Long pasted logs in a chat are rarely the useful part.
    static let maxMessageCharacters = 2_000

    struct Conversation {
        let title: String
        let date: Date?
        let messages: [(role: String, text: String)]
    }

    enum Source: String {
        case chatGPT = "ChatGPT"
        case claude = "Claude"
    }

    /// Parse an export. Returns nil when the JSON is not a chat export, so the
    /// caller can fall back to treating the file as plain text.
    static func parse(_ data: Data) -> (source: Source, text: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let items = root as? [[String: Any]], !items.isEmpty else { return nil }

        if items.contains(where: { $0["mapping"] is [String: Any] }) {
            let conversations = items.compactMap(chatGPTConversation)
            guard !conversations.isEmpty else { return nil }
            return (.chatGPT, render(conversations, source: .chatGPT))
        }
        if items.contains(where: { $0["chat_messages"] is [[String: Any]] }) {
            let conversations = items.compactMap(claudeConversation)
            guard !conversations.isEmpty else { return nil }
            return (.claude, render(conversations, source: .claude))
        }
        return nil
    }

    // MARK: - ChatGPT

    /// ChatGPT stores a conversation as a TREE of nodes (edits and regenerations
    /// create branches), not a list. Rebuilding the exact active branch needs the
    /// `current_node` pointer walked through parents; collecting every node and
    /// sorting by time is close enough for context and far more robust to format
    /// drift — a regenerated answer appearing twice costs a little duplication,
    /// a broken tree walk costs the whole conversation.
    private static func chatGPTConversation(_ item: [String: Any]) -> Conversation? {
        guard let mapping = item["mapping"] as? [String: Any] else { return nil }

        var dated: [(Double, String, String)] = []
        for value in mapping.values {
            guard let node = value as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let role = author["role"] as? String,
                  role != "system", role != "tool" else { continue }
            guard let content = message["content"] as? [String: Any] else { continue }
            let parts = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            dated.append((message["create_time"] as? Double ?? 0, role, text))
        }
        guard !dated.isEmpty else { return nil }
        dated.sort { $0.0 < $1.0 }

        let created = item["create_time"] as? Double
        return Conversation(
            title: (item["title"] as? String) ?? "Untitled conversation",
            date: created.map { Date(timeIntervalSince1970: $0) },
            messages: dated.map { (role: $0.1, text: $0.2) })
    }

    // MARK: - Claude

    private static func claudeConversation(_ item: [String: Any]) -> Conversation? {
        guard let raw = item["chat_messages"] as? [[String: Any]] else { return nil }

        let messages: [(String, String)] = raw.compactMap { message in
            let role = (message["sender"] as? String) ?? "unknown"
            // Newer exports nest blocks in `content`; older ones use a flat `text`.
            var text = (message["text"] as? String) ?? ""
            if text.isEmpty, let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (role == "human" ? "user" : role, text)
        }
        guard !messages.isEmpty else { return nil }

        return Conversation(
            title: (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled conversation",
            date: (item["created_at"] as? String).flatMap(ISO8601DateFormatter().date(from:)),
            messages: messages)
    }

    // MARK: - Rendering

    private static func render(_ all: [Conversation], source: Source) -> String {
        let sorted = all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let kept = Array(sorted.prefix(maxConversations))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var body = ""
        var rendered = 0
        var truncatedByBudget = false

        for conversation in kept {
            var block = "\n\n## \(conversation.title)"
            if let date = conversation.date { block += " · \(formatter.string(from: date))" }
            block += "\n"
            for message in conversation.messages {
                let speaker = message.role == "user" ? "User" : "Assistant"
                var text = message.text
                if text.count > maxMessageCharacters {
                    text = String(text.prefix(maxMessageCharacters)) + " […]"
                }
                block += "\n\(speaker): \(text)"
            }
            if body.count + block.count > maxCharacters {
                truncatedByBudget = true
                break
            }
            body += block
            rendered += 1
        }

        var header = "\(source.rawValue) export — \(rendered) of \(all.count) conversations"
        if all.count > kept.count {
            header += ", newest \(kept.count) considered"
        }
        if truncatedByBudget {
            header += "; stopped at the \(maxCharacters / 1000)k-character context budget"
        }
        header += ".\nOlder conversations are NOT included — re-export or trim before importing if you need them."

        return header + body
    }

    /// Display name for the produced context file.
    static func fileName(for source: Source) -> String { "\(source.rawValue) export" }
}
