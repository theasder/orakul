import Foundation

/// Убрать из расшифровки отметки времени, оставив слова.
///
/// **Зачем.** orakul не возит своей модели — он запускает вашу, и README
/// предлагает `whisper-cli … -otxt`. whisper.cpp печатает в стандартный вывод
/// отметку В ТОЙ ЖЕ строке, что и текст:
///
///     [00:00:00.000 --> 00:00:04.320]   Аня: По тарифам — что решили?
///
/// Строка уходила в архив целиком, а выдержка резала её по знакам препинания
/// вместе с отметкой — и цитата приходила такой:
///
///     [00: 320]   Аня: По тарифам — что решили в итоге
///
/// Цитата — это и есть продукт. Страдал бы каждый, кто следует README.
///
/// **Почему не в движке.** Готовый файл приносят тем же путём — экспорт SRT из
/// Телемоста или VTT из браузера, — и мусор там тот же. Одно решение на обе
/// двери в архив, как и с ответом на пустой архив.
///
/// **Чего этот код НЕ делает.** Не трогает время внутри фразы: «перенесём на
/// 10:30» — это содержание встречи, и вычистив его, мы испортили бы поиск
/// ровно по тому, что человек ищет. Поэтому отметка узнаётся только в начале
/// строки и только в своих формах, а не «любое двоеточие с цифрами».
public enum TranscriptCleanup {

    /// `[00:00:00.000 --> 00:00:04.320]` и `[00:12:03.500]` в начале строки.
    /// Часы необязательны: некоторые сборки печатают `[00:04.320]`.
    private static let inlineStamp = try? NSRegularExpression(
        pattern: #"^\s*\[(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?"#
                 + #"(?:\s*-->\s*(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?)?\]\s*"#)

    /// Строка целиком из отметки: формат SRT и VTT.
    private static let stampOnlyLine = try? NSRegularExpression(
        pattern: #"^\s*(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->\s*"#
                 + #"(?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3}.*$"#)

    /// Порядковый номер реплики SRT — только когда он один на строке.
    private static let cueNumberLine = try? NSRegularExpression(pattern: #"^\s*\d{1,5}\s*$"#)

    public static func strip(_ raw: String) -> String {
        // Быстрый выход: у расшифровки без отметок текст обязан остаться
        // тем же самым до байта, а не «почти тем же» после прогона по правилам.
        guard raw.contains("-->") || raw.contains("[") || raw.contains("WEBVTT") else {
            return raw
        }

        var lines: [String] = []
        var sawStampLine = false

        for line in raw.components(separatedBy: .newlines) {
            if matches(stampOnlyLine, line) {
                sawStampLine = true
                // Номер реплики SRT стоит ПЕРЕД отметкой, поэтому убирается
                // задним числом: к моменту встречи с отметкой он уже добавлен.
                if let last = lines.last, matches(cueNumberLine, last) { lines.removeLast() }
                continue
            }
            // Заголовок VTT и его параметры — не речь.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") { continue }
            // Одинокое число выбрасывается только там, где отметки уже
            // встречались: иначе «15» отдельной строкой — это ответ на вопрос
            // «на сколько подняли», и терять его нельзя.
            if sawStampLine, matches(cueNumberLine, line) { continue }

            lines.append(removeInlineStamp(line))
        }

        return collapseBlankRuns(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeInlineStamp(_ line: String) -> String {
        guard let expression = inlineStamp else { return line }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let matched = Range(match.range, in: line) else { return line }
        return String(line[matched.upperBound...])
    }

    private static func matches(_ expression: NSRegularExpression?, _ line: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Выброшенные строки оставляют после себя пустоты. Две пустые строки
    /// подряд разбивают абзац там, где его не было, а по абзацам ищется.
    private static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            result.append(line)
        }
        return result
    }
}
