import Foundation

/// Поиск по собственным созвонам — та самая кнопка «Что решили».
///
/// Почему не эмбеддинги, как в английской версии. Там поиск по смыслу сначала
/// **не нашёл встречу по названию**: две формулировки из трёх возвращали
/// пустоту, потому что косинус между предложениями награждает похожесть темы, а
/// вопрос про название спрашивает про имя. Починилось гибридом — косинус плюс
/// доля редких слов вопроса, — и гибрид оказался ещё и быстрее.
///
/// Для русского к этому добавляются два обстоятельства:
///
/// - системная модель предложений на macOS англоязычная, и на русский текст она
///   возвращает вектор, который ничего не значит: молчание было бы честнее;
/// - русский флективен, поэтому «ценах», «ценам», «цены» — одно слово, и без
///   приведения к основе лексическое совпадение просто не сработает.
///
/// Поэтому здесь честный лексический поиск с русской морфологией и без сети.
/// Синонимов он не понимает — и не притворяется, что понимает.
public struct RecallIndex: Sendable {

    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// День созвона, «2026-07-24». Время не хранится: для ответа «когда
        /// решили» хватает дня, а лишняя точность — лишние данные.
        public let date: String
        /// Итог созвона: то, по чему ищем и из чего цитируем.
        public let digest: String

        public init(id: String, title: String, date: String, digest: String) {
            self.id = id
            self.title = title
            self.date = date
            self.digest = digest
        }
    }

    public struct Hit: Equatable, Sendable {
        public let session: Session
        public let score: Double
        /// Предложение, в котором нашлось совпадение. Ответ без цитаты продукт
        /// не показывает, поэтому цитата — часть результата, а не украшение.
        public let excerpt: String
    }

    /// Слова, которые есть в любом вопросе и потому ничего не отбирают.
    static let stopwords: Set<String> = [
        "и", "в", "во", "не", "что", "он", "на", "я", "с", "со", "как", "а",
        "то", "все", "она", "так", "его", "но", "да", "ты", "к", "у", "же",
        "вы", "за", "бы", "по", "только", "ее", "мне", "было", "вот", "от",
        "меня", "еще", "нет", "о", "из", "ему", "теперь", "когда", "даже",
        "ну", "вдруг", "ли", "если", "уже", "или", "ни", "быть", "был", "него",
        "до", "мы", "тебя", "их", "чем", "была", "сам", "чтоб", "без", "будто",
        "чего", "раз", "тоже", "себе", "под", "будет", "тогда", "кто",
        "этот", "того", "потому", "этого", "какой", "совсем", "ним", "здесь",
        "этом", "один", "почти", "мой", "тем", "чтобы", "нее", "были", "куда",
        "зачем", "всех", "никогда", "можно", "при", "наконец", "два", "об",
        "другой", "хоть", "после", "над", "больше", "тот", "через", "эти",
        "нас", "про", "всего", "них", "какая", "много", "разве", "три", "эту",
        "моя", "впрочем", "свою", "этой", "перед", "иногда", "лучше", "чуть",
        "том", "нельзя", "такой", "им", "более", "всегда", "конечно", "всю",
        "между", "наш", "наши", "давайте", "давай",
    ]

    /// Окончания, отсекаемые для сравнения основ, от длинного к короткому —
    /// иначе «ценами» потеряет только «и».
    ///
    /// Это не морфологический анализатор и не претендует им быть: исключений он
    /// не знает, а на коротких словах отключается, чтобы «цена» и «цены»
    /// сошлись, а «дом» не превратился в «до».
    static let endings: [String] = [
        "ами", "ями", "ого", "ему", "ому", "ыми", "ими", "ах", "ях", "ам",
        "ям", "ов", "ев", "ей", "ой", "ый", "ий", "ая", "яя", "ое", "ее",
        "ые", "ие", "ем", "ом", "их", "ых", "ла", "ло", "ли", "ть", "ет",
        "ут", "ют", "ит", "ат", "ят", "а", "я", "о", "е", "ы", "и", "у", "ю",
    ]

    /// Минимальная длина основы: короче — не режем.
    static let minimumStem = 4

    public let sessions: [Session]

    public init(sessions: [Session]) {
        self.sessions = sessions
    }

    // MARK: - Разбор

    static func stem(_ word: String) -> String {
        let word = RussianLexicon.normalized(word)
        // Термин словаря уже канон, окончаний у него нет.
        guard RussianLexicon.canonicalForms()[word] == nil else { return word }
        for ending in endings where word.count > minimumStem && word.hasSuffix(ending) {
            let stripped = String(word.dropLast(ending.count))
            if stripped.count >= minimumStem { return stripped }
        }
        return word
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .filter { !stopwords.contains(RussianLexicon.normalized($0)) && $0.count > 1 }
            .map(stem)
    }

    // MARK: - Поиск

    /// Встречи, отвечающие на вопрос, лучшие первыми.
    ///
    /// Редкое слово весит больше частого: если «цены» встречаются в одном
    /// созвоне из тридцати, именно они отличают нужный, а «задача» — нет.
    /// Название встречи считается дважды: вопрос «что решили на планёрке по
    /// тарифам» спрашивает про имя, и это ровно тот случай, на котором
    /// англоязычная версия провалилась.
    public func search(_ query: String, limit: Int = 5) -> [Hit] {
        let queryTokens = Set(Self.tokens(query))
        guard !queryTokens.isEmpty, !sessions.isEmpty else { return [] }

        // Сколько встреч содержит слово — считаем один раз на запрос.
        var documentFrequency: [String: Int] = [:]
        let sessionTokens = sessions.map { session in
            Set(Self.tokens(session.title) + Self.tokens(session.digest))
        }
        for tokens in sessionTokens {
            for token in tokens where queryTokens.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        var hits: [Hit] = []
        for (index, session) in sessions.enumerated() {
            let titleTokens = Set(Self.tokens(session.title))
            var score = 0.0
            for token in queryTokens where sessionTokens[index].contains(token) {
                let frequency = Double(documentFrequency[token] ?? 1)
                let rarity = log(Double(sessions.count + 1) / frequency)
                score += rarity * (titleTokens.contains(token) ? 2 : 1)
            }
            guard score > 0 else { continue }
            hits.append(Hit(session: session, score: score,
                            excerpt: Self.excerpt(for: queryTokens, in: session.digest)))
        }

        return Array(hits.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.session.id < $1.session.id
        }.prefix(limit))
    }

    /// Предложение с наибольшим числом слов вопроса.
    ///
    /// Не первое предложение и не начало текста: цитата должна показывать, ЗА
    /// ЧТО встреча найдена, иначе читатель не может проверить ответ.
    static func excerpt(for queryTokens: Set<String>, in digest: String) -> String {
        let sentences = digest.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return "" }

        var best = ""
        var bestOverlap = 0
        for sentence in sentences {
            let overlap = Set(tokens(sentence)).intersection(queryTokens).count
            guard overlap > 0 else { continue }
            // При равном совпадении берётся более содержательное предложение.
            // Найдено на живом прогоне: на вопрос «что решили по тарифам»
            // обе фразы — «Обсудили тарифы» и «Решили перейти на оплату за
            // использование, две копейки за кредит» — совпадают одним словом,
            // и по порядку побеждала первая. Пользователь получал цитату,
            // которая подтверждает, что тема была, но не отвечает, что решили.
            let better = overlap > bestOverlap
                || (overlap == bestOverlap && sentence.count > best.count)
            if better {
                bestOverlap = overlap
                best = sentence
            }
        }
        return best
    }
}
