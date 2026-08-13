import Foundation
import Testing
@testable import OrakulCore

/// Отметки времени из расшифровки.
///
/// Найдено запуском собранной команды с движком, который печатает ровно то,
/// что печатает whisper.cpp: отметка стоит В ОДНОЙ строке с текстом. Такую
/// строку выдержка режет по знакам препинания вместе с отметкой, и цитата
/// приходила в виде «[00: 320]   Аня: По тарифам — что решили в итоге».
///
/// Цитата — это и есть продукт: страница обещает слова из вашего звонка, а не
/// обломок таймкода перед ними. И команда в README (`whisper-cli … -otxt`)
/// приводит ровно к этому случаю, то есть страдал бы каждый, кто ей следует.
///
/// Отдельные строки с отметками (SRT, VTT) в выдержку не попадали и выглядели
/// целыми, но в поисковый указатель шли — лишние числа среди слов.
@Suite("Отметки времени в расшифровке")
struct TranscriptCleanupTests {

    @Test("отметка whisper.cpp в начале строки уходит, текст остаётся")
    func inlineWhisperStampIsRemoved() {
        let raw = """
        [00:00:00.000 --> 00:00:04.320]   Аня: По тарифам — что решили в итоге?
        [00:00:04.320 --> 00:00:09.100]   Борис: Годовой не трогаем до декабря.
        """
        let clean = TranscriptCleanup.strip(raw)

        #expect(!clean.contains("00:00:04.320"), "отметка осталась: «\(clean)»")
        #expect(!clean.contains("-->"), "стрелка осталась: «\(clean)»")
        #expect(clean.contains("Аня: По тарифам — что решили в итоге?"),
                "текст пострадал: «\(clean)»")
        #expect(clean.contains("Борис: Годовой не трогаем до декабря."))
    }

    @Test("одиночная отметка в квадратных скобках тоже уходит")
    func singleBracketStampIsRemoved() {
        // Второй распространённый формат вывода: одна отметка, без стрелки.
        let clean = TranscriptCleanup.strip("[00:12:03.500]   Аня: Кто выкатывает?")
        #expect(clean == "Аня: Кто выкатывает?", "получилось «\(clean)»")
    }

    @Test("строки SRT и VTT не засоряют указатель")
    func standaloneStampLinesGo() {
        let raw = """
        WEBVTT

        1
        00:00:00,000 --> 00:00:04,320
        Аня: По тарифам — что решили?
        """
        let clean = TranscriptCleanup.strip(raw)

        #expect(!clean.contains("00:00:00,000"), "отметка SRT осталась: «\(clean)»")
        #expect(!clean.contains("WEBVTT"), "заголовок VTT остался: «\(clean)»")
        #expect(clean.contains("Аня: По тарифам — что решили?"))
        // Порядковый номер реплики — тоже мусор, но только когда он один на
        // строке: число внутри фразы трогать нельзя (см. проверку ниже).
        #expect(!clean.split(separator: "\n").contains("1"), "номер реплики остался")
    }

    @Test("время внутри фразы остаётся — о нём и говорили")
    func timeInsideASentenceSurvives() {
        // Граница. «Созвон в 10:30» — это содержание встречи, и вычистить его
        // значило бы испортить поиск ровно по тому, что человек ищет.
        let raw = "Аня: Давайте перенесём на 10:30, а релиз в 18:00."
        #expect(TranscriptCleanup.strip(raw) == raw, "вычистили осмысленное время")
    }

    @Test("отметка в середине фразы остаётся — это цитата из лога")
    func stampInsideASentenceSurvives() {
        // Пробел в проверках, найденный мутацией: без якоря `^` правило
        // срабатывало бы и здесь. А это продукт для разработчиков — они
        // диктуют друг другу строки лога прямо на звонке, и «посмотри
        // [00:00:04.320] там ошибка» без отметки теряет ровно то, о чём речь.
        let raw = "Аня: смотри лог [00:00:04.320] там ошибка соединения."
        #expect(TranscriptCleanup.strip(raw) == raw,
                "вычистили отметку из середины фразы: «\(TranscriptCleanup.strip(raw))»")
    }

    @Test("числа и обычный текст не трогаем")
    func ordinaryTextIsUntouched() {
        for line in ["Борис: Поднимаем на 15 процентов.",
                     "Аня: Версия 2.0.1 уходит в пятницу.",
                     "Борис: Задача TRACK-42 закрыта."] {
            #expect(TranscriptCleanup.strip(line) == line, "испортили строку: «\(line)»")
        }
    }

    @Test("расшифровка без отметок не меняется вовсе")
    func plainTranscriptIsIdentical() {
        let raw = """
        Аня: По тарифам — что решили в итоге?
        Борис: Годовой не трогаем до декабря.
        """
        #expect(TranscriptCleanup.strip(raw) == raw)
    }

    @Test("обе двери в архив чистят одинаково")
    func bothEntryPointsClean() throws {
        // Смысл общей чистки в том, что она стоит на обоих путях: расшифровка
        // движком и готовый файл. Значение по умолчанию тут невозможно, но
        // забыть один вызов — вполне, и тогда половина архива снова с мусором.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for (file, door) in [("Sources/OrakulCore/CommandLineApp.swift", "orakul добавить"),
                             ("Sources/OrakulCore/MeetingPipeline.swift", "orakul расшифровать")] {
            let source = try String(contentsOf: root.appendingPathComponent(file),
                                    encoding: .utf8)
            #expect(source.contains("TranscriptCleanup.strip"),
                    "«\(door)» кладёт в архив неочищенный текст")
        }
    }
}
