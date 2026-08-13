import Foundation
import Testing
@testable import OrakulCore

/// GitHub как источник контекста на звонке.
///
/// Форма запроса проверена на живом API 2026-08-12: без `is:issue` GitHub
/// отвечает 422 части токенов, а версия API фиксируется заголовком. Обе вещи
/// невозможно объяснить пользователю по тексту ошибки, поэтому они закреплены
/// здесь, а не в комментарии.
@Suite("GitHub")
struct GitHubConnectorTests {

    private static let issueJSON = """
    {"total_count": 1, "items": [
      {"number": 42, "title": "Поднять лимиты на выгрузку",
       "html_url": "https://github.com/myteam/backend/issues/42", "state": "open"}]}
    """

    private func stub(status: Int = 200, json: String = issueJSON)
        -> (GitHubConnector.HTTP, Recorder) {
        let recorder = Recorder()
        let http: GitHubConnector.HTTP = { request in
            recorder.record(request)
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (http, recorder)
    }

    private func client(repositories: [String] = ["myteam/backend"],
                        token: String = "ghp_synthetic",
                        http: @escaping GitHubConnector.HTTP) -> GitHubConnector {
        GitHubConnector(token: token, repositories: repositories, http: http)
    }

    @Test("в запрос всегда попадает тип, иначе GitHub отвечает 422")
    func queryAlwaysCarriesTheTypeQualifier() async throws {
        let (http, recorder) = stub()
        _ = try await client(http: http).search("лимиты")

        let url = try #require(recorder.last?.url?.absoluteString)
        // Двоеточие и слэш в строке запроса допустимы и не кодируются
        // (`.urlQueryAllowed`) — GitHub принимает их как есть; кодируются
        // только пробелы. Первая версия теста ждала `is%3Aissue` и ловила
        // собственное неверное представление, а не ошибку в коде.
        #expect(url.contains("is:issue"), "нет типа в запросе: \(url)")
        #expect(url.hasPrefix("https://api.github.com/search/issues?q="))
    }

    @Test("поиск ограничен указанными репозиториями")
    func searchIsScopedToTheRepositories() async throws {
        // Без ограничения поиск идёт по всему GitHub, и в подсказку попадают
        // чужие задачи — шум, неотличимый от контекста команды.
        let (http, recorder) = stub()
        _ = try await client(repositories: ["myteam/backend", "myteam/web"], http: http)
            .search("лимиты")

        let url = try #require(recorder.last?.url?.absoluteString)
        #expect(url.contains("repo:myteam/backend"))
        #expect(url.contains("repo:myteam/web"))
    }

    @Test("версия API и формат ответа заданы явно")
    func headersPinTheAPIVersion() async throws {
        let (http, recorder) = stub()
        _ = try await client(http: http).search("q")

        let request = try #require(recorder.last)
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_synthetic")
        #expect(request.timeoutInterval == 8)
    }

    @Test("без токена или без репозиториев запрос не уходит")
    func incompleteSetupNeverCallsOut() async {
        let (http, recorder) = stub()
        await #expect(throws: GitHubConnector.ConnectorError.notConfigured) {
            try await client(token: "", http: http).search("q")
        }
        await #expect(throws: GitHubConnector.ConnectorError.notConfigured) {
            try await client(repositories: [], http: http).search("q")
        }
        #expect(recorder.count == 0)
    }

    @Test("ключ задачи собирается так, чтобы её было видно без ссылки")
    func itemKeyNamesRepositoryAndNumber() async throws {
        // При нескольких репозиториях «#42» ничего не говорит.
        let (http, _) = stub()
        let items = try await client(http: http).search("лимиты")
        let item = try #require(items.first)
        #expect(item.key == "myteam/backend#42")
        #expect(item.title == "Поднять лимиты на выгрузку")
        #expect(item.state == "open")
        #expect(item.url?.absoluteString == "https://github.com/myteam/backend/issues/42")
    }

    @Test("состояние задачи сохраняется — закрытая меняет смысл находки")
    func closedStateSurvives() async throws {
        let json = """
        {"items": [{"number": 7, "title": "Уже сделано",
         "html_url": "https://github.com/myteam/backend/issues/7", "state": "closed"}]}
        """
        let (http, _) = stub(json: json)
        let items = try await client(http: http).search("q")
        #expect(items.first?.state == "closed")
    }

    @Test("запись без номера пропускается, остальные остаются")
    func partialRowsSurvive() async throws {
        let json = """
        {"items": [{"title": "нет номера"},
                   {"number": 7, "html_url": "https://github.com/myteam/backend/issues/7"}]}
        """
        let (http, _) = stub(json: json)
        let items = try await client(http: http).search("q")
        #expect(items.count == 1)
        #expect(items.first?.title == "Без названия")
    }

    @Test("ошибка от GitHub не выдаётся за пустую выдачу")
    func errorBodyIsNotAnEmptyResult() async {
        // `{"message": "..."}` без `items` — это невыполненный запрос. Пустой
        // список сказал бы «задач нет», и человек поверил бы.
        let (http, _) = stub(json: #"{"message": "Validation Failed"}"#)
        await #expect(throws: GitHubConnector.ConnectorError.unreadable) {
            try await client(http: http).search("q")
        }
    }

    @Test("401 и 403 читаются как неподходящий токен")
    func unauthorisedIsRecognised() async {
        for status in [401, 403] {
            let (http, _) = stub(status: status, json: "{}")
            await #expect(throws: GitHubConnector.ConnectorError.unauthorised) {
                try await client(http: http).search("q")
            }
        }
    }

    @Test("сказано, где взять токен и что писать в репозитории")
    func promptsExplainThemselves() {
        #expect(GitHubConnector.credentialHint.contains("Personal access tokens"))
        #expect(GitHubConnector.repositoriesPrompt.contains("/"))
    }
}

/// Запоминает запросы: замыкание `Sendable`, поэтому состояние под замком.
