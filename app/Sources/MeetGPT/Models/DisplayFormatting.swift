import Foundation

/// Язык дат и времени в том, что видит человек.
///
/// В приложении 39 форматтеров, и локаль задавали восемь. Часть из них ставила
/// `en_US_POSIX` — правильный выбор для машинных форматов и неправильный для
/// текста: экспортированный транскрипт получал заголовок «Wednesday, 12 August
/// 2026 at 14:30» внутри русского документа, а шапка звонка показывала
/// «Wednesday, Aug 12 · 1:16 AM» — двенадцатичасовые часы с AM/PM, которых в
/// русском нет.
///
/// Локаль фиксирована, а не берётся системная. orakul говорит по-русски целиком
/// и без переключателя языка; у российского разработчика macOS часто английская,
/// и тогда системная локаль дала бы русский интерфейс с английскими датами.
enum DisplayFormatting {

    /// Для всего, что читает человек.
    static let locale = Locale(identifier: "ru_RU")

    /// Для машинных форматов — разбор ISO, отметки UTC. Их локаль менять нельзя:
    /// `en_US_POSIX` тем и хорош, что не зависит от настроек системы.
    static let machineLocale = Locale(identifier: "en_US_POSIX")

    /// Готовый форматтер для показа: локаль уже проставлена.
    static func displayFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }

    /// Русский счёт: 1 термин, 2 термина, 5 терминов.
    ///
    /// В настройках стояло `term\(count == 1 ? "" : "s")` — английское «-s» на
    /// русском числе. Правило одно на весь язык, поэтому лежит рядом с локалью,
    /// а не в том экране, где понадобилось первым.
    static func termsWord(_ count: Int) -> String {
        let hundred = abs(count) % 100
        if (11...14).contains(hundred) { return "терминов" }
        switch abs(count) % 10 {
        case 1:       return "термин"
        case 2, 3, 4: return "термина"
        default:      return "терминов"
        }
    }
}
