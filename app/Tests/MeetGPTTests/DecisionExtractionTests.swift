import Foundation
import Testing
@testable import MeetGPT

/// Что попадёт в журнал решений. Ошибка здесь долгоживущая: запись остаётся
/// после звонка и читается потом как то, о чём договорились. Покрытие было
/// 14% — проверялась отрисовка, а не разбор ответа модели.
@Suite("Извлечение решения из звонка", .serialized)
struct DecisionExtractionTests {

    private func run(_ json: String, transcript: String = "Аня: годовой не трогаем до декабря.",
                     context: String = "", goal: String = "") async throws
        -> (decision: DecisionLogService.CapturedDecision?, gateway: MockLLMGateway) {
        let gateway = MockLLMGateway(response: json)
        let decision = try await LLMGatewayFactory.$overrideForTesting.withValue(gateway) {
            try await DecisionLogService.extract(
                transcript: transcript, context: context, goal: goal)
        }
        return (decision, gateway)
    }

    /// Честный промах лучше записи «ни о чём»: журнал, куда сыплется шум,
    /// перестают читать, и тогда он не хранит ничего.
    @Test("«решения не было» остаётся отсутствием записи")
    func noDecisionMeansNothingLogged() async throws {
        #expect(try await run(#"{"decision":null}"#).decision == nil)
        #expect(try await run(#"{"decision":{"title":"   ","statement":"x","goalType":"planning"}}"#)
                .decision == nil)
    }

    @Test("непонятный ответ не заводит запись",
          arguments: ["", "не могу", "{}", "[]", #"{"decision":"да"}"#])
    func unparsableReply(text: String) async throws {
        #expect(try await run(text).decision == nil)
    }

    @Test("пустая расшифровка не тратит запрос")
    func emptyTranscript() async throws {
        let out = try await run(#"{"decision":null}"#, transcript: "  \n ")
        #expect(out.decision == nil)
        #expect(out.gateway.calls.isEmpty)
    }

    /// Тип цели уходит в чужой API, и незнакомое значение там — отказ 400
    /// посреди звонка. Приводим к известному, а не пробуем на удачу.
    @Test("незнакомый тип цели приводится к известному, а не уезжает как есть")
    func goalTypeIsCoerced() async throws {
        let out = try await run("""
        {"decision":{"title":"Годовой тариф не трогаем","statement":"До декабря.",
        "goalType":"вымышленный","status":"decided"}}
        """)
        let decision = try #require(out.decision)
        #expect(DecisionLogService.goalTypes.contains(decision.goalType))
        #expect(decision.goalType == "planning")
    }

    @Test("незнакомое состояние становится «предложено», а не «решено»")
    func unknownStatusFallsBackToProposed() async throws {
        let out = try await run("""
        {"decision":{"title":"Годовой тариф не трогаем","statement":"До декабря.",
        "goalType":"planning","status":"почти решили"}}
        """)
        #expect(try #require(out.decision).status == "proposed",
                "сомнительное состояние не должно повышаться до решённого")
    }

    @Test("известные тип и состояние сохраняются как есть")
    func knownValuesSurvive() async throws {
        let out = try await run("""
        {"decision":{"title":"Годовой тариф не трогаем","statement":"До декабря.",
        "goalType":"planning","status":"decided","rationale":"Возражений нет."}}
        """)
        let decision = try #require(out.decision)
        #expect(decision.status == "decided")
        #expect(decision.goalType == "planning")
        #expect(decision.title == "Годовой тариф не трогаем")
    }

    @Test("цель встречи и добавочные сведения попадают в запрос")
    func goalAndContextAreSent() async throws {
        let out = try await run(#"{"decision":null}"#,
                                context: "Прошлое решение: годовой поднимали в июне.",
                                goal: "Согласовать тарифы")
        let call = try #require(out.gateway.calls.first)
        #expect(call.user.contains("Согласовать тарифы"))
        #expect(call.user.contains("годовой поднимали в июне"))
    }

    /// Долгий звонок не должен расти в цене без конца: уходит хвост.
    @Test("в запрос уходит хвост расшифровки")
    func transcriptIsClipped() async throws {
        let old = String(repeating: "старое ", count: 5000)
        let recent = "Аня: решили — годовой не трогаем."
        let out = try await run(#"{"decision":null}"#, transcript: old + recent)
        let call = try #require(out.gateway.calls.first)
        #expect(call.user.contains(recent))
        #expect(call.user.count < old.count)
    }
}
