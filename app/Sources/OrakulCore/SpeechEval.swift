import Foundation

/// Оценка распознавания русской речи разработчиков.
///
/// Опубликованные цифры WER для русского меряют не ту речь: лучший результат
/// GigaAM (3.3%) получен на нарезке из аудиокниг — один диктор, без
/// перебиваний, без жаргона. Совещание противоположно этому по всем четырём
/// признакам.
///
/// Здесь два разных инструмента, и разница между ними принципиальна:
///
/// - `wordErrorRate` — классика, но требует эталона, размеченного человеком.
///   Его у нас пока нет, и придумывать его нельзя.
/// - `termDisagreements` — работает уже сегодня. Если несколько движков
///   расшифровали один и тот же звук и разошлись на термине, кто-то из них
///   ошибся. Эталон для этого не нужен, а термины — ровно то место, где
///   ломается смешанная речь: «поднимем LLM-фильтр в prod» — это русская
///   фраза с английскими словами, которых модель могла не слышать.
public enum SpeechEval {

    // MARK: - Нормализация

    /// Приводит текст к виду, в котором сравнение осмысленно.
    ///
    /// «ё» и «е» — один звук и две традиции письма; движки пишут их
    /// по-разному, и без склейки половина расхождений оказалась бы
    /// орфографическими, а не слуховыми.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    // MARK: - WER

    public struct ErrorRate: Equatable, Sendable {
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public let referenceWords: Int

        public var errors: Int { substitutions + deletions + insertions }
        /// 0 — идеально. Может превышать 1: вставок бывает больше, чем слов.
        public var rate: Double {
            referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords)
        }
    }

    /// Классический WER по словам. Нужен эталон — без него не вызывать.
    public static func wordErrorRate(reference: String, hypothesis: String) -> ErrorRate {
        let reference = words(reference)
        let hypothesis = words(hypothesis)
        guard !reference.isEmpty || !hypothesis.isEmpty else {
            return ErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)
        }

        // Левенштейн по словам с РАЗДЕЛЬНЫМ подсчётом операций: суммарное
        // расстояние не отвечает на вопрос, речь сломалась или пропала, а это
        // разные болезни — глоссарий в промпте лечил первую и вызывал вторую.
        struct Cell { var s = 0, d = 0, i = 0; var total: Int { s + d + i } }
        var previous = (0...hypothesis.count).map { Cell(s: 0, d: 0, i: $0) }

        for (row, referenceWord) in reference.enumerated() {
            var current = [Cell(s: 0, d: row + 1, i: 0)]
            current.reserveCapacity(hypothesis.count + 1)
            for (column, hypothesisWord) in hypothesis.enumerated() {
                if referenceWord == hypothesisWord {
                    current.append(previous[column])
                    continue
                }
                let substitution = previous[column]
                let deletion = previous[column + 1]
                let insertion = current[column]
                let best = [substitution, deletion, insertion].min { $0.total < $1.total }!
                var cell = best
                if best.total == substitution.total { cell.s += 1 }
                else if best.total == deletion.total { cell.d += 1 }
                else { cell.i += 1 }
                current.append(cell)
            }
            previous = current
        }

        let last = previous[hypothesis.count]
        return ErrorRate(substitutions: last.s, deletions: last.d, insertions: last.i,
                         referenceWords: reference.count)
    }

    // MARK: - Термины без эталона

    public struct TermReport: Equatable, Sendable {
        public let term: String
        /// Сколько расшифровок содержат термин.
        public let found: Int
        public let total: Int

        /// Все согласны — либо все нашли, либо все не нашли.
        public var isUnanimous: Bool { found == 0 || found == total }
        /// Термин есть у одних и нет у других: кто-то точно ошибся.
        public var isDisputed: Bool { !isUnanimous }
    }

    /// Как расшифровки одного и того же звука расходятся на терминах.
    ///
    /// Эталон не нужен: разногласие само по себе — доказательство ошибки.
    /// Единогласие ошибку не исключает (все могли расслышать одинаково
    /// неверно), поэтому метод отвечает на вопрос «где точно плохо», а не
    /// «где хорошо». Это меньше, чем WER, и это честно.
    public static func termDisagreements(terms: [String],
                                         across transcripts: [String]) -> [TermReport] {
        guard !transcripts.isEmpty else { return [] }
        let normalized = transcripts.map { " " + normalize($0) + " " }

        return terms.map { term in
            let needle = " " + normalize(term) + " "
            let found = normalized.filter { $0.contains(needle) }.count
            return TermReport(term: term, found: found, total: transcripts.count)
        }
    }

    /// Доля терминов, на которых расшифровки согласны. 1 — полное согласие.
    public static func termAgreementRate(terms: [String], across transcripts: [String]) -> Double {
        let reports = termDisagreements(terms: terms, across: transcripts)
        guard !reports.isEmpty else { return 1 }
        return Double(reports.filter(\.isUnanimous).count) / Double(reports.count)
    }
}
