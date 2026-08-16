import Foundation
import Testing
@testable import MeetGPT

@Suite("Cross-track echo, character level")
struct TranscriptCharacterRecoveryTests {
    private func entry(_ text: String, _ source: TranscriptSource,
                       at seconds: TimeInterval) -> TranscriptEntry {
        TranscriptEntry(
            source: source,
            text: text,
            timestamp: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @Test("garbled full-line echo is dropped despite weak token overlap")
    func fullLineEcho() {
        let system = entry(
            "Завимодействие этого куска со стальными кускаем, получается архитектурный не очень.",
            .system, at: 100)
        let mic = entry(
            "А если вы опускали остальными пусками, получается архитектурный не очень.",
            .mic, at: 101)
        #expect(TranscriptDeduplicator.isDuplicate(mic, of: [system]))
    }

    @Test("one-word and fused-word echo fragments are dropped")
    func fragments() {
        let tailHost = entry(
            "потому что часть проблем не вылезнет.", .system, at: 200)
        #expect(TranscriptDeduplicator.isDuplicate(
            entry("вылизет.", .mic, at: 201), of: [tailHost]))

        let fusedHost = entry(
            "но взаимодействие этого куска со остальными кусками получается не очень",
            .system, at: 300)
        #expect(TranscriptDeduplicator.isDuplicate(
            entry("состальянного.", .mic, at: 301), of: [fusedHost]))
    }

    @Test("genuine short replies survive")
    func genuineReplies() {
        let question = entry(
            "Понимаешь, о чем речь, или надо глубже раскрыть?",
            .system, at: 400)
        #expect(!TranscriptDeduplicator.isDuplicate(
            entry("Можешь раскрыть.", .mic, at: 402), of: [question]))
        #expect(!TranscriptDeduplicator.isDuplicate(
            entry("Раскрыть? Да, давай попробуем сначала", .mic, at: 402),
            of: [question]))
    }

    @Test("tiny acknowledgements never match inside longer words")
    func tinyAcknowledgement() {
        let system = entry(
            "когда у тебя два одинаковых модуля отвечают за одну функцию",
            .system, at: 500)
        #expect(!TranscriptDeduplicator.isDuplicate(
            entry("Да.", .mic, at: 501), of: [system]))
    }

    @Test("character matching remains cross-track only")
    func sameTrackUnaffected() {
        let first = entry(
            "Завимодействие этого куска со стальными кускаем, получается архитектурный не очень.",
            .system, at: 600)
        let second = entry(
            "А если вы опускали остальными пусками, получается архитектурный не очень.",
            .system, at: 615)
        #expect(!TranscriptDeduplicator.isDuplicate(second, of: [first]))
    }

    @Test("transliteration bridges Cyrillic and Latin drift")
    func transliteration() {
        let first = TranscriptDeduplicator.normalizedCharacters(
            "в моду левеба и в моду левагента")
        let second = TranscriptDeduplicator.normalizedCharacters(
            "O modo leveb, e o modo agente")
        #expect(TranscriptDeduplicator.characterSimilarity(first, second) > 0.5)
        #expect(TranscriptDeduplicator.characterSimilarity(first, first) == 1)
        #expect(TranscriptDeduplicator.characterSimilarity(first, "") == 0)
    }
}

@Suite("Measured decoder-noise gates")
struct TranscriptNoiseRecoveryTests {
    private func entry(_ text: String, _ source: TranscriptSource = .mic,
                       at seconds: TimeInterval = 0) -> TranscriptEntry {
        TranscriptEntry(
            source: source,
            text: text,
            timestamp: Date(timeIntervalSinceReferenceDate: seconds))
    }

    @Test("bare filler is noise while real one-word replies survive")
    func fillerSingletons() {
        for noise in ["и", "в", "The", "So", "ну", "а"] {
            #expect(TranscriptDeduplicator.isNoiseArtifact(
                entry(noise), glossary: []), "\(noise)")
        }
        for reply in ["Да", "Нет", "Ага", "Окей", "Почему?"] {
            #expect(!TranscriptDeduplicator.isNoiseArtifact(
                entry(reply), glossary: []), "\(reply)")
        }
    }

    @Test("glossary-only hallucinations are rejected")
    func glossaryOnly() {
        let glossary = ["Orakul", "Proglib"]
        #expect(TranscriptDeduplicator.isNoiseArtifact(
            entry("Orakul."), glossary: glossary))
        #expect(TranscriptDeduplicator.isNoiseArtifact(
            entry("Orakul, Proglib"), glossary: glossary))
        #expect(!TranscriptDeduplicator.isNoiseArtifact(
            entry("Мы показали Orakul инвесторам"), glossary: glossary))
        #expect(!TranscriptDeduplicator.isNoiseArtifact(
            entry("Orakul."), glossary: []))
    }

    @Test("same-track garbled tail is rejected only near its host")
    func sameTrackTail() {
        let host = entry(
            "Давай посмотрим на общие цифры продаж", .system, at: 0)
        #expect(TranscriptDeduplicator.isDuplicate(
            entry("шие цифры продаш.", .system, at: 5), of: [host]))
        #expect(!TranscriptDeduplicator.isDuplicate(
            entry("Хорошие цифры!", .system, at: 5), of: [host]))
        #expect(!TranscriptDeduplicator.isDuplicate(
            entry("шие цифры продаш.", .system, at: 30), of: [host]))
    }
}
