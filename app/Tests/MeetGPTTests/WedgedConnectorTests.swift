import Foundation
import Testing
@testable import MeetGPT
import OrakulCore

/// Зависший коннектор не должен стоить ответа на звонке.
///
/// Веер источников — `withTaskGroup`, а группа ждёт ВСЕ задачи. Российские
/// коннекторы вызывались как `try? await client.search(query)` без общего
/// срока: единственной защитой был `timeoutInterval` у запроса, а он в
/// URLSession сбрасывается на каждом принятом байте. Сервер, отдающий по
/// байту раз в несколько секунд, держит соединение сколько угодно — и веер
/// не завершается никогда. У MCP-инструментов срок был, у этих пяти нет.
@Suite("Зависший коннектор")
struct WedgedConnectorTests {

    /// HTTP, который никогда не отвечает.
    private static let hanging: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in
        try await Task.sleep(nanoseconds: 60_000_000_000)   // минута — дольше любого срока
        throw URLError(.timedOut)
    }

    @Test("срок обрывает зависший поиск, а не ждёт его")
    func deadlineCutsTheHang() async {
        let began = Date()
        let result = await withMCPDeadline(seconds: 0.3) {
            try await WorkMessengers(service: .mattermost, token: "t", secondary: "host",
                                     scope: nil, http: Self.hanging).search("тарифы")
        }
        let elapsed = Date().timeIntervalSince(began)

        #expect(result == nil, "зависший коннектор вернул результат — срок не сработал")
        #expect(elapsed < 5,
                "ждали \(String(format: "%.1f", elapsed)) с вместо 0.3 — срок не ограничивает вызов")
    }

    @Test("живой коннектор сроком не обрезается")
    func healthyCallSurvives() async {
        // Иначе «починка» свелась бы к тому, что не работает ничего.
        let ok: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            let body = #"{"order":["p1"],"posts":{"p1":{"message":"обсудили тарифы","user_id":"u1"}}}"#
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        }
        let hits = await withMCPDeadline(seconds: 5) {
            try await WorkMessengers(service: .mattermost, token: "t", secondary: "chat.company.ru",
                                     scope: "team-1", http: ok).search("тарифы")
        }
        #expect(hits?.isEmpty == false, "здоровый коннектор ничего не вернул")
    }

    @Test("веер источников ограничен сроком в коде, а не только в комментарии")
    func fanOutCallsAreDeadlineWrapped() throws {
        // Структурно: вызовы коннекторов обязаны идти через `withMCPDeadline`.
        // Выполнить весь веер в тесте нельзя — он тянет живые сервисы.
        let source = try String(
            contentsOfFile: Self.groundingPath, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("try? await client.search("),
                "остался вызов коннектора без общего срока")
        let wrapped = code.components(separatedBy: "withMCPDeadline").count - 1
        #expect(wrapped >= 5,
                "обёрнуто только \(wrapped) вызовов — часть источников снова без срока")
    }

    @Test("сам срок остаётся человеческим")
    @MainActor
    func deadlineStaysInteractive() {
        // Обернуть вызов и выставить срок в сутки — то же самое, что не
        // оборачивать: мутация именно так и прошла мимо первой версии проверок.
        // Ответ нужен во время звонка, а не после него.
        #expect(MCPConnectionManager.groundingDeadline > 1,
                "срок меньше секунды обрежет живые сервисы")
        #expect(MCPConnectionManager.groundingDeadline <= 15,
                "срок \(MCPConnectionManager.groundingDeadline) с — это уже не срок, а его отсутствие")
    }

    static let groundingPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MeetGPT/MCP/MCPGrounding.swift").path
}
