import Foundation

/// Bridges DecisionRecallService into the ordinary ask flow (roadmap F1).
///
/// No new UI: when a composer prompt reads like a cross-meeting recall
/// question — "what did we decide about pricing", "что мы решили про цены" —
/// the top verbatim excerpts from saved sessions are prepended to the request
/// context, and the model is instructed to answer FROM the record and cite
/// the meeting, or say the record is silent. The gate is a regex, not a model
/// call: recall detection must be free and instant on every keystroke path.
enum DecisionRecallContext {

    /// Recall-intent shapes, English and Russian. Deliberately permissive —
    /// a false positive only adds a small grounded block to the context; a
    /// false negative sends the user back to scrolling old sessions, which is
    /// the pain this feature exists to end.
    private static let intentPattern = try! NSRegularExpression(pattern: #"""
        (?xi)
        \b(what|when|why|who)\b.{0,40}\b(decid\w*|agree\w*|land\w*\s+on|commit\w*)
        | \bdid\s+we\s+(decide|agree|commit|land)
        | \b(last|previous|prior|earlier)\s+(meeting|call|sync|standup|week)\b
        | \bwhat\s+was\s+decided\b
        | \bчто\s+(мы\s+)?(решили|договорились|обсуждали)
        | \bна\s+(прошл\w+|предыдущ\w+)\s+(встреч\w+|созвон\w+)
        | \bкогда\s+(мы\s+)?(решили|договорились)
        """#, options: [.allowCommentsAndWhitespace])

    static func matchesRecallIntent(_ prompt: String) -> Bool {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return intentPattern.firstMatch(in: prompt, range: range) != nil
    }

    /// The grounded context block, or nil when the prompt is not a recall
    /// question or the record has nothing relevant. Excerpts stay verbatim —
    /// the whole point is that the answer can be quoted back to a session.
    static func block(for prompt: String,
                      store: SessionStore = .shared,
                      embedder: any SkillTextEmbedder = RecallEmbedder.production,
                      limit: Int = 4) -> String? {
        guard matchesRecallIntent(prompt) else { return nil }
        let hits = DecisionRecallService.recall(query: prompt, store: store,
                                                embedder: embedder, limit: limit)

        // Файлы архива, которые не открылись. Модели об этом надо сказать
        // ДАЖЕ когда находок нет: иначе она уверенно ответит «в сохранённых
        // звонках об этом не говорили» поверх записи, часть которой ей не
        // показали.
        let unreadable = store.listWithUnreadable().unreadable
        guard !hits.isEmpty || !unreadable.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var lines = ["PRIOR-MEETING RECORD — verbatim excerpts from this user's saved sessions.",
                     "Answer the question FROM this record when it applies: cite the meeting",
                     "title and date, quote the record rather than paraphrasing it, and if the",
                     "record does not answer the question, say so plainly instead of guessing."]
        for hit in hits {
            lines.append("— [\(hit.sessionTitle) · \(formatter.string(from: hit.startedAt))] “\(hit.excerpt)”")
        }
        if !unreadable.isEmpty {
            // Прямая инструкция, а не намёк: без неё модель видит неполный
            // список и всё равно отвечает «не обсуждали» с полной уверенностью.
            lines.append("INCOMPLETE RECORD: \(unreadable.count) saved session file(s) "
                + "could not be read (\(unreadable.joined(separator: ", "))). "
                + "If the record does not answer the question, say the archive is "
                + "partially unreadable rather than stating it was not discussed.")
        }
        return lines.joined(separator: "\n")
    }
}
