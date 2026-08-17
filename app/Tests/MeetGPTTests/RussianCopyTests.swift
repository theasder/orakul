import Foundation
import Testing
@testable import MeetGPT

/// Правила русского текста в интерфейсе — по ru-deslop.
///
/// Тексты в приложении пишутся и правятся порциями, и портятся тоже порциями:
/// в одном месте «расшифровка», в другом «транскрипт»; в третьем появляется
/// «является» и «осуществляется». Читатель по этому опознаёт машинный перевод —
/// ровно то, чего продукт для русскоязычных разработчиков позволить себе не
/// может.
///
/// Проверяются только строки в кавычках: комментарии пишутся для нас, а не для
/// пользователя, и канцелярит в них никого не отпугнёт.
@Suite("Русские тексты интерфейса")
struct RussianCopyTests {

    /// Не только `Views`. Текст, который человек читает, лежит ещё в
    /// `Onboarding` (подсказки-коучи) и в `Models` (названия кнопок-подсказок).
    /// Пока проверялся один каталог, шестнадцать английских названий кнопок и
    /// три коуча доехали до собранного приложения — увидели их, только запустив
    /// его. Каталоги перечислены здесь, чтобы это не повторилось молча.
    private var sourceRoots: [URL] {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT")
        // Три папки интерфейса. `LLMProvider.keyConsoleHint` показывается в
        // настройках рядом с полем ключа, но лежит в `AI/` вместе с адресами
        // запросов — намеренно: консоль и адрес две половины одного факта, и
        // порознь они уже разъезжались (китайская консоль против
        // международного адреса, ключ на 401). Здесь его нет, и комментарий
        // раньше утверждал обратное — «путь добавлен явно», хотя в списке
        // всегда стояли те же три папки. Проверяет эти подсказки
        // `ProviderConsoleMatchTests`, построчно и по существу.
        //
        // `AppState.swift` сюда тоже не входит: в нём сто тридцать четыре
        // английские строки, и почти все — тела промптов и журнал. Видимую
        // его часть проверяет `visibleStateIsRussian` — по имени поля.
        return ["Views", "Onboarding", "Models"].map(base.appendingPathComponent)
    }

    /// Строковые литералы всех файлов интерфейса, кроме платного экрана: он
    /// недостижим (см. NoTariffsTests), и переводить его незачем.
    /// Только экранный текст. `Models` сюда не входит: там тела подсказок,
    /// которые уходят модели, а не пользователю. Считать их «английским на
    /// экране» — значит завышать долг и толкать себя переписывать выверенные
    /// промпты ради зелёного числа.
    private func onScreenLiterals() -> [(file: String, text: String)] {
        // Исключения для экрана с ценами больше нет: сам экран удалён
        // (`NoTariffsTests` следит, чтобы не вернулся). Пока он лежал в
        // исходниках непереведённым, исключение приходилось объяснять; теперь
        // объяснять нечего.
        return literals().filter { entry in
            if entry.file.hasSuffix("QuickPrompt.swift")
                || entry.file.hasSuffix("PromptWorkflow.swift")
                || entry.file.hasSuffix("SampleCall.swift")
                || entry.file.hasSuffix("RecordingContext.swift") { return false }
            return true
        }
    }

    private func literals() -> [(file: String, text: String)] {
        var result: [(String, String)] = []
        let walkers = sourceRoots.compactMap {
            FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)
        }
        for case let url as URL in walkers.flatMap({ $0.compactMap { $0 as? URL } })
        where url.pathExtension == "swift" {
            guard !url.path.contains("/Paywall/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Многострочные блоки считаются отдельно. Разбор по кавычкам
            // на строке их не видит: у `\"\"\"`-текста кавычек внутри нет, и
            // подсказки `.help(\"\"\"…\"\"\")` — самый видимый текст в
            // интерфейсе — проходили мимо проверки целиком.
            // Многострочный блок считается, только если он открыт вызовом,
            // который показывает текст человеку: `.help(`, `Text(`, подписи
            // доступности. Без этого сюда хлынут подсказки модели — их в
            // приложении больше, чем интерфейса, и проверка утонет в них, как
            // и предупреждает комментарий выше.
            let uiOpeners = [".help(", "Text(", ".accessibilityLabel(", ".accessibilityHint("]
            var insideBlock = false
            var blockIsUI = false
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("\"\"\"") {
                    if insideBlock {
                        insideBlock = false
                        blockIsUI = false
                    } else {
                        insideBlock = true
                        blockIsUI = uiOpeners.contains { trimmed.contains($0) }
                    }
                    continue
                }
                guard !trimmed.hasPrefix("//") else { continue }
                if insideBlock {
                    if blockIsUI, !trimmed.isEmpty {
                        result.append((url.lastPathComponent, trimmed))
                    }
                    continue
                }
                for (index, chunk) in line.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
                where index % 2 == 1 {
                    result.append((url.lastPathComponent, String(chunk)))
                }
            }
        }
        return result
    }

    private func russianLiterals() -> [(file: String, text: String)] {
        literals().filter {
            $0.text.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    @Test("в исключённых файлах видимые поля всё равно по-русски")
    func excludedFilesStillHaveRussianVisibleFields() {
        // Четыре файла выше исключены целиком, потому что в них лежат тела
        // промптов — модельный текст, английский намеренно. Но рядом с телом
        // лежат подписи для человека, и они выпали из счёта заодно: все
        // шестнадцать подсказок к кнопкам промптов оставались английскими, а
        // счётчик показывал ноль. Исключение по файлу слишком грубое, поэтому
        // здесь проверка с другой стороны — не «чего не должно быть», а «что
        // обязано быть русским».
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Models")

        let quick = (try? String(contentsOf: base.appendingPathComponent("QuickPrompt.swift"),
                                 encoding: .utf8)) ?? ""
        #expect(!quick.isEmpty, "не прочитался QuickPrompt.swift")

        // `tooltip:` и `title:` человек читает; `prompt:` уходит в модель.
        for field in ["tooltip", "title"] {
            let visible = quick.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .compactMap { line -> String? in
                    guard let range = line.range(of: "\(field): \"") else { return nil }
                    let rest = line[range.upperBound...]
                    guard let end = rest.firstIndex(of: "\"") else { return nil }
                    return String(rest[..<end])
                }
                // Пустые и подставляемые значения не в счёт.
                .filter { $0.count > 3 && !$0.contains("\\(") }
            #expect(!visible.isEmpty, "поле \(field) не нашлось — проверка была бы фиктивной")
            for value in visible {
                #expect(value.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) != nil,
                        "\(field) по-английски: «\(value)»")
            }
        }
    }

    @Test("нет канцелярита и штампов")
    func noOfficialese() {
        // «Является» и «осуществляется» — первый признак текста, написанного не
        // для человека. Живой глагол или тире короче и понятнее.
        let banned = ["является", "осуществля", "производится", "в целях",
                      "при помощи", "данный инструмент", "представляет собой",
                      "стоит отметить", "играет ключевую роль", "в современном мире"]
        var offenders: [String] = []
        for (file, text) in russianLiterals() {
            let lowered = text.lowercased()
            for phrase in banned {
                // По границе слова, а не подстрокой: «появляется» содержит
                // «является», и проверка на подстроку ловила бы совершенно
                // нормальную фразу. На странице такой ложный сигнал уже был.
                let pattern = "(^|[^а-яё])\(phrase)"
                guard lowered.range(of: pattern, options: .regularExpression) != nil else { continue }
                offenders.append("\(file): «\(phrase)» в «\(text.prefix(50))»")
            }
        }
        #expect(offenders.isEmpty, "канцелярит: \(offenders.joined(separator: "; "))")
    }

    @Test("значимость не надувается")
    func noInflation() {
        // «Мощный», «бесшовный», «интуитивный» ничего не сообщают: либо
        // конкретика, либо вон.
        let banned = ["мощный", "мощная", "революцион", "бесшовн", "интуитивн",
                      "уникальн", "инновацион", "легко и просто"]
        var offenders: [String] = []
        for (file, text) in russianLiterals() {
            let lowered = text.lowercased()
            for word in banned where lowered.contains(word) {
                offenders.append("\(file): «\(word)» в «\(text.prefix(50))»")
            }
        }
        #expect(offenders.isEmpty, "надувание значимости: \(offenders.joined(separator: "; "))")
    }

    @Test("одна вещь называется одним словом")
    func oneNamePerThing() {
        // Готовый текст звонка в продукте называется «транскрипт» — так он
        // назван в русском демо-фильме, и это же слово стоит на панели.
        // «Расшифровка» остаётся для процесса: язык расшифровки, расшифровка
        // недоступна.
        //
        // Ловится именно смешение: «в расшифровке» и «со всей расшифровкой»
        // говорят про готовый текст, то есть про транскрипт.
        let artefactSense = ["в расшифровке", "со всей расшифровкой", "расшифровку звонка",
                             "всю расшифровку", "расшифровки звонка"]
        var offenders: [String] = []
        for (file, text) in russianLiterals() {
            let lowered = text.lowercased()
            for phrase in artefactSense where lowered.contains(phrase) {
                offenders.append("\(file): «\(phrase)» — это транскрипт")
            }
        }
        #expect(offenders.isEmpty, "два слова про одно: \(offenders.joined(separator: "; "))")
    }

    @Test("записанный разговор всюду называется звонком")
    func recordedCallIsAlwaysAZvonok() {
        // Второй случай того же правила. «Встреча» законна ровно в одном
        // смысле — событие в календаре, до которого приложение напоминает
        // («Перед встречей», «Время до встречи»). Всё, что уже записано,
        // сохранено и ищется, — звонок, как в русском демо-фильме.
        let calendarSense = ["перед встреч", "до встречи", "напоминать перед"]
        var offenders: [String] = []
        for (file, text) in russianLiterals() {
            let lowered = text.lowercased()
            guard lowered.contains("встреч") else { continue }
            guard !calendarSense.contains(where: { lowered.contains($0) }) else { continue }
            offenders.append("\(file): «\(text.prefix(60))»")
        }
        #expect(offenders.isEmpty,
                "записанное — это звонок, не встреча: \(offenders.joined(separator: "; "))")
    }

    /// Сколько английских фраз ещё осталось на экранах. Число здесь —
    /// не цель, а храповик: оно может только уменьшаться.
    ///
    /// Почему так, а не «ноль». Прежний счётчик искал текст по четырём
    /// синтаксическим шаблонам (`Text(`, `Label(`, `caption:`, `title:`) и
    /// показывал ноль, пока в приложении оставались `Button("Run test")`,
    /// `label: "System audio"` и целые тернарники по-английски. Их нашли,
    /// запустив приложение. Настоящее число — вот это, и прятать его за
    /// зелёным тестом было бы враньём себе.
    /// Английские фразы, которые остаются английскими намеренно.
    ///
    /// Подсказок «где взять ключ» здесь больше нет: они переехали к
    /// `LLMProvider.keyConsoleHint`, чтобы стоять рядом с адресом запроса —
    /// консоль и адрес оказались двумя половинами одного факта и порознь
    /// разъехались (китайская консоль против международного адреса, ключ на
    /// 401). Эта проверка обходит папки интерфейса, а весь файл `LLMModel`
    /// включить нельзя: там же лежат подсказки модели, и проверка утонет в
    /// шуме. Сами подсказки проверяет `ProviderConsoleMatchTests` — построчно
    /// и по существу, а не по числу.
    ///
    /// Их две, и каждая — не недоделка перевода:
    ///
    /// - `Google Workspace` — имя продукта, по-русски его не называют;
    /// - `orakul, RICE, ARR, Kubernetes…` — пример перечисления терминов.
    ///
    /// Было восемь: пять строк вида `platform.openai.com → API keys` уехали к
    /// `LLMProvider.keyConsoleHint` (см. абзац выше), и список остался с
    /// прежним числом — «восемь» при двух записях. Число в тексте, которое
    /// нечем проверить, разъезжается с кодом первым; поэтому ниже стоит
    /// проверка, сверяющая эту фразу с размером набора.
    ///
    /// Поэтому число проверяется на равенство: и рост, и «улучшение»
    /// переводом требуют объяснения.
    static let deliberateEnglish: Set<String> = [
        "Google Workspace",
        "orakul, RICE, ARR, Kubernetes…",
    ]

    static let remainingEnglishPhrases = deliberateEnglish.count

    /// Число прописью в комментарии выше — против размера набора.
    @Test("список намеренно английских фраз совпадает со своим описанием")
    func deliberateListMatchesItsDescription() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let words = ["одна": 1, "две": 2, "три": 3, "четыре": 4, "пять": 5,
                     "шесть": 6, "семь": 7, "восемь": 8, "девять": 9, "десять": 10]
        let line = try #require(
            source.split(separator: "\n").first { $0.contains("/// Их ") },
            "строка «Их …» пропала — число больше нечем сверить")
        let stated = words.first { line.contains("Их \($0.key),") }?.value
        #expect(stated == Self.deliberateEnglish.count,
                "в описании «\(line.trimmingCharacters(in: .whitespaces))», а в наборе \(Self.deliberateEnglish.count)")
    }

    /// Шаблон DateFormatter, а не текст для человека.
    ///
    /// Признаков два, и оба обязательны: все буквы — служебные буквы шаблона
    /// (`EEEE`, `MMMM`, `HH`, `mm`, `yyyy`, `d`), и хотя бы одна из них
    /// повторена подряд.
    ///
    /// Одного первого признака мало: «May Day» тоже состоит только из таких
    /// букв, и правило молча вычеркнуло бы английскую фразу — ровно то, что
    /// этот храповик обязан ловить. Удвоение (EEEE, HH, mm) для шаблона
    /// обязательно и в обычной речи не встречается.
    private func isDateFormat(_ text: String) -> Bool {
        let patternLetters = Set("EMdHhmsyaZzGwWDFkKSXV")
        let letters = Array(text.filter { $0.isLetter })
        guard !letters.isEmpty, letters.allSatisfy({ patternLetters.contains($0) }) else {
            return false
        }
        return zip(letters, letters.dropFirst()).contains { $0 == $1 }
    }

    /// Текст, который человек читает, живёт не только в папках интерфейса.
    ///
    /// `AppState` держит состояние, а представления его показывают: строка,
    /// присвоенная `firefliesImportError`, доходит до экрана через
    /// `Text(error)`. Проверка выше туда не смотрит — и не должна: в том же
    /// файле лежат тела промптов и строки журнала, их там сто тридцать четыре,
    /// и счётчик утонул бы. Поэтому здесь правило узкое: литерал, присвоенный
    /// полю с именем на `Error`, `Status`, `Message`, `Notice`, `Warning`, —
    /// это текст для человека.
    ///
    /// Так нашлись пять английских строк: «Couldn't reach Fireflies»,
    /// «Couldn't import that meeting», «Error: …», «Reused suggestions from
    /// the last five minutes», «Synthetic connected-app fixture ready for
    /// review». Первые три к тому же прятались от счётчика по другой причине:
    /// он пропускает литералы с подстановкой, а в них она была.
    @Test("состояние, которое показывают на экране, задаётся по-русски")
    func visibleStateIsRussian() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT")
        var english: [String] = []
        var checked = 0
        for name in ["AppState.swift"] {
            let source = try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      let range = trimmed.range(of:
                        "\\w*(Error|Status|Message|Notice|Warning) = \"",
                        options: .regularExpression) else { continue }
                let rest = trimmed[range.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { continue }
                let text = String(rest[..<end])
                checked += 1
                guard text.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) == nil
                else { continue }
                let core = text.replacingOccurrences(
                    of: "\\\\\\(.*?\\)", with: "", options: .regularExpression)
                let words = core.components(separatedBy: CharacterSet.letters.inverted)
                    .filter { $0.count > 2 }
                guard words.count >= 2, core.rangeOfCharacter(from: .uppercaseLetters) != nil
                else { continue }
                english.append(text)
            }
        }
        #expect(checked > 10, "нашлось всего \(checked) присваиваний — проверка смотрит не туда")
        #expect(english.isEmpty, "по-английски на экране: \(english.joined(separator: " | "))")
    }

    /// Уведомления — самая заметная поверхность приложения: они появляются
    /// поверх всего посреди звонка. Ни счётчик английских фраз, ни проверка
    /// видимого состояния сюда не смотрели: `Detection/` — не папка
    /// интерфейса, и полей на `Error`/`Status` там нет. Так по-английски
    /// оставались «Start recording», «Incoming call — Zoom», «Blind spot» и
    /// «Starts in 5 min (…) — open Cruxwing to record», где вдобавок стоит имя
    /// другого продукта.
    @Test("уведомления написаны по-русски и называют наш продукт")
    func notificationsAreRussian() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Detection")
        var english: [String] = []
        var checked = 0
        // Только те файлы, что составляют текст уведомления. `CallDetector`
        // сюда не входит намеренно: в нём лежат имена чужих приложений и куски
        // заголовков окон («Google Meet», «zoom meeting») — это не наш текст, и
        // переводить их нельзя, иначе звонок перестанет опознаваться.
        let notifiers = ["CallNotifier.swift", "MeetingReminderScheduler.swift",
                         "BlindSpotNotifier.swift"]
        let files = notifiers.map(base.appendingPathComponent)
        for url in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Только то, что попадает в уведомление: заголовок, тело,
                // подпись действия. Имена приложений («Google Meet») сюда не
                // попадают — они не наш текст.
                guard trimmed.contains("content.title") || trimmed.contains("content.body")
                        || trimmed.contains("content.subtitle") || trimmed.contains("title: \"")
                        || trimmed.contains("return (\"") || trimmed.contains("\", \"")
                else { continue }
                for part in trimmed.split(separator: "\"", omittingEmptySubsequences: false)
                    .enumerated().filter({ $0.offset % 2 == 1 }).map({ String($0.element) }) {
                    guard part.count > 7, part.contains(" ") else { continue }
                    checked += 1
                    #expect(!part.contains("Cruxwing"),
                            "в уведомлении имя другого продукта: \(part)")
                    guard part.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive])
                            == nil else { continue }
                    let words = part.components(separatedBy: CharacterSet.letters.inverted)
                        .filter { $0.count > 2 }
                    if words.count >= 2 { english.append(part) }
                }
            }
        }
        #expect(checked > 3, "проверено всего \(checked) строк — смотрим не туда")
        #expect(english.isEmpty, "по-английски в уведомлениях: \(english.joined(separator: " | "))")
    }

    /// Разрешения и вход — те же слова, что уведомления, только в другом
    /// файле. По-английски оставались «Microphone access denied. Open System
    /// Settings → …, allow Cruxwing», такой же текст про запись экрана и два
    /// сообщения о слетевшем входе, обещавшие «AI credits» — то, чего у orakul
    /// нет вовсе. Первое из них человек видит при первом же запуске.
    /// Строки, которые человек не читает: они уходят в модель или в поиск.
    ///
    /// Список короткий и с причиной у каждой — иначе он превратится в место,
    /// куда сваливают непереведённое. Проверка выше нашла три; две оказались
    /// такими, третья («Workflow: … → …») показывалась в двух представлениях
    /// и переведена.
    static let notForPeople: Set<String> = [
        // Запрос к коннекторам, когда цель звонка не задана: слова ищутся в
        // чужих сервисах, где всё по-английски.
        "canonical project product people acronym API technical terminology",
        // Заголовок куска запроса к модели, попадает в отладочный след.
        // Разбор берёт строку как она написана в коде, вместе с \n и подстановкой.
        #"Packed connector facts:\n\(packed)"#,
    ]

    @Test("разрешения и вход объясняются по-русски и без чужого имени")
    func permissionAndSignInCopyIsRussian() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/AppState.swift")
        let source = try String(contentsOf: base, encoding: .utf8)
        var checked = 0
        var problems: [String] = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            // Строки, которые кладут в `lastError`/`status`/`message` — это
            // то, что человек читает, когда что-то не получилось.
            guard trimmed.hasPrefix("let msg = \"") || trimmed.hasPrefix("return \"")
            else { continue }
            guard let open = trimmed.firstIndex(of: "\""),
                  let close = trimmed.lastIndex(of: "\""), open < close else { continue }
            let text = String(trimmed[trimmed.index(after: open)..<close])
            guard text.count > 20, text.contains(" ") else { continue }
            checked += 1
            guard !Self.notForPeople.contains(text) else { continue }
            if text.contains("Cruxwing") { problems.append("чужое имя: \(text)") }
            if text.lowercased().contains("credits") { problems.append("кредиты: \(text)") }
            let cyrillic = text.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive])
            if cyrillic == nil {
                let words = text.components(separatedBy: CharacterSet.letters.inverted)
                    .filter { $0.count > 2 }
                if words.count >= 4 { problems.append("по-английски: \(text)") }
            }
        }
        #expect(checked > 5, "проверено всего \(checked) строк — смотрим не туда")
        #expect(problems.isEmpty, "\(problems.joined(separator: " | "))")
    }

    /// Последние углы: звук, хранилище, коннекторы, ИИ. Здесь текста для
    /// человека мало, но он самый неприятный — приходит, когда что-то не
    /// работает. По-английски оставались «No display available for capture» и
    /// «Invalid API key (check Settings → Integrations)».
    @Test("отказы в остальных папках тоже по-русски")
    func failuresElsewhereAreRussian() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT")
        var english: [String] = []
        var checked = 0
        for folder in ["Audio", "Persistence", "AI", "MCP", "Integrations"] {
            guard let walker = FileManager.default.enumerator(
                at: base.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for line in source.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    // Только то, что уходит человеку: видимое состояние и
                    // описание ошибки. Промпты и адреса сюда не попадают.
                    guard trimmed.contains("NSLocalizedDescriptionKey: \"")
                            || trimmed.contains("lastError = \"")
                            || trimmed.contains("let message = \"")
                            || trimmed.contains("onError?(\"")
                            || trimmed.contains("onTerminalFailure?(\"") else { continue }
                    for part in trimmed.split(separator: "\"", omittingEmptySubsequences: false)
                        .enumerated().filter({ $0.offset % 2 == 1 }).map({ String($0.element) }) {
                        guard part.count > 14 else { continue }
                        checked += 1
                        guard part.range(of: "[а-яё]", options: [.regularExpression,
                                                                 .caseInsensitive]) == nil
                        else { continue }
                        let words = part.components(separatedBy: CharacterSet.letters.inverted)
                            .filter { $0.count > 2 }
                        if words.count >= 3 { english.append("\(url.lastPathComponent): \(part)") }
                    }
                }
            }
        }
        // Порог низкий намеренно: таких строк в этих папках и правда мало —
        // шесть. Он стоит не ради числа, а чтобы проверка не проходила молча,
        // если шаблоны перестанут совпадать вовсе.
        #expect(checked >= 5, "проверено всего \(checked) строк — смотрим не туда")
        #expect(english.isEmpty, "\(english.joined(separator: " | "))")
    }

    @Test("английских фраз на экране не становится больше")
    func englishProseOnlyShrinks() {
        // Берутся все литералы без кириллицы, похожие на речь: есть пробел и
        // хотя бы два латинских слова длиннее двух букв. Идентификаторы,
        // имена SF Symbols и ключи пробелов не содержат и отсеиваются сами;
        // интерполяции пропускаются — это куски формата, а не фразы.
        var phrases: Set<String> = []
        for (_, text) in onScreenLiterals() {
            guard text.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) == nil,
                  !text.contains("\\("),
                  text.contains(" ") else { continue }
            let words = text
                .components(separatedBy: CharacterSet(charactersIn:
                    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").inverted)
                .filter { $0.count > 2 }
            guard words.count >= 2 else { continue }
            // Строки без единой заглавной — это ключевые слова для распознавания
            // («tech debt», «term sheet», «cap table»), а не текст на экране.
            // Их и нельзя переводить: русские разработчики говорят их
            // по-английски посреди русской фразы, и перевод сломал бы
            // определение темы звонка. Фраза для человека начинается с
            // заглавной.
            guard text.rangeOfCharacter(from: .uppercaseLetters) != nil else { continue }
            // Формат даты — не фраза. `"EEEE, d MMMM · HH:mm"` состоит из
            // подстановок DateFormatter: они обязаны быть латиницей, а месяц и
            // день недели по-русски выдаёт локаль, а не буквы шаблона. Это
            // ловится отдельно — DisplayLocaleTests.
            guard !isDateFormat(text) else { continue }
            phrases.insert(text)
        }
        // Ровно столько, не «не больше».
        //
        // Второй половиной храповика было `count > remainingEnglishPhrases - 25`.
        // При счётчике 8 это `> -17` — условие, которое не может не выполниться.
        // Проверка, которая не умеет упасть, — не проверка; в этом репозитории
        // за такими отдельно охотятся (см. проверку про «пройдено, ничего не
        // выполнив»). Запас в 25 имел смысл, пока фраз было три десятка.
        //
        // Равенство заставляет объяснять любое движение в обе стороны: новая
        // английская фраза на экране роняет проверку, и перевод одной из
        // восьми — тоже, потому что переводить их нельзя (см. ниже).
        // Не количество, а сам список.
        //
        // Счёт ловит появление новой фразы, но не подмену: заменить одну
        // английскую строку другой — восемь так и остаётся восемью. Проверено
        // мутацией. Раз причины перечислены поимённо, пусть список и будет
        // тем, что проверяется: тогда любое движение — добавили, убрали,
        // подменили — придётся объяснить.
        #expect(phrases == Self.deliberateEnglish,
                "список английских фраз изменился: \(phrases.symmetricDifference(Self.deliberateEnglish).sorted().joined(separator: " | "))")
    }

    @Test("интерфейс говорит по-русски, а не наполовину")
    func noHalfTranslatedStrings() {
        // Самая заметная поломка: строка, где перевели первое предложение и
        // забыли второе. Ловится по латинским словам внутри русской строки —
        // кроме имён сервисов и технических терминов, которые так и пишутся.
        let allowed: Set<String> = [
            "orakul", "cruxwing", "google", "notion", "linear", "asana", "jira",
            "fireflies", "zapier", "deepgram", "whisper", "assemblyai", "openai",
            "anthropic", "claude", "gpt", "gemini", "deepseek", "qwen", "zhipu",
            "moonshot", "kimi", "glm", "mcp", "oauth", "api", "http", "https",
            // Мессенджеры: марки сервисов, а не забытый перевод.
            "mattermost", "rocket", "chat", "telegram", "teams", "bot", "botfather", "pachca",
            "gitlab", "gitea", "forgejo", "zulip",
            "redmine", "outline", "settings", "tokens", "teamly", "app",
            "matrix", "element",
            "json", "url", "pdf", "mac", "macos", "kaiten", "yougile",
            "weeek", "pyrus", "slack", "confluence", "hubspot", "attio", "sentry",
            "posthog", "amplitude", "mixpanel", "intercom", "zoom", "atlassian",
            "env", "wasapi", "screencapturekit", "llm", "sberjazz",
            "trueconf", "doc", "sheet", "drive", "calendar", "docs", "sheets",
            "workspace", "slides", "forms",
            "org", "base", "small", "medium", "large", "tiny", "auto",
            // Имена и торговые марки, которые по-русски так и пишутся.
            "apple", "crm", "salesforce", "affinity", "chatgpt", "cursor",
            "cookie", "client", "secret", "desktop", "word", "docx", "acme",
            "streamable", "dynamic", "registration", "socratic", "github",
            "sms", "finder", "rice", "arr", "kubernetes",
            // Названия методик: специалист пишет их латиницей.
            "daci", "raid", "bluf", "invest", "steelman", "severity",
        ]
        var offenders: [String] = []
        for (file, text) in russianLiterals() {
            // Интерполяции — это имена свойств, а не текст на экране:
            // `\(item.name)` пользователь видит как значение, а не как слово
            // "item". Без этой очистки тест ловил почти каждую строку и не
            // показывал настоящие огрехи.
            // Строка могла оборваться на кавычке внутри интерполяции
            // (`?? ""`), поэтому незакрытый хвост тоже отбрасывается.
            let withoutInterpolation = text
                .replacingOccurrences(of: #"\\\([^)]*\)"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\\\(.*$"#, with: " ", options: .regularExpression)
                // Адреса — не текст: «platform.deepseek.com» это место, куда
                // человеку идти за ключом, и переводить в нём нечего.
                // Перечислять их в списке разрешённых слов пришлось бы вечно.
                .replacingOccurrences(of: #"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+"#,
                                      with: " ", options: .regularExpression)
            let latin = withoutInterpolation.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz").inverted)
                .filter { $0.count > 2 }
            let unexplained = latin.filter { !allowed.contains($0) }
            if !unexplained.isEmpty {
                offenders.append("\(file): \(unexplained.joined(separator: ",")) в «\(text.prefix(60))»")
            }
        }
        #expect(offenders.isEmpty, "недопереведено: \(offenders.joined(separator: " | "))")
    }
}
