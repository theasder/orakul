import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Проверка коннектора на живом сервисе — вашим токеном.
///
/// **Зачем это есть.** Остальные проверки коннекторов подставляют своё
/// замыкание HTTP и в сеть не ходят: тест, который стучится в чужой сервис,
/// проверяет чужой сервис, а не наш код. Это правильно — и это же оставляет
/// дыру. Форма запроса взята из документации вендора, а документация врёт и
/// устаревает. Единственный способ узнать, что коннектор действительно
/// работает, — сходить в настоящий сервис.
///
/// Поэтому здесь тот же код, что и в приложении: `WorkMessengers.live`,
/// `SelfHostedTrackers.live`, `TeamNotes.live`. Второй реализации нет — иначе
/// она разъехалась бы с первой, и проверка проверяла бы саму себя.
///
/// **По умолчанию не запускается** — ни в обычном прогоне, ни в CI: без
/// переменных окружения набор пропускается. Токен нужен ваш, никуда не
/// пишется и не печатается.
///
///     ORAKUL_PROBE_SERVICE=mattermost \
///     ORAKUL_PROBE_TOKEN=… \
///     ORAKUL_PROBE_HOST=chat.company.ru \
///     ORAKUL_PROBE_SCOPE=team-id \
///     ORAKUL_PROBE_QUERY=тарифы \
///     swift test --filter LiveConnectorProbe
///
/// `SERVICE` — одно из: pachca, mattermost, rocketChat, zulip, matrix,
/// gitlab, gitea, redmine, outline.
@Suite("Живая проверка коннектора")
struct LiveConnectorProbeTests {

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var isEnabled: Bool { environment["ORAKUL_PROBE_SERVICE"] != nil }

    private var service: String { Self.environment["ORAKUL_PROBE_SERVICE"] ?? "" }
    private var token: String { Self.environment["ORAKUL_PROBE_TOKEN"] ?? "" }
    private var host: String? { Self.environment["ORAKUL_PROBE_HOST"] }
    private var scope: String? { Self.environment["ORAKUL_PROBE_SCOPE"] }
    private var query: String { Self.environment["ORAKUL_PROBE_QUERY"] ?? "тест" }

    @Test("коннектор отвечает на живом сервисе",
          .enabled(if: LiveConnectorProbeTests.isEnabled),
          .timeLimit(.minutes(1)))
    func probe() async throws {
        try #require(!token.isEmpty, "ORAKUL_PROBE_TOKEN пуст — проверять нечем")

        // Печатается ЧТО нашлось, а не токен: вывод теста легко попадает в
        // issue, и секрету там не место.
        if let messenger = WorkMessengers.Service(rawValue: service) {
            let hits = try await WorkMessengers(service: messenger, token: token,
                                                secondary: host, scope: scope,
                                                http: WorkMessengers.live).search(query)
            print("[\(messenger.title)] найдено сообщений: \(hits.count)")
            for hit in hits.prefix(3) { print("  — \(hit.text.prefix(120))") }
            // Пустая выдача — не провал: слова могло и не быть. Провал это
            // брошенная ошибка, и она поднялась бы выше сама.
            return
        }

        if let tracker = SelfHostedTrackers.Service(rawValue: service) {
            let items = try await SelfHostedTrackers(service: tracker, token: token,
                                                     host: host,
                                                     http: SelfHostedTrackers.live).search(query)
            print("[\(tracker.title)] найдено задач: \(items.count)")
            for item in items.prefix(3) {
                print("  — \(item.key) [\(item.state)] \(item.title.prefix(100))")
            }
            return
        }

        if let notes = TeamNotes.Service(rawValue: service) {
            let hits = try await TeamNotes(service: notes, token: token, host: host,
                                           http: TeamNotes.live).search(query)
            print("[\(notes.title)] найдено документов: \(hits.count)")
            for hit in hits.prefix(3) {
                print("  — \(hit.title): \(hit.context.prefix(100))")
            }
            return
        }

        let messengers: [String] = WorkMessengers.Service.allCases.map(\.rawValue)
        let trackers: [String] = SelfHostedTrackers.Service.allCases.map(\.rawValue)
        let wikis: [String] = TeamNotes.Service.allCases.map(\.rawValue)
        let known = (messengers + trackers + wikis).joined(separator: ", ")
        Issue.record("неизвестный сервис «\(service)». Доступны: \(known)")
    }

    /// Имена сервисов в подсказке выше должны существовать.
    ///
    /// Проверка дешёвая и токена не требует — в отличие от самой пробы. Список
    /// в документации к набору написан руками и без этого тихо устареет от
    /// первого же переименования или нового коннектора.
    @Test("документация набора называет существующие сервисы")
    func documentedServicesExist() {
        let documented: Set<String> = ["pachca", "mattermost", "rocketChat", "zulip",
                                       "matrix", "gitlab", "gitea", "redmine", "outline"]
        let real = Set(WorkMessengers.Service.allCases.map(\.rawValue))
            .union(SelfHostedTrackers.Service.allCases.map(\.rawValue))
            .union(TeamNotes.Service.allCases.map(\.rawValue))

        let onlyDocumented = documented.subtracting(real).sorted()
        let onlyInCode = real.subtracting(documented).sorted()
        #expect(documented == real,
                "подсказка и коннекторы разошлись: только в подсказке \(onlyDocumented), только в коде \(onlyInCode)")
    }
}
