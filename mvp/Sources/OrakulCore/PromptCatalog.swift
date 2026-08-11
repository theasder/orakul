import Foundation

/// Кнопки быстрых действий и правила, по которым они показываются.
///
/// Каталог лежит в JSON, а не в коде, потому что его правит тот, кто пишет
/// тексты, а не тот, кто собирает приложение. Здесь — разбор и те решения,
/// которые нельзя оставлять на усмотрение интерфейса: что бесплатно, что
/// работает без сети и что показывать, когда сети нет.
public struct PromptCatalog: Codable, Sendable {

    public struct Button: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let prompt: String
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
        /// Кнопка, которой нужна сеть, ломает обещание продукта: всё работает
        /// на устройстве. Платных уровней нет, оправдания «это в подписке» —
        /// тоже, поэтому такая кнопка просто не грузится.
        case buttonRequiresNetwork(String)
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
            if !button.offline {
                throw LoadError.buttonRequiresNetwork(button.id)
            }
        }
    }

    // MARK: - Что показывать

    /// Кнопки, которые можно нажать прямо сейчас.
    ///
    /// Раньше здесь были уровни подписки. Их больше нет: продукт бесплатный
    /// целиком, поэтому единственная причина, по которой кнопка может быть
    /// недоступна, — техническая, а не коммерческая. Сейчас таких причин тоже
    /// нет, и метод возвращает всё: честный список из одной строки лучше, чем
    /// механизм разграничения, которому нечего разграничивать.
    public var actionable: [Button] { buttons }

    /// Главная кнопка продукта. Обращение по имени, а не по индексу: порядок в
    /// каталоге меняют текстовики, и он не должен ничего ломать.
    public var recall: Button? {
        buttons.first { $0.id == "what-decided" }
    }
}
