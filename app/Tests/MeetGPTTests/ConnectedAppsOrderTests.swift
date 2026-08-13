import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT
import OrakulCore

/// «Подключённые приложения»: российские трекеры стоят первыми.
///
/// Порядок здесь — это и есть функция. Список, начинающийся с Notion и Linear,
/// человек с задачами в Яндекс Трекере читает как «нашего тут нет»; до нужной
/// строки он не долистает, даже если она в списке есть. Порядок легко
/// разъезжается при следующей правке настроек, поэтому он закреплён тестом, а
/// не комментарием.
@MainActor
@Suite("Порядок в «Подключённых приложениях»", .serialized)
struct ConnectedAppsOrderTests {

    /// Читается исходник, а не отрисованное дерево: `ConnectedAppsTab`
    /// приватный, а порядок задан буквально порядком блоков в `body`.
    private var settingsSource: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetGPTTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .appendingPathComponent("Sources/MeetGPT/Views/SettingsView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("блок российских трекеров идёт раньше Google и зарубежных приложений")
    func russianTrackersComeFirst() throws {
        let source = settingsSource
        #expect(!source.isEmpty, "не прочитался SettingsView.swift — сравнение было бы фиктивным")

        let trackers = try #require(source.range(of: "RussianTrackersSection()"))
        let google = try #require(source.range(of: "GoogleSignInRow()"))
        let mcp = try #require(source.range(of: "MCPAppsSection()"))

        #expect(trackers.lowerBound < google.lowerBound, "трекеры уехали ниже Google")
        #expect(trackers.lowerBound < mcp.lowerBound, "трекеры уехали ниже зарубежных приложений")
    }

    @Test("у каждого трекера есть кнопка подключения с устойчивым идентификатором")
    func everyTrackerIsReachable() throws {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.selectedSettingsTab = .connectedApps
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        let view = try SettingsView()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()

        for service in RussianTrackers.Service.allCases {
            let id = "settings.tracker.\(service.rawValue).connect"
            #expect(throws: Never.self, "нет строки для \(service.title): \(id)") {
                _ = try view.find(viewWithAccessibilityIdentifier: id)
            }
        }
    }
}
