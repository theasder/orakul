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

    /// Порог тишины, откалиброванный замером, а не рассуждением.
    ///
    /// Сначала здесь стояло 0.001 — число, взятое из головы. Запись с реального
    /// микрофона показала фоновый шум тихой комнаты **RMS 0.00114**: то есть
    /// порог проходил обычный фон, и «тишина» ловилась только на полностью
    /// мёртвом канале. Один и тот же кабинет в соседние минуты давал то
    /// «тишину», то «есть звук».
    ///
    /// 0.005 — примерно вчетверо выше измеренного фона и заметно ниже речи
    /// (обычно 0.02…0.2). Замер один и с одной машины, поэтому порог намеренно
    /// ближе к фону, чем к речи: пропустить тихий созвон к движку дешевле, чем
    /// отказаться расшифровывать настоящий.
    public static let silenceThreshold = 0.005

    /// Средний уровень записи. Наружу — чтобы человеку можно было показать
    /// число, а не только вердикт.
    public var level: Double {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumOfSquares / Double(samples.count)).squareRoot()
    }

    /// Похоже ли это на тишину.
    ///
    /// Среднеквадратичное, а не максимум: один щелчок не делает созвон
    /// записанным.
    public var looksSilent: Bool { level < Self.silenceThreshold }

    /// Достаточно ли записано, чтобы вообще звать движок.
    ///
    /// Короче двух секунд — это случайное нажатие, а не созвон.
    public var isWorthTranscribing: Bool { seconds >= 2 && !looksSilent }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        droppedSamples = 0
    }
}
