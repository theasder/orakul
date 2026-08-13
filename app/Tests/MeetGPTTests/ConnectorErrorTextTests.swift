import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Что человек читает, когда коннектор отказал.
///
/// Swift без `LocalizedError` печатает «The operation couldn’t be completed.
/// (MeetGPT.WorkMessengers.ConnectorError error 1.)». В приложении, где всё
/// остальное по-русски, это выходит наружу ровно в тот момент, когда человеку
/// нужна помощь: не тот токен, недоступный сервер, не та очередь.
///
/// `RenderedRussianTests` этого не ловит: он смотрит на статичные строки
/// интерфейса, а такие сообщения рождаются во время работы.
@Suite("Сообщения об отказе коннекторов")
struct ConnectorErrorTextTests {

    /// Все ошибки, которые может увидеть человек.
    static let all: [Error] = [
        WorkMessengers.ConnectorError.notConfigured,
        WorkMessengers.ConnectorError.unauthorised,
        WorkMessengers.ConnectorError.unreadable,
        SelfHostedTrackers.ConnectorError.notConfigured,
        SelfHostedTrackers.ConnectorError.unauthorised,
        SelfHostedTrackers.ConnectorError.unreadable,
        TeamNotes.ConnectorError.notConfigured,
        TeamNotes.ConnectorError.unauthorised,
        TeamNotes.ConnectorError.unreadable,
        RussianTrackers.TrackerError.notConfigured(.yandexTracker),
        RussianTrackers.TrackerError.unauthorised(.kaiten),
        RussianTrackers.TrackerError.http(.yougile, 404),
        RussianTrackers.TrackerError.unreadable(.yandexTracker),
        GitHubConnector.ConnectorError.notConfigured,
        GitHubConnector.ConnectorError.unauthorised,
        GitHubConnector.ConnectorError.http(404),
        GitHubConnector.ConnectorError.unreadable,
    ]

    @Test("ни одна ошибка не показывает английскую заглушку и внутренности",
          arguments: all.map { $0.localizedDescription })
    func noBoilerplateLeaks(text: String) {
        for leak in ["operation couldn", "MeetGPT.", "error 0", "error 1",
                     "error 2", "error 3", "ConnectorError", "TrackerError"] {
            #expect(!text.contains(leak), "наружу вышли внутренности: «\(text)»")
        }
    }

    @Test("каждое сообщение по-русски и достаточно длинное, чтобы объяснить",
          arguments: all.map { $0.localizedDescription })
    func everyMessageIsRussian(text: String) {
        #expect(text.count >= 25, "слишком коротко: «\(text)»")
        let cyrillic = text.filter { ("а"..."я").contains($0) || ("А"..."Я").contains($0) }
        #expect(cyrillic.count > text.count / 3, "сообщение не по-русски: «\(text)»")
    }

    @Test("«не подключён» ведёт туда, где это чинится",
          arguments: [WorkMessengers.ConnectorError.notConfigured as Error,
                      SelfHostedTrackers.ConnectorError.notConfigured,
                      TeamNotes.ConnectorError.notConfigured,
                      RussianTrackers.TrackerError.notConfigured(.kaiten),
                      GitHubConnector.ConnectorError.notConfigured])
    func notConfiguredNamesTheScreen(error: Error) {
        #expect(error.localizedDescription.contains("Подключённые приложения"),
                "не сказано, где подключать: «\(error.localizedDescription)»")
    }

    @Test("ошибка трекера называет, какой именно трекер отказал")
    func trackerErrorsNameTheService() {
        // При трёх подключённых трекерах «не принял токен» без имени
        // бесполезно: непонятно, где менять.
        let text = RussianTrackers.TrackerError.unauthorised(.kaiten).localizedDescription
        #expect(text.contains(RussianTrackers.Service.kaiten.title),
                "в сообщении нет имени сервиса: «\(text)»")
    }

    @Test("код ответа доходит до человека")
    func httpStatusSurvives() {
        #expect(GitHubConnector.ConnectorError.http(404).localizedDescription.contains("404"))
        #expect(RussianTrackers.TrackerError.http(.yougile, 500).localizedDescription.contains("500"))
    }
}
