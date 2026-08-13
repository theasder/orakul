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

    /// Слова каждой встречи, разобранные ОДИН раз при создании индекса.
    ///
    /// Раньше это считалось внутри `search`, то есть заново на каждый вопрос —
    /// а название вдобавок разбиралось дважды: один раз в общем наборе, второй
    /// отдельно для веса заголовка. На месяце часовых звонков (450 тыс. слов)
    /// один поиск стоил секунды, и каждый следующий столько же.
    private let sessionTokens: [Set<String>]
    private let titleTokens: [Set<String>]

    public init(sessions: [Session]) {
        self.sessions = sessions
        let titles = sessions.map { Set(Self.tokens($0.title)) }
        self.titleTokens = titles
        self.sessionTokens = sessions.enumerated().map { index, session in
            Set(Self.tokens(session.digest)).union(titles[index])
        }
    }

    // MARK: - Разбор

    /// Слово → общий токен для запроса и расшифровки.
    ///
    /// Три ступени, и порядок важен:
    ///
    /// 1. **Термин словаря** отдаётся каноном и НЕ обрезается. Обрезать нельзя:
    ///    у «коммит» на конце «ит» — обычное глагольное окончание, и обрезка
    ///    превращает термин в «комм». Это выяснилось мутацией: попытка
    ///    «причесать обе стороны одной обрезкой» починила «деплою» и сломала
    ///    «коммита», который работал.
    /// 2. **Падеж термина** ищется в таблице форм. «коммита», «деплою»,
    ///    «фичи» — не термины, но приводятся к своему термину.
    /// 3. Всё остальное — обычная обрезка окончаний.
    static func stem(_ word: String) -> String {
        if let canonical = RussianLexicon.canonicalToken(for: word) { return canonical }
        return stripEnding(RussianLexicon.normalized(word))
    }

    /// Окончания, разобранные по длине. Строится один раз.
    ///
    /// Список идёт строго от длинных к коротким, и цикл возвращал ПЕРВОЕ
    /// совпадение — то есть самое длинное. Три множества дают тот же ответ, но
    /// тремя хешами вместо сорока четырёх сравнений суффикса.
    ///
    /// Разница не косметическая: поиск по 30 часовым звонкам (~450 тыс. слов)
    /// занимал 4.1 с, и почти всё это — двадцать миллионов сравнений строк.
    private static let endingsByLength: [Int: Set<String>] = {
        var table: [Int: Set<String>] = [:]
        for ending in endings { table[ending.count, default: []].insert(ending) }
        return table
    }()

    private static func stripEnding(_ word: String) -> String {
        guard word.count > minimumStem else { return word }
        // От длинного к короткому — тот же порядок, что был у списка.
        for length in stride(from: 3, through: 1, by: -1) {
            guard let candidates = endingsByLength[length], word.count > length else { continue }
            let suffix = String(word.suffix(length))
            guard candidates.contains(suffix) else { continue }
            let stripped = String(word.dropLast(length))
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
        // Сами слова встреч уже разобраны в `init`.
        var documentFrequency: [String: Int] = [:]
        for tokens in sessionTokens {
            for token in tokens where queryTokens.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        var hits: [Hit] = []
        for (index, session) in sessions.enumerated() {
            var score = 0.0
            for token in queryTokens where sessionTokens[index].contains(token) {
                let frequency = Double(documentFrequency[token] ?? 1)
                let rarity = log(Double(sessions.count + 1) / frequency)
                score += rarity * (titleTokens[index].contains(token) ? 2 : 1)
            }
            guard score > 0 else { continue }
            // Цитата — самая дорогая часть: она заново разбирает расшифровку по
            // строкам и предложениям. Считать её для КАЖДОГО совпадения, а
            // потом выбросить всё, кроме пяти, — основная работа впустую.
            // Замерено: повторный поиск стоил столько же, сколько первый,
            // несмотря на разобранный заранее индекс.
            hits.append(Hit(session: session, score: score, excerpt: ""))
        }

        let best = hits.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.session.id < $1.session.id
        }.prefix(limit)
        // Цитаты — только для тех, кто действительно попал в выдачу.
        return best.map { hit in
            Hit(session: hit.session, score: hit.score,
                excerpt: Self.excerpt(for: queryTokens, in: hit.session.digest))
        }
    }

    /// Предложение с наибольшим числом слов вопроса.
    ///
    /// Не первое предложение и не начало текста: цитата должна показывать, ЗА
    /// ЧТО встреча найдена, иначе читатель не может проверить ответ.
    /// Реплика, отвечающая на вопрос, — вместе с тем, кто её сказал.
    ///
    /// Разбор идёт по строкам, а не по всей расшифровке сразу. Раньше цитата
    /// резалась по «.!?\n» на всём тексте, и говорящий оставался только у
    /// ПЕРВОГО предложения строки: на запрос «пятницу» выдача была
    /// «Выкатываем в пятницу, откат готовим заранее» — без имени. Для
    /// продукта, который обещает ответ цитатой из звонка, цитата без
    /// говорящего наполовину бесполезна: непонятно, кого переспрашивать.
    static func excerpt(for queryTokens: Set<String>, in digest: String) -> String {
        var best = ""
        var bestOverlap = 0
        var bestLength = 0
        var bestLineIndex = -1
        var bestWasQuestion = false

        let lines = digest.split(separator: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let (speaker, body) = splitSpeaker(String(line))
            // Знак конца нужен дальше: по нему видно, что реплика была
            // вопросом. `split` его выбрасывает, поэтому запоминаем отдельно.
            let sentences = splitSentences(body)

            for (sentence, endedWithQuestion) in sentences {
                let overlap = Set(tokens(sentence)).intersection(queryTokens).count
                guard overlap > 0 else { continue }
                // При равном совпадении берётся более содержательное
                // предложение. Найдено на живом прогоне: на вопрос «что решили
                // по тарифам» обе фразы — «Обсудили тарифы» и «Решили перейти
                // на оплату за использование» — совпадают одним словом, и по
                // порядку побеждала первая. Пользователь получал цитату,
                // которая подтверждает, что тема была, но не отвечает, что
                // решили.
                //
                // Сравнивается длина САМОГО предложения, не считая имени:
                // иначе выбор зависел бы от того, насколько длинное имя у
                // говорящего.
                let better = overlap > bestOverlap
                    || (overlap == bestOverlap && sentence.count > bestLength)
                guard better else { continue }
                bestOverlap = overlap
                bestLength = sentence.count
                best = speaker.map { "\($0): \(sentence)" } ?? sentence
                bestLineIndex = lineIndex
                bestWasQuestion = endedWithQuestion
            }
        }

        // Если нашёлся ВОПРОС — показываем и следующую реплику.
        //
        // Найдено прогоном быстрого старта из README дословно: на «что решили
        // по тарифам» продукт цитировал строку Ани «По тарифам — что решили в
        // итоге», то есть сам вопрос. Решение стояло следующей строкой и со
        // словами запроса не пересекалось вовсе — отвечающий не повторяет
        // тему, — поэтому словарным поиском оно недостижимо в принципе.
        //
        // Это не додумывание: следующая реплика берётся дословно и с именем
        // говорящего, человек видит, кто что сказал, и может проверить.
        // Приписывается только к вопросу: приклеивать соседа к каждой находке
        // значит топить ответ в чужих репликах.
        //
        // Граница правила, проверенная на живой планёрке: между вопросом и
        // ответом встревает «Борис: Секунду, найду документ» — и показана
        // будет она. Чинить это «пропускать короткие реплики» нельзя: «Я, к
        // пятнице» тоже коротка и при этом ответ. Любая догадка о том, какая
        // из соседних строк «настоящая», — это решение за пользователя, что
        // было сказано. Показываем соседнюю строку как есть; страница про эту
        // границу говорит прямо.
        guard bestWasQuestion, bestLineIndex >= 0, bestLineIndex + 1 < lines.count else {
            return best
        }
        let next = String(lines[bestLineIndex + 1]).trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty else { return best }
        return best + "\n" + next
    }

    /// Предложения строки и признак «кончилось вопросительным знаком».
    static func splitSentences(_ body: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        for character in body {
            if ".!?".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append((trimmed, character == "?")) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append((tail, false)) }
        return result
    }

    /// «Борис: Обсудили деплой» → («Борис», «Обсудили деплой»).
    ///
    /// Двоеточие внутри фразы говорящим не считается: подпись — это короткое
    /// начало строки без знаков конца предложения. Иначе «Про тарифы вскользь:
    /// клиенты жалуются» превратилось бы в реплику «Про тарифы вскользь».
    static func splitSpeaker(_ line: String) -> (String?, String) {
        guard let colon = line.firstIndex(of: ":") else { return (nil, line) }
        let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !rest.isEmpty,
              !name.contains(where: { ".!?,;".contains($0) }) else {
            return (nil, line)
        }
        return (name, rest)
    }
}
