import Foundation

/// Кнопки быстрых действий и правила, по которым они показываются.
///
/// Каталог лежит в JSON, а не в коде, потому что его правит тот, кто пишет
/// тексты, а не тот, кто собирает приложение. Здесь — разбор и те решения,
/// которые нельзя оставлять на усмотрение интерфейса: что бесплатно, что
/// работает без сети и что показывать, когда сети нет.
public struct PromptCatalog: Codable, Sendable {

    /// Уровень подписки. Порядок важен: `free < team < company`.
    public enum Tier: String, Codable, Comparable, Sendable, CaseIterable {
        case free
        case team
        case company

        private var rank: Int {
            switch self {
            case .free: return 0
            case .team: return 1
            case .company: return 2
            }
        }

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rank < rhs.rank }
    }

    public struct Button: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let prompt: String
        public let tier: Tier
        /// Работает ли кнопка целиком на устройстве.
        public let offline: Bool
        /// Почему формулировка именно такая. Пользователю не показывается —
        /// это защита от «причёсывания» текстов при следующем переводе.
        public let adapted: String
    }

    public let version: Int
    public let locale: String
    public let buttons: [Button]

    // MARK: - Загрузка

    public enum LoadError: Error, Equatable {
        case resourceMissing
        case duplicateIdentifier(String)
        /// Бесплатная кнопка, которой нужна сеть, ломает сразу два обещания:
        /// «работает без сети» и «звук не покидает компьютер».
        case freeButtonRequiresNetwork(String)
    }

    /// Каталог из строки JSON. Отдельно от загрузки из бандла, чтобы правила
    /// можно было проверять без файловой системы.
    public static func decode(_ data: Data) throws -> PromptCatalog {
        let catalog = try JSONDecoder().decode(PromptCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    /// Каталог, вшитый в приложение.
    ///
    /// Две функции, а не значение по умолчанию: `Bundle.module` генерируется
    /// SwiftPM как internal, и в значении по умолчанию публичного метода на
    /// него сослаться нельзя.
    public static func bundled() throws -> PromptCatalog {
        try bundled(in: .module)
    }

    static func bundled(in bundle: Bundle) throws -> PromptCatalog {
        guard let url = bundle.url(forResource: "prompts.ru", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        return try decode(try Data(contentsOf: url))
    }

    /// Правила, которые должны падать при сборке, а не у пользователя.
    public func validate() throws {
        var seen = Set<String>()
        for button in buttons {
            guard seen.insert(button.id).inserted else {
                throw LoadError.duplicateIdentifier(button.id)
            }
            if button.tier == .free && !button.offline {
                throw LoadError.freeButtonRequiresNetwork(button.id)
            }
        }
    }

    // MARK: - Что показывать

    /// Кнопки, доступные на этом уровне подписки.
    public func available(for tier: Tier) -> [Button] {
        buttons.filter { $0.tier <= tier }
    }

    /// Кнопки, которые можно нажать прямо сейчас.
    ///
    /// Без сети остаются только те, что считаются на устройстве, — и это не
    /// деградация, а бесплатный уровень в чистом виде.
    public func actionable(for tier: Tier, online: Bool) -> [Button] {
        available(for: tier).filter { online || $0.offline }
    }

    /// Почему кнопка недоступна — текстом, который можно показать человеку.
    ///
    /// Кнопка не исчезает: пропавшая кнопка читается как поломка, а не как
    /// ограничение, и пользователь идёт искать её вместо того, чтобы понять,
    /// что происходит.
    public func unavailabilityReason(for button: Button,
                                     tier: Tier,
                                     online: Bool) -> String? {
        if button.tier > tier {
            return "Доступно на уровне «\(button.tier.displayName)»"
        }
        if !online && !button.offline {
            return "Нужна сеть: эта кнопка обращается к внешнему сервису"
        }
        return nil
    }

    /// Главная кнопка продукта. Обращение по имени, а не по индексу: порядок в
    /// каталоге меняют текстовики, и он не должен ничего ломать.
    public var recall: Button? {
        buttons.first { $0.id == "what-decided" }
    }
}

public extension PromptCatalog.Tier {
    var displayName: String {
        switch self {
        case .free: return "Открытый"
        case .team: return "Команда"
        case .company: return "Компания"
        }
    }
}
