import Foundation

/// Копилка сэмплов на время записи созвона.
///
/// Выглядит как массив с добавлением, но решает два вопроса, на которых
/// ломается наивная реализация:
///
/// **Память.** Час записи в 16 кГц Float — это около 230 МБ, три часа — почти
/// 700 МБ. Планёрка, которую забыли остановить, съест память и утащит с собой
/// всё несохранённое. Поэтому у копилки есть жёсткий потолок, и по достижении
/// она перестаёт расти, а не падает: обрезанная запись лучше, чем упавшее
/// приложение с потерянным созвоном.
///
/// **Тишина.** Пустой звук нельзя отдавать движку: тот вернёт пустую строку,
/// которую конвейер справедливо примет за «расшифровать не удалось». Отличить
/// «никто не говорил» от «выбран не тот микрофон» можно только здесь, по уровню
/// сигнала, и сказать об этом надо до расшифровки, а не после.
public struct AudioAccumulator: Sendable {

    /// Потолок по умолчанию — четыре часа. Дольше не длится ни один созвон,
    /// который потом кто-то станет читать.
    public static let defaultLimitSeconds: Double = 4 * 60 * 60

    public let sampleRate: Int
    public let limitSeconds: Double

    public private(set) var samples: [Float] = []
    /// Сколько сэмплов не поместилось. Ноль — норма; больше нуля обязано
    /// дойти до человека, потому что запись оборвана.
    public private(set) var droppedSamples = 0

    public init(sampleRate: Int = WAVFile.sampleRate,
                limitSeconds: Double = AudioAccumulator.defaultLimitSeconds) {
        self.sampleRate = sampleRate
        self.limitSeconds = limitSeconds
    }

    public var seconds: Double { Double(samples.count) / Double(sampleRate) }
    public var isFull: Bool { droppedSamples > 0 }

    private var capacity: Int { Int(limitSeconds * Double(sampleRate)) }

    public mutating func append(_ incoming: [Float]) {
        let room = capacity - samples.count
        guard room > 0 else {
            droppedSamples += incoming.count
            return
        }
        if incoming.count <= room {
            samples.append(contentsOf: incoming)
        } else {
            samples.append(contentsOf: incoming.prefix(room))
            droppedSamples += incoming.count - room
        }
    }

    /// Похоже ли это на тишину.
    ///
    /// Порог, а не «строго ноль»: микрофон всегда шумит, и запись выключенного
    /// микрофона — это не нули, а очень тихий шум. Считаем среднеквадратичное,
    /// потому что один щелчок не делает созвон записанным.
    public var looksSilent: Bool {
        guard !samples.isEmpty else { return true }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        return rms < 0.001
    }

    /// Достаточно ли записано, чтобы вообще звать движок.
    ///
    /// Короче двух секунд — это случайное нажатие, а не созвон.
    public var isWorthTranscribing: Bool { seconds >= 2 && !looksSilent }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        droppedSamples = 0
    }
}
