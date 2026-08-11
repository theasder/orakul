import Foundation
import Testing
@testable import OrakulCore

/// Копилка держит запись целого созвона в памяти. Ошибка здесь — это не
/// неверный ответ, а упавшее приложение вместе с несохранённой встречей,
/// поэтому проверяются границы, а не удачный путь.
@Suite("Копилка звука")
struct AudioAccumulatorTests {

    /// Синусоида: звук, который не выглядит тишиной.
    private func tone(seconds: Double, rate: Int = 16_000) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) / 12) * 0.3) }
    }

    @Test("сэмплы копятся, секунды считаются")
    func accumulates() {
        var buffer = AudioAccumulator()
        buffer.append(tone(seconds: 1))
        buffer.append(tone(seconds: 1))
        #expect(abs(buffer.seconds - 2) < 0.01)
        #expect(!buffer.isFull)
    }

    @Test("потолок обрезает запись, но не роняет программу")
    func limitTruncatesInsteadOfCrashing() {
        // Созвон, который забыли остановить, — это не редкость, а вторник.
        var buffer = AudioAccumulator(limitSeconds: 1)
        buffer.append(tone(seconds: 3))

        #expect(abs(buffer.seconds - 1) < 0.01, "запись должна остановиться на потолке")
        #expect(buffer.isFull)
        #expect(buffer.droppedSamples > 0, "потерянное обязано быть посчитано")
    }

    @Test("после потолка добавление ничего не ломает")
    func appendingAfterLimitIsSafe() {
        var buffer = AudioAccumulator(limitSeconds: 0.5)
        buffer.append(tone(seconds: 1))
        let after = buffer.seconds
        buffer.append(tone(seconds: 1))
        // Микрофон не знает про потолок и продолжает слать буферы.
        #expect(buffer.seconds == after)
        #expect(buffer.droppedSamples > 0)
    }

    @Test("тишина распознаётся до того, как её отдали движку")
    func silenceIsDetected() {
        // Выключенный микрофон даёт не нули, а очень тихий шум. Движок вернёт
        // пустую строку, и конвейер решит, что расшифровка не удалась, — хотя
        // на самом деле человек выбрал не то устройство.
        var quiet = AudioAccumulator()
        quiet.append((0..<32_000).map { _ in Float.random(in: -0.0002...0.0002) })
        #expect(quiet.looksSilent)
        #expect(!quiet.isWorthTranscribing)

        var loud = AudioAccumulator()
        loud.append(tone(seconds: 3))
        #expect(!loud.looksSilent)
        #expect(loud.isWorthTranscribing)
    }

    @Test("уровень считается по всей записи, а не по самому громкому месту")
    func levelIsAveraged() {
        // Среднеквадратичное, а не максимум: одиночный хлопок дверью не должен
        // выглядеть как трёхчасовая планёрка.
        //
        // Порог при этом намеренно низкий (0.001). Один щелчок даёт около
        // 0.0056 и порог переживает — то есть такая запись всё-таки уедет
        // движку и вернётся с «не смог расшифровать». Это осознанный размен:
        // поднять порог значит начать отбраковывать тихую речь, а отказаться
        // расшифровывать настоящий созвон куда хуже, чем впустую сходить к
        // движку из-за хлопка.
        var click = AudioAccumulator()
        var samples = [Float](repeating: 0, count: 32_000)
        samples[100] = 1
        click.append(samples)

        var speech = AudioAccumulator()
        speech.append(tone(seconds: 2))

        // Главное свойство: щелчок на два порядка тише разговора.
        #expect(!click.looksSilent, "0.0056 выше порога — и это задокументировано выше")
        let clickLevel = level(of: click)
        let speechLevel = level(of: speech)
        #expect(speechLevel > clickLevel * 10, "максимум вместо среднего сравнял бы их")
    }

    private func level(of buffer: AudioAccumulator) -> Double {
        let squares = buffer.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (squares / Double(max(1, buffer.samples.count))).squareRoot()
    }

    @Test("слишком короткая запись не отправляется движку")
    func tooShortIsRejected() {
        // Случайное нажатие «записать» и сразу «стоп».
        var buffer = AudioAccumulator()
        buffer.append(tone(seconds: 0.5))
        #expect(!buffer.isWorthTranscribing)
        #expect(!buffer.looksSilent, "звук там есть — дело в длине, и причины разные")
    }

    @Test("пустая копилка — это тишина, а не ошибка")
    func emptyIsSilent() {
        let buffer = AudioAccumulator()
        #expect(buffer.seconds == 0)
        #expect(buffer.looksSilent)
        #expect(!buffer.isWorthTranscribing)
    }

    @Test("сброс возвращает копилку в исходное состояние")
    func resetClearsEverything() {
        var buffer = AudioAccumulator(limitSeconds: 0.5)
        buffer.append(tone(seconds: 2))
        buffer.reset()
        #expect(buffer.seconds == 0)
        #expect(buffer.droppedSamples == 0, "счётчик потерь тоже обнуляется")
        #expect(!buffer.isFull)
    }

    @Test("записанное можно сразу закодировать в WAV")
    func feedsTheEncoder() {
        // Ради этого всё и делалось: копилка отдаёт ровно то, что ждёт WAVFile.
        var buffer = AudioAccumulator()
        buffer.append(tone(seconds: 0.1))
        let wav = WAVFile.encode(samples: buffer.samples)
        #expect(wav.count == 44 + buffer.samples.count * 2)
    }
}
