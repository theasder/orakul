import Foundation
import Testing
@testable import OrakulCore

/// Поиск по базе знаний.
///
/// Раздел заметок в `RESEARCH-AND-PLAN` §2.1 был закрыт как невозможный — и это
/// по-прежнему верно для российских облаков: у Яндекс Вики нет поиска по
/// тексту, у Teamly нет публичного API. Но открытые вики, которые команда
/// поднимает у себя, поиск отдают, и здесь закреплена его форма.
@Suite("База знаний")
struct TeamNotesTests {

    private func stub(status: Int = 200, json: String) -> (TeamNotes.HTTP, Recorder) {
        let recorder = Recorder()
        let http: TeamNotes.HTTP = { request in
            recorder.record(request)
            return (Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
        return (http, recorder)
    }

    private static let outlineJSON = """
    {"data": [{"context": "…решили поднять месячный на пятнадцать процентов…",
               "document": {"id": "d1", "title": "Тарифы 2026"}}]}
    """

    @Test("Outline ищет POST-ом и берёт токен в Bearer")
    func outlineSearch() async throws {
        let (http, recorder) = stub(json: Self.outlineJSON)
        let hits = try await TeamNotes(service: .outline, token: "tok-synthetic",
                                       host: "wiki.company.ru", http: http).search("тарифы")

        let request = try #require(recorder.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://wiki.company.ru/api/documents.search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-synthetic")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == "тарифы")

        // В подсказку идут слова вокруг совпадения, а не ссылка: ссылку на
        // звонке никто не откроет.
        #expect(hits.first?.title == "Тарифы 2026")
        #expect(hits.first?.context.contains("пятнадцать процентов") == true)
    }

    @Test("без адреса используется облако сервиса, а не ошибка")
    func emptyHostMeansCloud() async throws {
        // Отличие от GitLab и Gitea: там адрес обязателен, здесь нет. Outline
        // бывает облачным, и требовать адрес значило бы не пустить половину.
        let (http, recorder) = stub(json: Self.outlineJSON)
        _ = try await TeamNotes(service: .outline, token: "tok",
                                host: nil, http: http).search("q")
        #expect(recorder.last?.url?.absoluteString
                == "https://app.getoutline.com/api/documents.search")
    }

    @Test("без токена запрос не уходит")
    func tokenIsRequired() async {
        let (http, recorder) = stub(json: "{}")
        await #expect(throws: TeamNotes.ConnectorError.notConfigured) {
            try await TeamNotes(service: .outline, token: "  ",
                                host: "wiki.company.ru", http: http).search("q")
        }
        #expect(recorder.count == 0)
    }

    @Test("401 и 403 читаются как неподходящий токен")
    func unauthorisedIsRecognised() async {
        for status in [401, 403] {
            let (http, _) = stub(status: status, json: "{}")
            await #expect(throws: TeamNotes.ConnectorError.unauthorised) {
                try await TeamNotes(service: .outline, token: "t",
                                    host: nil, http: http).search("q")
            }
        }
    }

    @Test("ошибка сервиса не выдаётся за пустую выдачу")
    func errorBodyIsNotAnEmptyResult() async {
        // Пустой список сказал бы «не описывали», и человек бы поверил.
        let (http, _) = stub(json: #"{"error": "authentication_required"}"#)
        await #expect(throws: TeamNotes.ConnectorError.unreadable) {
            try await TeamNotes(service: .outline, token: "t", host: nil, http: http).search("q")
        }
    }

    @Test("пустой запрос никуда не уходит")
    func blankQueryIsNotSent() async throws {
        let (http, recorder) = stub(json: Self.outlineJSON)
        let hits = try await TeamNotes(service: .outline, token: "t",
                                       host: nil, http: http).search("   ")
        #expect(hits.isEmpty)
        #expect(recorder.count == 0)
    }
    @Test("подсказка написана по-русски")
    func promptIsRussian() {
        for service in TeamNotes.Service.allCases {
            #expect(service.credentialHint.range(
                of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) != nil)
        }
    }

    /// Тексты отказов не были покрыты ничем — и в них жила ошибка, которую
    /// видел каждый, кто подключал заметки: «База знаний не подключён»,
    /// «не принял токен», «ответил ошибкой». Название женского рода, глаголы
    /// мужского. У остальных коннекторов подлежащее мужского рода («Трекер»,
    /// «Мессенджер», «GitHub»), поэтому там та же заготовка читается верно —
    /// отсюда и ошибка при переносе.
    @Test("отказ написан по-русски и согласован с «базой знаний»")
    func errorsAgreeInGender() throws {
        let cases: [(TeamNotes.ConnectorError, String)] = [
            (.notConfigured, "не подключена"),
            (.unauthorised, "не приняла токен"),
            (.http(500), "ответила ошибкой 500"),
            (.unreadable, "ответила непонятным образом"),
        ]
        for (error, expected) in cases {
            let text = try #require(error.errorDescription)
            #expect(text.hasPrefix("База знаний "), "сервис не назван: \(text)")
            #expect(text.contains(expected), "в «\(text)» нет «\(expected)»")
            for masculine in ["не подключён", "не принял ", "ответил ", "ответило "] {
                #expect(!text.contains(masculine),
                        "мужской род при женском подлежащем: \(text)")
            }
        }
    }

    @Test("название и подсказка адреса есть у каждого сервиса заметок",
          arguments: TeamNotes.Service.allCases)
    func serviceStrings(service: TeamNotes.Service) {
        #expect(!service.title.isEmpty)
        #expect(service.hostPrompt.contains("адрес"),
                "подсказка не говорит, что вписывать: \(service.hostPrompt)")
    }
}
