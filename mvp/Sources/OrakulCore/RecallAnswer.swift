import Foundation

/// Ответ на вопрос «что мы решили» — то, что человек в итоге читает.
///
/// Здесь живёт главное обещание продукта, и сформулировано оно как запрет:
/// **нет слов в расшифровке — нет ответа**. Модель, которой показали пустой
/// результат, охотно сочинит правдоподобное решение, поэтому фраза «ничего не
/// нашлось» собирается здесь, кодом, а не запрашивается у модели.
///
/// Ответ состоит из трёх частей, и каждая нужна для проверки: название встречи
/// (где сказано), дата (когда) и точная цитата (что именно). Без цитаты ответ
/// невозможно проверить, а непроверяемый ответ про чужие обещания — ровно то,
/// на что жалуются пользователи других инструментов.
public enum RecallAnswer {

    /// Сколько встреч показывать. Больше трёх — это уже не ответ, а выдача.
    public static let maximumMeetings = 3

    /// Текст, который видит пользователь.
    public static func compose(query: String, hits: [RecallIndex.Hit]) -> String {
        let grounded = hits.filter { !$0.excerpt.isEmpty }
        guard !grounded.isEmpty else { return notFound(hits: hits) }

        var lines: [String] = []
        for hit in grounded.prefix(maximumMeetings) {
            lines.append("«\(hit.session.title)», \(humanDate(hit.session.date))")
            lines.append("    \(hit.excerpt)")
        }

        if grounded.count > maximumMeetings {
            let rest = grounded.count - maximumMeetings
            lines.append("Ещё \(rest) \(meetingsWord(rest)) с упоминанием — в архиве.")
        }
        return lines.joined(separator: "\n")
    }

    /// Почему ответа нет — разными словами для разных причин.
    ///
    /// «Не нашёл» и «нашёл встречу, но там про это не сказано» — разные
    /// сообщения, и человек принимает по ним разные решения: искать иначе или
    /// перестать искать.
    static func notFound(hits: [RecallIndex.Hit]) -> String {
        if hits.isEmpty {
            return "В сохранённых созвонах об этом не говорили. Ответ придумывать не буду."
        }
        let titles = hits.prefix(maximumMeetings)
            .map { "«\($0.session.title)»" }
            .joined(separator: ", ")
        return "Похожие созвоны есть — \(titles), — но точных слов по вашему вопросу "
            + "в расшифровке нет, поэтому цитировать нечего."
    }

    /// «2026-07-24» → «24 июля 2026». Дату в ответе читает человек, а не
    /// сортирует машина.
    static func humanDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]) else { return iso }
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                      "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        return "\(day) \(months[month - 1]) \(parts[0])"
    }

    /// Русский счёт: 1 встреча, 2 встречи, 5 встреч.
    static func meetingsWord(_ count: Int) -> String {
        let hundred = count % 100
        if (11...14).contains(hundred) { return "встреч" }
        switch count % 10 {
        case 1: return "встреча"
        case 2, 3, 4: return "встречи"
        default: return "встреч"
        }
    }
}
