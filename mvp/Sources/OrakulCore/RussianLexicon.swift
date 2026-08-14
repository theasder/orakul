import Foundation

/// Словарь русскоязычного разработчика и починка расшифровки по нему.
///
/// Зачем он существует — измерено, а не предположено. На трёх фрагментах живой
/// русской речи три движка разошлись в среднем на 29% терминов, и **все**
/// спорные оказались код-свитчингом: «прод», «промпт», «API», «джейлбрейк».
/// Ни одного обычного русского слова среди них не было.
///
/// Отсюда два решения:
///
/// 1. **Чинить после расшифровки, а не в декодере.** Термин, которого модель не
///    слышала, подсказка в промпте не спасёт, зато она умеет удалять речь: на
///    английском корпусе такой глоссарий довёл большую модель до WER 0.95 с
///    2757 пропусками. Правка текста максимум портит один токен и не может
///    заставить речь исчезнуть.
/// 2. **Только регистр и написание, без нечёткого исправления.** Общий словарь
///    не покрывает лексику конкретного созвона, поэтому «похожее» слово он
///    превратит в соседнее по написанию, а не в правильное.
///
/// **Аудит коллизий — это и есть кураторство.** Слово попадает в словарь только
/// если его нормализованная форма не совпадает с обычным русским словом.
/// «Агент» не входит: это слово языка («страховой агент»), и починка сломала бы
/// обычную речь. «Прод» входит, но только как отдельное слово — внутри
/// «продукт» его быть не должно.
public enum RussianLexicon {

    /// Аббревиатуры, которые в русской речи произносятся по-английски и пишутся
    /// латиницей заглавными. Регистр — единственное, что здесь чинится.
    public static let acronyms: [String] = [
        "API", "SDK", "CLI", "UI", "UX", "LLM", "ML", "AI", "RAG", "MCP",
        "CI", "CD", "SQL", "JSON", "YAML", "HTTP", "HTTPS", "REST", "gRPC",
        "JWT", "OAuth", "SSO", "TLS", "DNS", "CDN", "VPN", "SLA", "SLO",
        "CPU", "GPU", "RAM", "ORM", "DTO", "MVP", "PR", "QA", "RPS", "TTL",
    ]

    /// Заимствования, которые в русской речи звучат по-русски и пишутся
    /// кириллицей. Канон — кириллица: расшифровка русского созвона, где
    /// половина слов латиницей, читается как чужая.
    ///
    /// Каждое слово прошло проверку на совпадение с обычной русской лексикой.
    /// Намеренно отсутствуют «агент», «канал», «очередь», «ветка», «образ» и
    /// «модель»: у всех есть обиходное значение, и починка испортила бы
    /// нормальную фразу.
    public static let loanwords: [String] = [
        "промпт", "прод", "деплой", "релиз", "бэкенд", "фронтенд", "фича",
        "баг", "коммит", "мёрж", "пул-реквест", "ревью", "рефакторинг",
        "пайплайн", "джейлбрейк", "фолбэк", "хардкод", "легаси", "хотфикс",
        "хендлер", "миграция", "кеш", "докер", "кубернетес",
        // Добавлено 2026-08-14: слова, которые на созвоне произносят, а в
        // поиск набирают по-английски. Проверено запуском: «стейджинг» и
        // «ролбэк» не находили ни staging, ни rollback.
        "стейджинг", "ролбэк",
    ]

    public static var allTerms: [String] { acronyms + loanwords }

    // MARK: - Починка

    /// Нормализованная форма для сравнения: регистр и «ё» не различают слова.
    public static func normalized(_ term: String) -> String {
        term.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Написания того же слова в другом алфавите.
    ///
    /// Измерено, а не придумано. На одном и том же звуке Whisper пишет
    /// `Prompt`, Parakeet — `Промпт`; на «API» Parakeet пишет только «апи»,
    /// Whisper — «API». То есть движки расходятся не в слухе, а в АЛФАВИТЕ, и
    /// словарь, приводящий написание внутри одного алфавита, такую разницу
    /// исправить не может в принципе — первый прогон это и показал: согласие
    /// 71% до словаря и 71% после.
    ///
    /// Направление канона разное и не случайное: аббревиатуру в русском тексте
    /// пишут латиницей заглавными (API, LLM), а заимствование, ставшее русским
    /// словом, — кириллицей (промпт, прод). Поэтому таблица приводит «апи» к
    /// `API`, но `prompt` — к «промпт».
    ///
    /// Осознанный компромисс: английская фраза внутри русской расшифровки
    /// («we need a prompt for that») тоже будет переписана. Для расшифровки
    /// русского созвона это верно чаще, чем неверно, но это не бесплатно — и
    /// именно поэтому в таблице только слова, у которых кириллическая форма
    /// является нормой русской технической речи.
    static let variants: [String: String] = [
        // Кириллица → латинская аббревиатура
        "апи": "API", "эйпиай": "API", "элэлэм": "LLM", "джейсон": "JSON",
        "сиай": "CI", "куа": "QA", "джиэйтиви": "JWT", "рэг": "RAG",
        // Латиница → кириллическое заимствование
        "prompt": "промпт", "prod": "прод", "deploy": "деплой",
        "release": "релиз", "backend": "бэкенд", "frontend": "фронтенд",
        "feature": "фича", "bug": "баг", "commit": "коммит", "merge": "мёрж",
        "review": "ревью", "refactoring": "рефакторинг", "pipeline": "пайплайн",
        "jailbreak": "джейлбрейк", "fallback": "фолбэк", "hardcode": "хардкод",
        "legacy": "легаси", "hotfix": "хотфикс", "cache": "кеш",
        "docker": "докер", "kubernetes": "кубернетес", "handler": "хендлер",
        "staging": "стейджинг", "stage": "стейджинг", "rollback": "ролбэк",
    ]

    /// Канонические написания, разобранные по нормализованной форме.
    /// Таблица строится ОДИН раз.
    ///
    /// Была функцией, и её звали из `stem` на каждое слово: 20 звонков —
    /// 3000 слов — 3000 перестроений словаря. Один поиск занимал 118 секунд, а
    /// на 200 звонках не заканчивался вовсе. Тесты этого не видели: в них по
    /// две-три фразы, где разница незаметна.
    static let canonicalIndex: [String: String] = buildCanonicalForms()

    public static func canonicalForms() -> [String: String] { canonicalIndex }

    private static func buildCanonicalForms() -> [String: String] {
        var forms: [String: String] = [:]
        for term in allTerms {
            forms[normalized(term)] = term
        }
        // Варианты добавляются поверх: они указывают на тот же канон.
        for (variant, canonical) in variants {
            forms[normalized(variant)] = canonical
        }
        return forms
    }

    /// Канонический токен слова: сам термин, его падеж — или nil.
    ///
    /// Один поиск в двух местах. Приложение и командная строка разбирают слова
    /// по-разному (разные стоп-слова, разная обрезка), но ЭТОТ шаг у них был
    /// одинаковый и написан дважды: сначала таблица канонов, потом таблица
    /// падежей, иначе слово как есть. Кросс-алфавитный поиск и падежи чинились
    /// в обеих копиях руками — ровно та работа, которой быть не должно.
    ///
    /// nil означает «слова нет в словаре», и вызывающий решает сам: командная
    /// строка обрежет окончание, приложение оставит как есть.
    public static func canonicalToken(for word: String) -> String? {
        let key = normalized(word)
        if let canonical = canonicalIndex[key] { return normalized(canonical) }
        if let canonical = inflectionIndex[key] { return normalized(canonical) }
        // Имена инфраструктуры — последними: они действуют ТОЛЬКО на поиск и не
        // должны перебивать канон, по которому переписывается расшифровка.
        if let canonical = infrastructureIndex[key] { return canonical }
        return nil
    }

    // MARK: - Имена инфраструктуры (только поиск)

    /// Одно и то же место, названное по-русски и официально.
    ///
    /// **Зачем.** На планёрке говорят «подняли редис», «постгрес обновили», «в
    /// гите ветку смержили». Ищут — официальным именем: так оно написано в
    /// конфиге и в документации. До этой таблицы не находилось ни одно из
    /// девяти проверенных имён; работали только `Kubernetes` и `Docker`,
    /// единственные из этого ряда, попавшие в таблицу вариантов.
    ///
    /// **Почему отдельно от `variants`.** По `variants` строится канон, которым
    /// `restore` ПЕРЕПИСЫВАЕТ расшифровку. Половина этих имён совпадает с
    /// обычными русскими словами: «редис» — овощ, «кафка» — писатель,
    /// «прометей» — титан. Переписать их в тексте созвона значит испортить
    /// нормальную фразу; этот файл такие слова и исключает намеренно — см.
    /// «агент», «канал», «очередь» в комментарии к `loanwords`. А счесть их
    /// одним словом ПРИ ПОИСКЕ безопасно: цена ошибки — лишняя находка про
    /// овощ, а не испорченный архив.
    ///
    /// Ключ — что человек мог сказать или набрать; значение — общий токен.
    /// Сам токен латиницей и вниз регистром: он не показывается человеку,
    /// только сравнивается.
    static let infrastructure: [String: String] = [
        "редис": "redis", "redis": "redis",
        "кафка": "kafka", "kafka": "kafka",
        "постгрес": "postgres", "постгре": "postgres",
        "postgres": "postgres", "postgresql": "postgres", "psql": "postgres",
        "нжинкс": "nginx", "энжиникс": "nginx", "nginx": "nginx",
        "гит": "git", "git": "git",
        "эластик": "elastic", "эластиксёрч": "elastic",
        "elastic": "elastic", "elasticsearch": "elastic",
        "кликхаус": "clickhouse", "clickhouse": "clickhouse",
        "графана": "grafana", "grafana": "grafana",
        "прометей": "prometheus", "прометеус": "prometheus",
        "prometheus": "prometheus",
        "монга": "mongo", "монго": "mongo", "mongo": "mongo", "mongodb": "mongo",
        "рэббит": "rabbitmq", "раббит": "rabbitmq",
        "rabbit": "rabbitmq", "rabbitmq": "rabbitmq",
        "терраформ": "terraform", "terraform": "terraform",
        "ансибл": "ansible", "ansible": "ansible",
        "сентри": "sentry", "sentry": "sentry",
        "кибана": "kibana", "kibana": "kibana",
        "тарантул": "tarantool", "tarantool": "tarantool",
        "кубер": "кубернетес", "k8s": "кубернетес",
        // Эти три — обычные русские слова, и переписывать ими расшифровку
        // нельзя: «кролик» бывает зверем, «откат» — деньгами, «артефакт» —
        // находкой. Таблица действует только на поиск, поэтому им здесь место,
        // а в словаре терминов — нет.
        "кролик": "rabbitmq", "откат": "ролбэк", "артефакт": "artifact",
        "artifact": "artifact", "артифакт": "artifact",
        // Добавлено 2026-08-13 по частоте в речи, а не по популярности
        // технологии: слова, которые произносят вслух на созвонах, а пишут
        // потом по-английски. Таблица только для поиска, поэтому совпадение с
        // обычным русским словом здесь не беда — «постман» останется почтальоном
        // в расшифровке и найдётся по запросу postman.
        "дженкинс": "jenkins", "jenkins": "jenkins",
        "питон": "python", "пайтон": "python", "python": "python",
        "джава": "java", "жава": "java", "java": "java",
        "кассандра": "cassandra", "касандра": "cassandra", "cassandra": "cassandra",
        "эйрфлоу": "airflow", "эйрфлов": "airflow", "airflow": "airflow",
        "постман": "postman", "postman": "postman",
        "сваггер": "swagger", "свагер": "swagger", "swagger": "swagger",
        "вебхук": "webhook", "вебхуки": "webhook", "webhook": "webhook",
        "зукипер": "zookeeper", "zookeeper": "zookeeper",
    ]

    /// Разобрано по нормализованной форме один раз, как и остальные таблицы:
    /// разбор зовётся на каждое слово каждого звонка.
    private static let infrastructureIndex: [String: String] = {
        var table: [String: String] = [:]
        for (spoken, canonical) in infrastructure {
            table[normalized(spoken)] = normalized(canonical)
        }
        // Падежи русских написаний: «постгресу», «кафку», «графану» человек
        // произносит не задумываясь, а ищет именительным падежом или латиницей.
        // Ставятся ПОСЛЕ основных ключей и не затирают их: у «гит» падеж
        // «гита» не должен перебить само слово.
        for (spoken, canonical) in infrastructure where isCyrillic(spoken) {
            for form in russianCases(of: spoken) where table[normalized(form)] == nil {
                table[normalized(form)] = normalized(canonical)
            }
        }
        return table
    }()

    private static func isCyrillic(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return first.value >= 0x0400 && first.value <= 0x04FF
    }

    /// Падежные формы русского слова по трём общим правилам — тем же, что
    /// `inflections()` применяет к заимствованиям.
    private static func russianCases(of word: String) -> [String] {
        guard let last = word.last else { return [] }
        let stem = String(word.dropLast())
        switch last {
        case "а":  return [stem + "у", stem + "е", stem + "и", stem + "ой", stem + "ы"]
        case "й":  return [stem + "я", stem + "ю", stem + "е", stem + "ем", stem + "и"]
        default:   return [word + "а", word + "у", word + "е", word + "ом", word + "ы", word + "и"]
        }
    }

    /// Падежи и числа терминов → сам термин.
    ///
    /// Зачем отдельной таблицей, а не обрезкой окончаний. Обрезка не знает
    /// слова: у «коммит» на конце «ит», у «деплой» — «ой», и то и другое
    /// выглядит как русское окончание. Обрезать термины нельзя. А их падежи
    /// обрезка режет — и обе стороны перестают сходиться: в архиве «деплой», в
    /// запросе «деплою» → «депло», и человек не находит свой же звонок, хотя
    /// страница обещает, что падежи понимаются.
    ///
    /// Словарь закрытый и маленький, поэтому формы порождаются механически и
    /// проверяются целиком — на каждый термин есть тест.
    ///
    /// Правила ровно три, по типу окончания термина:
    ///   * на «й» (деплой) — «й» заменяется: деплоя, деплою, деплое, деплоем…
    ///   * на «а»/«я» (фича, миграция) — заменяется тем же набором;
    ///   * согласный (коммит, баг) — окончание добавляется.
    ///
    /// Латинские написания получают ещё и английское множественное: `prompts`
    /// — то, что человек наберёт, если привык писать термин латиницей.
    /// Тоже один раз: внутри цикл по терминам × окончаниям, и каждая
    /// итерация ещё спрашивала `canonicalForms()`. На каждое слово запроса.
    static let inflectionIndex: [String: String] = buildInflections()

    public static func inflections() -> [String: String] { inflectionIndex }

    private static func buildInflections() -> [String: String] {
        var forms: [String: String] = [:]
        let replaced = ["а", "я", "у", "ю", "е", "и", "ы", "ом", "ем", "ов", "ев",
                        "ам", "ах", "ями", "ами", "ой", "ей"]
        let appended = ["а", "у", "е", "и", "ы", "ом", "ов", "ам", "ах", "ами"]

        for term in allTerms {
            let key = normalized(term)
            guard let last = key.last else { continue }
            let endings: [String]
            let base: String
            if last == "й" || last == "а" || last == "я" {
                base = String(key.dropLast())
                endings = replaced
            } else {
                base = key
                endings = appended
            }
            for ending in endings {
                let form = base + ending
                // Сам термин не перезаписываем и чужие термины не крадём:
                // порождённая форма, совпавшая с настоящим термином, — не форма.
                guard form != key, canonicalIndex[form] == nil else { continue }
                forms[form] = term
            }
        }

        // Английское множественное для латинских написаний.
        for (variant, canonical) in variants where variant.allSatisfy({ $0.isASCII }) {
            let plural = normalized(variant) + "s"
            if canonicalIndex[plural] == nil { forms[plural] = canonical }
        }
        return forms
    }

    /// Приводит термины в расшифровке к каноническому написанию.
    ///
    /// Только целые слова: замена по подстроке испортила бы «продукт» и
    /// «апишку». Ничего не удаляет и не добавляет — количество слов остаётся
    /// прежним, и это проверяется тестом, потому что молчание движка уже
    /// однажды оказалось дороже искажения.
    /// Чинит только то, что похоже на русскую речь.
    ///
    /// Английская расшифровка не должна кириллизоваться: словарь приводит
    /// `prompt` к «промпт», и на английском тексте это порча, а не починка.
    ///
    /// Жило в отдельной копии словаря внутри приложения. Копий было две, и
    /// каждая правка — кросс-алфавитный поиск, падежи, кэш таблиц — вносилась
    /// в обе руками. Работало это ровно до первого раза, когда кто-нибудь
    /// забудет.
    public static func restoreIfRussian(_ transcript: String) -> String {
        guard looksRussian(transcript) else { return transcript }
        return restore(transcript)
    }

    static func looksRussian(_ text: String) -> Bool {
        var cyrillic = 0
        var latin = 0
        for character in text.unicodeScalars {
            if ("\u{0400}"..."\u{04FF}").contains(character) { cyrillic += 1 }
            else if ("a"..."z").contains(character) || ("A"..."Z").contains(character) { latin += 1 }
        }
        // Треть — намеренно низко: фраза «поднимем LLM-фильтр в prod» на три
        // четверти латиница и всё-таки русская.
        let letters = cyrillic + latin
        return letters > 0 && Double(cyrillic) / Double(letters) > 0.33
    }

    public static func restore(_ transcript: String) -> String {
        let forms = canonicalForms()
        guard !forms.isEmpty, !transcript.isEmpty else { return transcript }

        var result = ""
        result.reserveCapacity(transcript.count)
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            result += forms[normalized(word)] ?? word
            word = ""
        }

        for character in transcript {
            // Дефис — часть слова: «пул-реквест» одно слово, а не два.
            if character.isLetter || character.isNumber || character == "-" {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// Термины словаря, встречающиеся в тексте. Для замера покрытия.
    public static func terms(in transcript: String) -> [String] {
        let forms = canonicalForms()
        var seen = Set<String>()
        var found: [String] = []
        for word in transcript.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let key = normalized(String(word))
            if let canonical = forms[key], seen.insert(key).inserted {
                found.append(canonical)
            }
        }
        return found
    }
}
