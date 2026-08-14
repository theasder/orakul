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
        // Указательные и наречия места: в вопросе они есть, а искать по ним
        // нечего. Измерено на живых формулировках — «а что там по этому»
        // после отбора оставляло «там» и «этому», и поиск шёл по ним, то есть
        // по шуму: эти слова встречаются в каждом втором звонке.
        "это", "этому", "этим", "этих", "там", "тут", "туда", "оттуда",
        "нам", "вам", "нами", "вами", "себя", "свои", "своё", "свой",
    ]

    /// Окончания, отсекаемые для сравнения основ, от длинного к короткому —
    /// иначе «ценами» потеряет только «и».
    ///
    /// Это не морфологический анализатор и не претендует им быть: исключений он
    /// не знает, а на коротких словах отключается, чтобы «цена» и «цены»
    /// сошлись, а «дом» не превратился в «до».
    static let endings: [String] = [
        // Семейство на «и» — отдельной строкой, потому что без него разъезжался
        // целый разряд слов, самый обычный в разговоре про работу:
        // «развёртывание» обрезалось до «развёртыван» (окончание «ие»), а
        // «развёртыванием» — только до «развёртывани» (окончание «ем»). Одно
        // и то же слово давало две разные основы, и вопрос «что решили по
        // развёртыванию?» получал ответ «не говорили» о том, что говорили.
        // Сюда же попадают «линия/линии/линией» и «партия/партии» — они тоже
        // сходятся в одну основу, только более короткую.
        "иями", "ием", "ией", "иям", "иях", "ия", "ию", "ии",
        "ами", "ями", "ого", "ему", "ому", "ыми", "ими", "ах", "ях", "ам",
        // «ым»/«им» — творительный падеж прилагательных: «годовым тарифом».
        // Без них «годовой» обрезался до «годов», а «годовым» оставался целым,
        // и вопрос про годовой тариф не находил разговор о нём.
        "ым", "им",
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
        if let cached = stemCache.value(for: word) { return cached }
        let result: String
        if let canonical = RussianLexicon.canonicalToken(for: word) {
            result = canonical
        } else {
            result = stripEnding(RussianLexicon.normalized(word))
        }
        stemCache.store(result, for: word)
        return result
    }

    /// Слово → основа считается один раз на слово, а не на каждое вхождение.
    ///
    /// Речь повторяется: на месяце звонков (412 тыс. слов) разных слов
    /// несколько тысяч. Разбор был чистой функцией, которую звали заново на
    /// каждое вхождение, и указатель строился 3.5 секунды — это то, что человек
    /// ждёт на каждый вопрос, потому что на диск указатель не пишется.
    ///
    /// Ограничение по размеру обязательно: без него долгий процесс приложения
    /// накапливал бы каждое услышанное слово навсегда. При переполнении кэш
    /// сбрасывается целиком — это дешевле учёта возрастов и здесь достаточно.
    static let stemCache = StemCache()

    final class StemCache: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: String] = [:]
        private let limit = 50_000

        func value(for word: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return table[word]
        }

        func store(_ stem: String, for word: String) {
            lock.lock(); defer { lock.unlock() }
            if table.count >= limit { table.removeAll(keepingCapacity: true) }
            table[word] = stem
        }

        func countForTesting() -> Int {
            lock.lock(); defer { lock.unlock() }
            return table.count
        }

        /// Замер обязан начинаться с холодного кэша: иначе он показывает не
        /// стоимость разбора, а то, что успели разобрать соседние проверки в
        /// том же процессе.
        func resetForTesting() {
            lock.lock(); defer { lock.unlock() }
            table.removeAll(keepingCapacity: true)
        }
    }

    /// Тот же шаг для приложения.
    ///
    /// В приложении стояло `canonicalToken(for:) ?? слово` с комментарием
    /// «один и тот же шаг, что и в командной строке». Шаг был не тот: обрезки
    /// окончаний там не было вовсе, и «развёртыванием» с «развёртывание»
    /// оставались разными словами. Приложение считает совпадение множествами
    /// слов, для русского запроса это и есть весь поиск — значит разговор
    /// просто не находился.
    public static func searchToken(for word: String) -> String { stem(word) }

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
        // Сверху 4: самое длинное окончание в списке — «иями».
        for length in stride(from: 4, through: 1, by: -1) {
            guard let candidates = endingsByLength[length], word.count > length else { continue }
            let suffix = String(word.suffix(length))
            guard candidates.contains(suffix) else { continue }
            let stripped = String(word.dropLast(length))
            if stripped.count >= minimumStem { return stripped }
        }
        return word
    }

    static func tokens(_ text: String) -> [String] { surfaceTokens(text).map(stem) }

    /// Те же слова, что уходят в указатель, но как они написаны в расшифровке.
    ///
    /// Отдельной функцией, а не копией правил разбора: подсказка про опечатку
    /// обязана предлагать слово, которое поиск действительно найдёт. Разойдись
    /// эти два разбора — и в подсказке окажется слово, по которому не ищется.
    static func surfaceTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
            .flatMap(splitCompound)
            .filter { !stopwords.contains(RussianLexicon.normalized($0)) && $0.count > 1 }
    }

    /// Слово с дефисом — и целиком, и по частям.
    ///
    /// Дефис оставлен разделителем нарочно: «код-свитчинг» и
    /// «Kubernetes-кластер» — одно слово, и терять их нельзя. Но искали при
    /// этом только целиком: вопрос «что там с кластером» не находил разговор
    /// про «Kubernetes-кластер», хотя произнесли именно это. Части идут в
    /// указатель рядом с целым; частое слово вроде «код» веса почти не имеет —
    /// в поиске редкое весит больше частого.
    ///
    /// Дефис по краям — это не слово, а знак препинания: строка «- тарифы»,
    /// вставленная из списка, давала токен «-тарифы», который не совпадал ни с
    /// чем.
    static func splitCompound(_ word: String) -> [String] {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard trimmed.contains("-") else { return trimmed.isEmpty ? [] : [trimmed] }
        let parts = trimmed.split(separator: "-").map(String.init).filter { $0.count > 1 }
        return [trimmed] + parts
    }

    // MARK: - Похожие слова

    /// Наименьшая длина слова, для которого ищется опечатка.
    ///
    /// Для «код» одна буква — треть слова, и «кот» ему «похож» ровно так же,
    /// как «код». Подсказка из трёхбуквенных слов — шум.
    static let minimumTypoLength = 4

    /// Слова из архива, отличающиеся от спрошенного на одну опечатку.
    ///
    /// Зачем. Поиск словарный: «тарифф» с лишней буквой не совпадает ни с чем,
    /// и человек читает «в сохранённых звонках об этом не говорили» — то есть
    /// утверждение о разговоре, который на самом деле был. Одна опечатка —
    /// самый частый способ не найти лежащее на месте.
    ///
    /// Слово не подставляется молча: подменить вопрос — значит ответить не на
    /// него. Возвращается подсказка, решает человек.
    ///
    /// Считается только когда не нашлось ничего, поэтому обход всего словаря
    /// здесь ничего не стоит: на обычном пути этой работы нет.
    public func nearMisses(for query: String, limit: Int = 3) -> [String] {
        let asked = Set(Self.tokens(query)).filter { $0.count >= Self.minimumTypoLength }
        guard !asked.isEmpty, !sessions.isEmpty else { return [] }

        // Сначала — по основам, которые уже разобраны в `init`. Первая
        // редакция вместо этого заново разбирала весь архив на слова: на
        // архиве в 600 тысяч слов промах стоил лишних 1,8 секунды, и «на
        // обычном пути ноль» скрывало, что на промахе не ноль.
        var vocabulary: Set<String> = []
        for tokens in sessionTokens { vocabulary.formUnion(tokens) }

        var wanted: Set<String> = []
        for token in asked where !vocabulary.contains(token) {
            for stem in vocabulary where Self.isOneEditApart(token, stem) {
                wanted.insert(stem)
            }
        }
        guard !wanted.isEmpty else { return [] }

        // И только теперь — по тексту, ради написания найденных основ:
        // у «раскатываем» основа «раскатыва», а это не слово, и предлагать
        // её значит выдать внутренний формат за русский язык. Проход
        // обрывается, как только написание нашлось для каждой основы, —
        // обычно на первом же звонке.
        var spelling: [String: String] = [:]
        for session in sessions {
            for word in Self.surfaceTokens(session.title + " " + session.digest) {
                let stem = Self.stem(word)
                guard wanted.contains(stem), spelling[stem] == nil else { continue }
                spelling[stem] = word
            }
            if spelling.count == wanted.count { break }
        }

        // Берётся написание, встретившееся первым, а не самое частое: считать
        // частоты можно только обойдя архив целиком, то есть отказавшись от
        // обрыва выше. Любая из форм — настоящая, звучавшая на звонке.
        return spelling.values.sorted().prefix(limit).map { $0 }
    }

    /// Отличаются ли слова ровно на одну опечатку.
    ///
    /// Четыре вида: лишняя буква, пропущенная, не та и переставленные соседние.
    /// Перестановка здесь не роскошь: «таирфы» набирается не реже, чем
    /// «тарифф», а через замены до «тарифы» расстояние два — без этой ветки
    /// самая частая опечатка спешащего человека осталась бы не пойманной.
    static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        let left = Array(a), right = Array(b)
        // Быстрый выход, а не проверка: обе ветки ниже отсекают и одинаковые
        // слова (ноль расхождений — не одна опечатка), и разницу длин в две
        // буквы (проход умеет пропустить только одну). Строка стоит здесь
        // потому, что при промахе эта функция зовётся на каждую основу
        // словаря, а не потому, что без неё ответ был бы другим: мутация
        // `<= 2` проверок не роняет — и не должна.
        guard abs(left.count - right.count) <= 1, left != right else { return false }

        if left.count == right.count {
            var mismatches: [Int] = []
            for position in left.indices where left[position] != right[position] {
                mismatches.append(position)
                if mismatches.count > 2 { return false }
            }
            if mismatches.count == 1 { return true }
            guard mismatches.count == 2 else { return false }
            let (first, second) = (mismatches[0], mismatches[1])
            return second == first + 1
                && left[first] == right[second] && left[second] == right[first]
        }

        // Длины разные: короткое должно получаться из длинного вычёркиванием
        // одной буквы. Один проход, без таблицы расстояний.
        let shorter = left.count < right.count ? left : right
        let longer = left.count < right.count ? right : left
        var matched = 0
        var skipped = false
        for position in longer.indices {
            if matched < shorter.count, shorter[matched] == longer[position] {
                matched += 1
                continue
            }
            if skipped { return false }
            skipped = true
        }
        return matched == shorter.count
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

            // Имя говорящего — тоже слово расшифровки, и спрашивают по нему
            // чаще многого: «что говорила Вера». Раньше оно в совпадение не
            // входило — `splitSpeaker` отрезал его до сравнения, — и продукт
            // отвечал «точных слов по вашему вопросу в расшифровке нет» про
            // человека, который на этом звонке говорил. Указатель имя знал и
            // звонок находил: пустой оказывалась именно цитата.
            let speakerTokens = speaker.map { Set(tokens($0)) } ?? []

            for (sentence, endedWithQuestion) in sentences {
                let overlap = Set(tokens(sentence)).union(speakerTokens)
                    .intersection(queryTokens).count
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
