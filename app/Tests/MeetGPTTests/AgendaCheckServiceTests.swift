import Foundation
import Testing
@testable import MeetGPT

/// Служба идёт по ходу звонка сама, без нажатий, и её находки попадают человеку
/// на глаза как подсказки. Покрытие было нулевым: `make()` собирает настоящий
/// конвейер, и подставить свой шлюз было некуда.
///
/// Проверяется здесь не то, что модель хорошо думает, а то, что мы делаем с её
/// ответом: чего не пропускаем, что выбрасываем и что не спрашиваем вовсе.
@Suite("Проверка повестки", .serialized)
struct AgendaCheckServiceTests {

    private func reply(_ json: String) -> MockLLMGateway { MockLLMGateway(response: json) }

    private func run(_ gateway: MockLLMGateway,
                     transcript: String,
                     prior: [String] = []) async throws -> [Suggestion] {
        try await LLMGatewayFactory.$overrideForTesting.withValue(gateway) {
            try await AgendaCheckService.findings(transcript: transcript, priorTitles: prior)
        }
    }

    /// Главное. Модель обязана привести дословную цитату, и цитата проверяется
    /// по расшифровке. Находка без опоры — это выдумка, показанная человеку
    /// посреди звонка как то, что при нём сказали.
    @Test("находка без дословной цитаты из расшифровки выбрасывается")
    func evidenceMustComeFromTheTranscript() async throws {
        let transcript = "Аня: годовой тариф не трогаем до декабря. Борис: согласен."
        let gateway = reply("""
        {"findings":[
          {"title":"Одностороннее сравнение","detail":"Названа одна сторона.",
           "kind":"framing","evidence":"годовой тариф не трогаем до декабря"},
          {"title":"Выдумка","detail":"Такого не говорили.",
           "kind":"framing","evidence":"мы уволим половину отдела в январе"}
        ]}
        """)
        let found = try await run(gateway, transcript: transcript)
        #expect(found.map(\.title) == ["Одностороннее сравнение"],
                "находка без опоры в расшифровке дошла до человека")
    }

    @Test("framing показывается как риск, agenda — как совет")
    func kindMapping() async throws {
        let transcript = "Аня: давайте вернёмся к тарифам, мы ушли в найм."
        let gateway = reply("""
        {"findings":[
          {"title":"Уход от темы","detail":"Обсуждение ушло в найм.",
           "kind":"agenda","evidence":"мы ушли в найм"},
          {"title":"Нагруженная формулировка","detail":"Оценка вместо факта.",
           "kind":"framing","evidence":"давайте вернёмся к тарифам"}
        ]}
        """)
        let found = try await run(gateway, transcript: transcript)
        #expect(found.first(where: { $0.title == "Уход от темы" })?.kind == .advice)
        #expect(found.first(where: { $0.title == "Нагруженная формулировка" })?.kind == .risk)
    }

    @Test("пустая расшифровка не тратит запрос к модели")
    func emptyTranscriptAsksNothing() async throws {
        let gateway = reply(#"{"findings":[]}"#)
        let found = try await run(gateway, transcript: "   \n  ")
        #expect(found.isEmpty)
        #expect(gateway.calls.isEmpty, "спросили модель о пустой расшифровке")
    }

    /// Ответ модели — чужой текст, и он бывает любым. Ни один из этих случаев
    /// не должен ронять звонок: подсказок просто нет.
    @Test("непонятный ответ модели не роняет и не выдумывает",
          arguments: ["", "извините, не могу", "{}", #"{"findings":null}"#, "[1,2,3]"])
    func unparsableReply(text: String) async throws {
        let found = try await run(reply(text), transcript: "Аня: тарифы обсудили.")
        #expect(found.isEmpty)
    }

    @Test("уже показанное перечислено в запросе, чтобы не повторяться")
    func priorTitlesAreSent() async throws {
        let gateway = reply(#"{"findings":[]}"#)
        _ = try await run(gateway, transcript: "Аня: тарифы.", prior: ["Уход от темы"])
        let call = try #require(gateway.calls.first)
        #expect(call.system.contains("Уход от темы"), "модель не знает, что уже показано")
    }

    /// Долгий звонок — это десятки тысяч знаков. В запрос уходит хвост, а не
    /// всё: иначе цена запроса растёт весь звонок, а отвечает модель о начале.
    @Test("в запрос уходит хвост расшифровки, а не вся она")
    func transcriptIsClipped() async throws {
        let old = String(repeating: "старое ", count: 4000)
        let recent = "Аня: годовой тариф не трогаем."
        let gateway = reply(#"{"findings":[]}"#)
        _ = try await run(gateway, transcript: old + recent)
        let call = try #require(gateway.calls.first)
        #expect(call.user.contains(recent), "свежие реплики не попали в запрос")
        #expect(call.user.count < old.count, "ушла вся расшифровка целиком")
    }
}
