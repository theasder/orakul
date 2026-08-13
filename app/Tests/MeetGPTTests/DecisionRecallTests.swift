import Foundation
import Testing
@testable import MeetGPT

/// F1 from the RICE roadmap: cross-meeting decision recall. The mined pain:
/// "the part that kills me is the relitigating… nobody's sure what we landed
/// on" — answered by interrogating the sessions already on disk. Tests inject
/// the deterministic hashing embedder: recall must behave identically on a
/// machine with no NLEmbedding model, and tests must not depend on Apple's
/// embedding weights.
@Suite("Decision recall")
struct DecisionRecallTests {

    private func scratchStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    private func session(title: String, daysAgo: Double, digest: String,
                         transcript: [String] = [], goal: String = "") -> SavedSession {
        let started = Date().addingTimeInterval(-daysAgo * 86_400)
        return SavedSession(
            id: UUID(), title: title, startedAt: started, savedAt: started,
            goal: goal,
            entries: transcript.map {
                TranscriptEntry(id: UUID(), source: .system, text: $0,
                                timestamp: started, speaker: nil)
            },
            aiResponse: "", digest: digest)
    }

    private let embedder = HashingSkillTextEmbedder()

    @Test("окно расшифровки накрывает и вопрос, и ответ на него")
    func windowCoversQuestionAndAnswer() throws {
        // В командной строке цитата — одно предложение, и на вопрос она
        // возвращала сам вопрос: отвечающий не повторяет тему, и словарный
        // поиск до ответа не дотягивается. Там это чинилось отдельно.
        //
        // Здесь единица крупнее — окно в 220 символов по репликам, — поэтому
        // ответ попадает в неё сам. Проверка не про новое поведение, а про то,
        // что его нельзя потерять: уменьшив окно, легко разлучить вопрос с
        // ответом и не заметить.
        let store = try scratchStore()
        try store.save(session(title: "Планёрка по тарифам", daysAgo: 2,
                               digest: "Обсуждали тарифы.",
                               transcript: [
                                "По тарифам — что решили в итоге?",
                                "Годовой не трогаем до декабря, месячный поднимаем на пятнадцать процентов.",
                               ]))

        let hits = DecisionRecallService.recall(query: "что решили по тарифам",
                                                store: store, embedder: embedder)
        let excerpt = hits.first?.excerpt ?? ""
        #expect(excerpt.contains("Годовой не трогаем"),
                "ответ не попал в цитату вместе с вопросом: «\(excerpt)»")
    }

    @Test("модели говорят, что часть архива не открылась")
    func recordSaysWhenItIsIncomplete() throws {
        // Раньше `SessionStore.list()` выбрасывал нечитаемый файл через
        // `compactMap { try? decode }` и не запоминал даже его имени. Модель
        // получала неполную запись без единого признака этого — и уверенно
        // отвечала «не обсуждали». Для продукта, который обещает не выдумывать,
        // это худший вид выдумки: не добавленный факт, а отсутствующий.
        let store = try scratchStore()
        try store.save(session(title: "Планёрка по тарифам", daysAgo: 3,
                               digest: "Решили поднять месячный тариф на пятнадцать процентов."))
        let broken = store.root.appendingPathComponent("сломанный.json")
        try Data("{\"id\": \"x\", \"tit".utf8).write(to: broken)

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about pricing", store: store, embedder: embedder))
        #expect(block.contains("INCOMPLETE RECORD"),
                "модели не сказали, что запись неполная: «\(block)»")
        #expect(block.contains("сломанный.json"), "не назван файл, который не открылся")
    }

    @Test("на целом архиве запись остаётся прежней")
    func intactArchiveAddsNoWarning() throws {
        // Граница: предупреждение в каждом запросе — это лишние токены и шум,
        // который модель начнёт повторять пользователю без повода.
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 3,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about usage-based pricing", store: store, embedder: embedder))
        #expect(!block.contains("INCOMPLETE"), "жалуется на целом архиве: «\(block)»")
    }

    @Test("официальное имя базы находит русскую речь о ней")
    func infrastructureNamesCrossAlphabet() throws {
        // Приложение — то, что скачивают, а не клонируют, и разбор слов у него
        // общий с командной строкой: `RussianLexicon.canonicalToken`. Общий он
        // именно затем, чтобы такие правки доходили до обеих поверхностей —
        // но «доходит» это утверждение, а не факт, пока его не проверить
        // здесь. В командной строке до этой правки не находилось ни одно из
        // девяти имён.
        let store = try scratchStore()
        try store.save(session(title: "Планёрка по инфраструктуре", daysAgo: 3,
                               digest: "Подняли редис до пятидесяти тысяч ключей. Постгрес обновили до шестнадцатой версии, нжинкс перенастроили."))
        try store.save(session(title: "Найм", daysAgo: 1,
                               digest: "Открываем две вакансии бэкендеров."))

        for asked in ["Redis", "PostgreSQL", "nginx"] {
            let hits = DecisionRecallService.recall(query: asked, store: store, embedder: embedder)
            #expect(hits.first?.sessionTitle == "Планёрка по инфраструктуре",
                    "«\(asked)» не нашёл звонок, где это обсуждали по-русски")
        }
    }

    @Test("finds the meeting where a topic was decided, from the digest")
    func findsDecisionAcrossSessions() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 12,
                               digest: "Decided to move to usage-based pricing at two cents per credit. Rationale: aligns cost with heavy transcription users."))
        try store.save(session(title: "Hiring pipeline", daysAgo: 8,
                               digest: "Agreed to open two senior backend roles and pause the design hire."))
        try store.save(session(title: "Weekly standup", daysAgo: 2,
                               digest: "Status updates only, no decisions recorded."))

        let hits = DecisionRecallService.recall(query: "what did we decide about usage-based pricing",
                                                store: store, embedder: embedder)
        #expect(hits.first?.sessionTitle == "Pricing sync")
        #expect(hits.first?.excerpt.contains("usage-based pricing") == true)
    }

    @Test("every excerpt is a verbatim slice of the stored session")
    func excerptsAreVerbatim() throws {
        let store = try scratchStore()
        let digest = "Decided to sunset the legacy API in June after the enterprise migration completes."
        try store.save(session(title: "Platform review", daysAgo: 3, digest: digest))

        let hits = DecisionRecallService.recall(query: "sunset legacy API",
                                                store: store, embedder: embedder)
        let hit = try #require(hits.first)
        #expect(digest.contains(hit.excerpt) || hit.excerpt.contains("sunset the legacy API"),
                "an excerpt must be quotable back to the record, never a paraphrase")
    }

    @Test("transcript windows are searched when the digest is silent")
    func transcriptWindowsSearched() throws {
        let store = try scratchStore()
        try store.save(session(title: "Vendor call", daysAgo: 5,
                               digest: "General discussion.",
                               transcript: [
                                "So to confirm, we are renewing the Deepgram contract for twelve months.",
                                "Yes, and we revisit the on-device option at the next quarterly review.",
                               ]))

        let hits = DecisionRecallService.recall(query: "renewing the Deepgram contract",
                                                store: store, embedder: embedder)
        #expect(hits.contains { $0.excerpt.contains("renewing the Deepgram contract") })
    }

    @Test("identical relevance breaks toward the newer meeting")
    func recencyBreaksTies() throws {
        let store = try scratchStore()
        let digest = "Decided to cancel the Berlin offsite."
        try store.save(session(title: "Older", daysAgo: 30, digest: digest))
        try store.save(session(title: "Newer", daysAgo: 1, digest: digest))

        let hits = DecisionRecallService.recall(query: "cancel the Berlin offsite",
                                                store: store, embedder: embedder)
        #expect(hits.first?.sessionTitle == "Newer",
                "when the same words match equally, the later meeting is the living decision")
    }

    @Test("respects the result limit")
    func limitRespected() throws {
        let store = try scratchStore()
        for day in 1...8 {
            try store.save(session(title: "Sync \(day)", daysAgo: Double(day),
                                   digest: "Decided to cancel the Berlin offsite, option \(day)."))
        }
        let hits = DecisionRecallService.recall(query: "cancel the Berlin offsite",
                                                store: store, embedder: embedder, limit: 4)
        #expect(hits.count == 4)
    }

    @Test("an empty history returns no hits, not an error")
    func emptyStore() throws {
        let store = try scratchStore()
        let hits = DecisionRecallService.recall(query: "anything at all",
                                                store: store, embedder: embedder)
        #expect(hits.isEmpty)
    }

    @Test("an unrelated query stays silent instead of dredging noise")
    func unrelatedQueryFiltered() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let hits = DecisionRecallService.recall(query: "kubernetes ingress teardown ceremony",
                                                store: store, embedder: embedder)
        #expect(hits.isEmpty, "no shared vocabulary must mean no hits — a wrong answer here relitigates worse than none")
    }

    @Test("one long paragraph cannot smuggle a whole meeting into the prompt")
    func excerptsAreBounded() throws {
        // A digest written without blank lines is a single paragraph. Uncapped,
        // its excerpt would be quoted into every recall request — tens of
        // kilobytes of an old meeting, on the user's credits, invisibly.
        let store = try scratchStore()
        let huge = "We decided to sunset the legacy API in June. "
            + String(repeating: "Then somebody said something else about the migration. ", count: 400)
        try store.save(session(title: "Marathon", daysAgo: 2, digest: huge))

        let hit = try #require(DecisionRecallService.recall(
            query: "what did we decide about the legacy API",
            store: store, embedder: embedder).first)
        #expect(hit.excerpt.count <= DecisionRecallService.maxExcerptCharacters)
        #expect(huge.contains(hit.excerpt), "a truncated quote is still a quote — never a paraphrase")

        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about the legacy API",
            store: store, embedder: embedder))
        #expect(block.count < 4 * DecisionRecallService.maxExcerptCharacters + 800,
                "the whole context block stays small enough to prepend to any request")
    }

    // MARK: ask-flow bridge

    @Test("recall intent is recognised in English and Russian, and only there")
    func intentGate() {
        for prompt in ["what did we decide about the API pricing?",
                       "did we agree on the launch date",
                       "what was decided last week about hiring",
                       "remind me what the previous meeting landed on",
                       "что мы решили про тарифы?",
                       "на прошлой встрече договорились про дедлайн?"] {
            #expect(DecisionRecallContext.matchesRecallIntent(prompt), "should match: \(prompt)")
        }
        for prompt in ["summarize this call",
                       "draft a follow-up email to the client",
                       "переведи этот текст на английский"] {
            #expect(!DecisionRecallContext.matchesRecallIntent(prompt), "should NOT match: \(prompt)")
        }
    }

    @Test("the context block quotes the record and names the meeting")
    func blockQuotesRecord() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let block = try #require(DecisionRecallContext.block(
            for: "what did we decide about usage-based pricing",
            store: store, embedder: embedder))
        #expect(block.contains("Pricing sync"))
        #expect(block.contains("usage-based pricing at two cents per credit"))
        #expect(block.contains("PRIOR-MEETING RECORD"))
    }

    @Test("no block for a non-recall prompt or an empty record")
    func blockAbsentWhenNotApplicable() throws {
        let store = try scratchStore()
        #expect(DecisionRecallContext.block(for: "what did we decide about pricing",
                                            store: store, embedder: embedder) == nil,
                "empty history must add nothing to the request")
        try store.save(session(title: "Pricing sync", daysAgo: 2,
                               digest: "Decided to move to usage-based pricing."))
        #expect(DecisionRecallContext.block(for: "summarize this call",
                                            store: store, embedder: embedder) == nil,
                "an ordinary prompt must not grow a recall preamble")
    }

    // MARK: discoverability

    @Test("the shipped chip actually triggers recall, rather than only naming it")
    func recallChipMatchesItsOwnGate() throws {
        // The button exists because recall was reachable only by guessing the
        // phrasing. That fix is worthless if the chip's own text misses the
        // gate — this is the test that keeps the two in step.
        let chip = try #require(QuickPrompts.all.first { $0.id == "recall" })
        #expect(DecisionRecallContext.matchesRecallIntent(chip.prompt),
                "the recall chip must match the recall intent gate it depends on")

        // And end to end: pressing it against a real store produces the record.
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 6,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        let block = try #require(DecisionRecallContext.block(for: chip.prompt,
                                                             store: store, embedder: embedder))
        #expect(block.contains("Pricing sync"))
    }

    @Test("the chip refuses to invent history when the record is silent")
    func recallChipInstructsAgainstFabrication() throws {
        // The failure this feature exists to prevent is a confidently wrong
        // memory of a decision. The prompt has to say so, because the model
        // will otherwise happily reconstruct one from the live transcript.
        let chip = try #require(QuickPrompts.all.first { $0.id == "recall" })
        #expect(chip.prompt.contains("say plainly that nothing was found"))
        #expect(chip.prompt.contains("quote"))
    }

    // MARK: pre-meeting brief bridge (F8)

    private func upcoming(title: String) -> UpcomingMeeting {
        UpcomingMeeting(id: "evt-1", title: title,
                        start: Date().addingTimeInterval(1800))
    }

    @Test("a meeting's brief sources quote what prior sessions decided on its topic")
    func briefSourcesFromHistory() throws {
        let store = try scratchStore()
        try store.save(session(title: "Pricing sync", daysAgo: 7,
                               digest: "Decided to move to usage-based pricing at two cents per credit."))
        try store.save(session(title: "Design review", daysAgo: 3,
                               digest: "Agreed the onboarding redesign ships behind a flag."))

        let sources = BriefRecallSources.build(for: upcoming(title: "Pricing sync follow-up"),
                                               store: store, embedder: embedder)
        #expect(!sources.isEmpty && sources.count <= 3)
        let first = try #require(sources.first)
        #expect(first.server == BriefRecallSources.serverLabel)
        #expect(first.text.contains("Pricing sync"))
        #expect(first.text.contains("usage-based pricing"))
        #expect(first.readFor == "Pricing sync follow-up")
    }

    @Test("no history on the topic means no invented sources")
    func briefSourcesEmptyWhenIrrelevant() throws {
        let store = try scratchStore()
        try store.save(session(title: "Hiring pipeline", daysAgo: 3,
                               digest: "Agreed to open two senior backend roles."))
        let sources = BriefRecallSources.build(for: upcoming(title: "Quarterly kubernetes ceremony"),
                                               store: store, embedder: embedder)
        #expect(sources.isEmpty)
    }
}

/// Поиск по своим звонкам через границу алфавита — в приложении.
///
/// Тот же разрыв, что нашёлся в командной строке, только здесь он дороже:
/// приложение — это то, что скачивают. Расшифровку канонизируют при
/// сохранении («промпт»), а запрос не канонизировали никогда, и человек,
/// набравший `prompt`, не находил свой же звонок.
///
/// Для русского запроса лексическая половина — это весь поиск: вторая половина
/// считается системной моделью предложений macOS, а она англоязычная.
@Suite("Кросс-алфавитный поиск в приложении")
struct DecisionRecallCrossAlphabetTests {

    @Test("обе формы термина дают один токен",
          arguments: [("prompt", "промпт"), ("prod", "прод"), ("апи", "api")])
    func spellingsCollapseToOneToken(pair: (String, String)) {
        let left = DecisionRecallService.tokens(in: pair.0)
        let right = DecisionRecallService.tokens(in: pair.1)
        #expect(left == right,
                "«\(pair.0)» и «\(pair.1)» разошлись: \(left) против \(right)")
        #expect(!left.isEmpty, "токенов не осталось вовсе — проверка пустая")
    }

    @Test("запрос латиницей пересекается с расшифровкой на кириллице")
    func latinQueryOverlapsCyrillicTranscript() {
        // Ровно тот случай: в архиве канон «промпт», человек ищет `prompt`.
        let transcript = DecisionRecallService.tokens(in: "Мы поменяли промпт для модели")
        let query = DecisionRecallService.tokens(in: "что там с prompt")
        #expect(!transcript.intersection(query).isEmpty,
                "запрос латиницей не пересёкся с канонической расшифровкой")
    }

    @Test("падеж термина ищется наравне с самим термином",
          arguments: [("деплой", "деплою"), ("коммит", "коммита"),
                      ("фича", "фичи"), ("промпт", "промпты"),
                      ("промпт", "prompts")])
    func inflectionsFindTheTerm(pair: (String, String)) {
        // То же, что в командной строке, но здесь это то, что скачивают.
        // Страница обещает падежи; для терминов их не понимал никто.
        let left = DecisionRecallService.tokens(in: pair.0)
        let right = DecisionRecallService.tokens(in: pair.1)
        #expect(left == right, "«\(pair.0)» и «\(pair.1)» разошлись: \(left) / \(right)")
    }

    @Test("термин не обрезается сам по себе")
    func termsAreNotStripped() {
        // Обрезка канона превращает «коммит» в «комм»: у термина на конце
        // обычное русское окончание. Регрессию поймала мутация.
        #expect(DecisionRecallService.tokens(in: "коммит") == ["коммит"])
        #expect(DecisionRecallService.tokens(in: "деплой") == ["деплой"])
    }

    @Test("слово не из словаря между алфавитами не переводится")
    func unknownWordsAreNotTransliterated() {
        // Границы: словарь — таблица измеренных терминов, а не транслитератор.
        // Находить то, чего не говорили, дороже, чем не найти.
        #expect(DecisionRecallService.tokens(in: "cat") == ["cat"])
        #expect(DecisionRecallService.tokens(in: "кот") == ["кот"])
    }
}

/// Цитата из расшифровки — вместе с говорящим.
///
/// `TranscriptEntry` знает `speaker`, а окна поиска строились по
/// `entries.map(\.text)`: имя выбрасывалось, реплики склеивались через пробел.
/// Получались две беды сразу — цитату некому приписать, и одно окно могло
/// накрыть двух человек, так что слова одного читались как слова другого.
@Suite("Говорящий в цитате приложения")
struct RecallSpeakerAttributionTests {

    private func session(_ entries: [(String?, String)]) -> SavedSession {
        let started = Date()
        return SavedSession(
            id: UUID(), title: "Планёрка", startedAt: started, savedAt: started,
            goal: "",
            entries: entries.map { speaker, text in
                TranscriptEntry(id: UUID(), source: .system, text: text,
                                timestamp: started, speaker: speaker)
            },
            aiResponse: "", digest: "")
    }

    @Test("имя говорящего доходит до окна расшифровки")
    func windowsCarryTheSpeaker() {
        let units = DecisionRecallService.unitsForTesting(
            of: session([("Борис", "Выкатываем в пятницу, откат готовим заранее")]))
        let transcript = units.filter { $0.isTranscript }.map(\.text).joined()
        #expect(transcript.contains("Борис"),
                "окно расшифровки потеряло говорящего: \(transcript)")
    }

    @Test("смена говорящего видна внутри окна")
    func speakerChangeStaysVisible() {
        // Худший случай прежнего склеивания: два человека в одном окне без
        // единой пометки, и ответ выглядит как реплика одного.
        let units = DecisionRecallService.unitsForTesting(
            of: session([("Аня", "Кто дежурит"), ("Борис", "Я дежурю все выходные")]))
        let transcript = units.filter { $0.isTranscript }.map(\.text).joined()
        #expect(transcript.contains("Аня") && transcript.contains("Борис"),
                "в окне не различить, кто говорит: \(transcript)")
    }

    @Test("реплика без имени остаётся как есть")
    func unnamedEntriesAreLeftAlone() {
        // Диаризация бывает выключена — тогда имени нет вовсе, и выдумывать
        // его нельзя.
        let units = DecisionRecallService.unitsForTesting(
            of: session([(nil, "Договорились про релиз в среду")]))
        let transcript = units.filter { $0.isTranscript }.map(\.text).joined()
        #expect(transcript.contains("Договорились про релиз"))
        #expect(!transcript.contains(":"), "появилось двоеточие там, где имени нет")
    }
}
