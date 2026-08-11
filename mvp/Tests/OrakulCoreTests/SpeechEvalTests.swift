import Foundation
import Testing
@testable import OrakulCore

/// Метрика решает, какую модель распознавания мы возьмём. Если она врёт в нашу
/// пользу, мы возьмём не ту — поэтому она проверяется первой, до того как на
/// неё посмотрит хоть один движок.
@Suite("Оценка распознавания")
struct SpeechEvalTests {

    // MARK: - Нормализация

    @Test("«ё» и «е» — одно слово, а не расхождение движков")
    func yoIsNotADisagreement() {
        // Whisper пишет «всё», Parakeet — «все». Без склейки мы считали бы
        // орфографическую традицию ошибкой слуха и видели бы разницу там, где
        // звук расслышан одинаково.
        #expect(SpeechEval.normalize("Всё ещё") == SpeechEval.normalize("Все еще"))
    }

    @Test("пунктуация и регистр не считаются ошибками")
    func punctuationIgnored() {
        let rate = SpeechEval.wordErrorRate(reference: "Поднимем фильтр в прод.",
                                            hypothesis: "поднимем фильтр в прод")
        #expect(rate.errors == 0)
    }

    // MARK: - WER

    @Test("идеальная расшифровка даёт ноль")
    func perfectIsZero() {
        let text = "мы решили перейти на оплату за использование"
        #expect(SpeechEval.wordErrorRate(reference: text, hypothesis: text).rate == 0)
    }

    @Test("замена, пропуск и вставка считаются по отдельности")
    func operationsAreCountedSeparately() {
        // Суммарное расстояние не отвечает на вопрос, речь сломалась или
        // ПРОПАЛА. Глоссарий в промпте когда-то поднял recall терминов ценой
        // 2757 пропусков — по одному числу это выглядело бы улучшением.
        let substitution = SpeechEval.wordErrorRate(reference: "поднимем фильтр в прод",
                                                    hypothesis: "поднимем фильтр в тест")
        #expect(substitution.substitutions == 1)
        #expect(substitution.deletions == 0 && substitution.insertions == 0)

        let deletion = SpeechEval.wordErrorRate(reference: "поднимем фильтр в прод",
                                                hypothesis: "поднимем фильтр")
        #expect(deletion.deletions == 2)
        #expect(deletion.substitutions == 0)

        let insertion = SpeechEval.wordErrorRate(reference: "поднимем фильтр",
                                                 hypothesis: "поднимем фильтр в прод")
        #expect(insertion.insertions == 2)
        #expect(insertion.substitutions == 0)
    }

    @Test("пустая расшифровка — это сто процентов ошибок, а не ноль")
    func emptyHypothesisIsTotalFailure() {
        // Движок, который промолчал, не «не ошибся». Ровно это и произошло с
        // большой моделью: WER 0.95 при почти полном молчании.
        let rate = SpeechEval.wordErrorRate(reference: "мы решили перейти на оплату",
                                            hypothesis: "")
        #expect(rate.rate == 1.0)
        #expect(rate.deletions == 5)
    }

    @Test("WER может быть больше единицы, и это не баг")
    func rateCanExceedOne() {
        // Галлюцинация длиннее исходной фразы — обычное поведение на границах
        // VAD-нарезки. Метрика, зажатая в 0…1, спрятала бы это.
        let rate = SpeechEval.wordErrorRate(reference: "да",
                                            hypothesis: "да и ещё много лишних слов")
        #expect(rate.rate > 1.0)
    }

    // MARK: - Термины без эталона

    @Test("расхождение на термине — доказательство ошибки без эталона")
    func disagreementProvesError() {
        // Один и тот же звук, три расшифровки. Кто прав — неизвестно, но что
        // кто-то неправ — известно точно.
        let reports = SpeechEval.termDisagreements(
            terms: ["LLM", "прод"],
            across: [
                "поднимем LLM фильтр в прод",
                "поднимем LLM фильтр в прод",
                "поднимем элэлэм фильтр в прод",
            ])
        let llm = reports.first { $0.term == "LLM" }!
        #expect(llm.isDisputed)
        #expect(llm.found == 2 && llm.total == 3)

        let prod = reports.first { $0.term == "прод" }!
        #expect(prod.isUnanimous)
    }

    @Test("единогласие не считается доказательством правоты")
    func unanimityIsNotProof() {
        // Все три могли расслышать одинаково неверно. Метод отвечает «где
        // точно плохо» и не притворяется, что отвечает «где хорошо».
        let reports = SpeechEval.termDisagreements(
            terms: ["Kubernetes"],
            across: ["кубернетес поднят", "кубернетес поднят", "кубернетес поднят"])
        let report = reports[0]
        #expect(report.found == 0)
        #expect(report.isUnanimous, "все промахнулись одинаково — согласие, а не успех")
    }

    @Test("термин ищется как слово, а не как подстрока")
    func termMatchIsWordLevel() {
        // «прод» не должен находиться внутри «продукт», иначе метрика начнёт
        // видеть согласие там, где сказаны разные слова.
        let reports = SpeechEval.termDisagreements(terms: ["прод"],
                                                   across: ["мы обсудили продукт"])
        #expect(reports[0].found == 0)
    }

    @Test("доля согласия считается по терминам, а не по расшифровкам")
    func agreementRate() {
        let rate = SpeechEval.termAgreementRate(
            terms: ["LLM", "прод", "релиз"],
            across: ["LLM прод релиз", "LLM прод релиз", "элэлэм прод релиз"])
        // Два термина из трёх единогласны.
        #expect(abs(rate - 2.0 / 3.0) < 0.001)
    }

    @Test("без расшифровок метрика молчит, а не выдумывает")
    func emptyInput() {
        #expect(SpeechEval.termDisagreements(terms: ["LLM"], across: []).isEmpty)
        #expect(SpeechEval.termAgreementRate(terms: [], across: ["текст"]) == 1)
    }

    /// Замер на настоящей русской речи — не проверка, а измерение.
    ///
    ///     CRUXWING_RU_CORPUS=/путь/к/data/russian \
    ///     swift test --filter probeRussianCorpus
    ///
    /// Эталона, размеченного человеком, у нас нет, поэтому WER здесь не
    /// считается: печатается расхождение движков между собой и список
    /// терминов, на которых они разошлись. Разногласие доказывает ошибку,
    /// единогласие ничего не доказывает — и вывод не должен притворяться,
    /// что доказывает.
    @Test("замер: расхождение движков на русском корпусе")
    func probeRussianCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["CRUXWING_RU_CORPUS"] else { return }
        let terms = ["LLM", "API", "промпт", "агент", "фильтр", "токен", "инъекция",
                     "прод", "MCP", "RAG", "модель", "модели", "пайплайн", "деплой",
                     "релиз", "бэкенд", "джейлбрейк"]
        let engines = ["whisper-large", "parakeet", "fireflies"]
        let stems = ["ru1-ai-security-w900", "ru1-ai-security-w2700", "ru1-ai-security-w4300"]

        var rates: [Double] = []
        var ratesAfter: [Double] = []
        for stem in stems {
            let texts = engines.compactMap {
                try? String(contentsOfFile: "\(dir)/\(stem).\($0).txt", encoding: .utf8)
            }
            guard texts.count == engines.count else { continue }

            let reports = SpeechEval.termDisagreements(terms: terms, across: texts)
            // Термин, которого нет ни у кого, ничего не говорит о движках:
            // возможно, его просто не произносили.
            let spoken = reports.filter { $0.found > 0 }
            let disputed = spoken.filter(\.isDisputed)
            guard !spoken.isEmpty else { continue }

            let agreement = Double(spoken.count - disputed.count) / Double(spoken.count)
            rates.append(agreement)
            print(String(format: "%@: терминов прозвучало %d, спорных %d, согласие %.0f%%",
                         stem, spoken.count, disputed.count, agreement * 100))
            for report in disputed.sorted(by: { $0.term < $1.term }) {
                print("    спорный «\(report.term)»: нашли \(report.found) из \(report.total)")
            }
            let drift = SpeechEval.wordErrorRate(reference: texts[0], hypothesis: texts[1])
            print(String(format: "    whisper vs parakeet: расходятся на %.0f%% слов (замен %d, пропусков %d, вставок %d)",
                         drift.rate * 100, drift.substitutions, drift.deletions, drift.insertions))

            // Тот же замер после словаря. Смысл всей затеи: если согласие не
            // выросло, словарь не решает измеренную задачу, и об этом надо
            // узнать здесь, а не после релиза.
            let repaired = texts.map { RussianLexicon.restore($0) }
            let afterReports = SpeechEval.termDisagreements(terms: terms, across: repaired)
            let afterSpoken = afterReports.filter { $0.found > 0 }
            let afterDisputed = afterSpoken.filter(\.isDisputed)
            if !afterSpoken.isEmpty {
                let after = Double(afterSpoken.count - afterDisputed.count) / Double(afterSpoken.count)
                ratesAfter.append(after)
                print(String(format: "    после словаря: спорных %d, согласие %.0f%% (было %.0f%%)",
                             afterDisputed.count, after * 100, agreement * 100))
                for report in afterDisputed.sorted(by: { $0.term < $1.term }) {
                    print("        всё ещё спорный «\(report.term)»: \(report.found) из \(report.total)")
                }
            }
        }

        guard !rates.isEmpty else { return }
        let mean = rates.reduce(0, +) / Double(rates.count)
        // Обе цифры, и обязательно рядом: одна «до» в отчёте выглядела бы как
        // результат работы словаря, хотя это результат его отсутствия.
        print(String(format: "среднее согласие по терминам: %.0f%% (сырые расшифровки)", mean * 100))
        if !ratesAfter.isEmpty {
            let meanAfter = ratesAfter.reduce(0, +) / Double(ratesAfter.count)
            print(String(format: "среднее согласие после словаря: %.0f%%", meanAfter * 100))
        }
        // Порога здесь нет намеренно: это замер, а не ворота. Порог появится
        // тогда, когда появится эталон и можно будет считать WER честно.
    }
}
