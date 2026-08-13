import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT
import OrakulCore

/// Что человек видит на экране — по-русски.
///
/// Отличие от `RussianCopyTests`: там считаются литералы в исходниках, здесь —
/// отрисованный текст. Разница не теоретическая. Литерал может никогда не
/// показаться (рельса кредитов закрыта признаком и не рендерится вовсе), а
/// показанная строка может собираться в рантайме и целиком в исходниках не
/// встречаться. Считать надо то, что видно.
@MainActor
@Suite("Русский на экране", .serialized)
struct RenderedRussianTests {

    private func settingsText(_ tab: SettingsTab) throws -> [String] {
        let state = AppState(credentialStore: InMemoryKeychain())
        state.selectedSettingsTab = tab
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        return try SettingsView()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
    }

    /// Марки, адреса и технические имена — не непереведённый текст.
    private static let allowed: Set<String> = [
        "github", "notion", "linear", "jira", "asana", "zapier", "sentry",
        "fireflies", "zoom", "gmail", "google", "kaiten", "yougile", "slack",
        "confluence", "hubspot", "attio", "posthog", "amplitude", "mixpanel",
        "intercom", "atlassian", "openai", "anthropic", "claude", "gpt",
        "gemini", "deepseek", "qwen", "kimi", "glm", "yandexgpt", "whisper",
        "deepgram", "assemblyai", "parakeet", "docx", "word", "docs", "api",
        "mcp", "oauth", "url", "macos", "screencapturekit", "calendar",
        "orakul", "cruxwing", "wav", "png", "json", "rice", "arr", "kubernetes",
        "tech", "debt", "term", "sheet", "cap", "table", "sla", "wer", "key",
        "keys", "get", "com", "platform", "console", "aistudio", "dashscope",
        "aliyun", "moonshot", "yandex", "cloud", "folder",
        // Названия моделей — марки, а не непереведённый текст: «Zhipu GLM»,
        // «GPT-5.6 Sol», «large-v3». Переводить их значит называть чужой
        // продукт не тем именем, под которым он существует.
        "zhipu", "sol", "mini", "flash", "pro", "opus", "sonnet", "haiku",
        "large", "small", "base", "turbo", "lite", "max", "plus",
        // Мессенджеры — тоже марки: «Rocket.Chat» переводить некуда.
        "mattermost", "rocket", "chat", "telegram", "teams", "bot",
        // Открытые трекеры: тоже марки.
        "gitlab", "gitea", "forgejo", "zulip", "pachca",
        "redmine", "outline", "matrix", "element",
    ]

    /// Латинская фраза: два и более слова длиннее двух букв, и хотя бы одно из
    /// них — не марка. Одиночные слова и адреса так не ловятся, и не должны.
    private func isEnglishSentence(_ text: String) -> Bool {
        guard text.range(of: "[а-яё]", options: [.regularExpression, .caseInsensitive]) == nil
        else { return false }
        // Адрес — не непереведённая фраза. В отладочной сборке на вкладке
        // подключений показывается адрес MCP из `.env`
        // (`http://localhost:8787/mcp`), и переводить в нём нечего.
        guard !text.contains("://") else { return false }
        let words = text
            .components(separatedBy: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").inverted)
            .filter { $0.count > 2 }
        guard words.count >= 2 else { return false }
        return !words.allSatisfy { Self.allowed.contains($0.lowercased()) }
    }

    @Test("на вкладках настроек нет английских фраз",
          arguments: [SettingsTab.general, .transcription, .ai,
                      .connectedApps, .accountPrivacy])
    func settingsTabsAreRussian(tab: SettingsTab) throws {
        let strings = try settingsText(tab)
        #expect(!strings.isEmpty, "вкладка \(tab) не отрисовалась — проверка была бы фиктивной")

        let english = strings.filter(isEnglishSentence)
        #expect(english.isEmpty, "вкладка \(tab): \(english.joined(separator: " | "))")
    }

    @Test("на экранах первого запуска нет английских фраз")
    func firstRunScreensAreRussian() throws {
        // Это первое, что видит человек, и на этих экранах уже находились
        // английские подписи, которые счётчик по исходникам не показывал: он
        // считает литералы в трёх папках, а текст первого запуска собирается и
        // за их пределами.
        let state = AppState(credentialStore: InMemoryKeychain())
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())

        let screens: [(String, [String])] = [
            ("проверка захвата",
             try CaptureCheckStep(onContinue: {})
                .environmentObject(state).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
            ("карточка настройки",
             try SetupCard()
                .environmentObject(state).environmentObject(manager).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
            ("согласие на запись",
             try RecordingConsentSheet()
                .environmentObject(state).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
        ]

        for (name, strings) in screens {
            #expect(!strings.isEmpty, "\(name) не отрисовался — проверка была бы фиктивной")
            let english = strings.filter(isEnglishSentence)
            #expect(english.isEmpty, "\(name): \(english.joined(separator: " | "))")
        }
    }


    @Test("в главном окне нет английских фраз")
    func mainWindowIsRussian() throws {
        // Архив звонков берётся из временной папки, а не из настоящего.
        //
        // Иначе тест читал бы историю той машины, где запущен: у меня в боковой
        // панели лежат звонки с английскими названиями, и проверка ругалась бы
        // на мои же данные вместо интерфейса. Пустой архив — единственный
        // способ проверить именно интерфейс.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orakul-render-\(UUID().uuidString)", isDirectory: true)

        // Своя роль тоже своя у каждой машины: она лежит в UserDefaults, и в
        // тестовом хосте от прошлых прогонов осталось «Head of RevOps». Проверка
        // ругалась бы на чужую строку вместо интерфейса.
        let savedRole = Config.userCustomRole
        defer { Config.userCustomRole = savedRole }
        Config.userCustomRole = ""

        let state = AppState(llm: MockLLMGateway(response: ""),
                             sessionStore: SessionStore(root: root))
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        state.mcp = manager

        let screens: [(String, [String])] = [
            ("боковая панель",
             try Sidebar()
                .environmentObject(state).environmentObject(manager).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
            ("панель ассистента",
             try AIStudioView()
                .environmentObject(state).environmentObject(manager).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
        ]

        for (name, strings) in screens {
            #expect(!strings.isEmpty, "\(name) не отрисовалась — проверка была бы фиктивной")
            let english = strings.filter(isEnglishSentence)
            #expect(english.isEmpty, "\(name): \(english.joined(separator: " | "))")
        }
    }

    @Test("экраны ключей и трекеров по-русски")
    func keysAndTrackersAreRussian() throws {
        // Два экрана, ради которых orakul вообще открывают: куда вставить ключ
        // и как подключить трекер.
        //
        // Порог по числу строк — не украшение. Соседние экраны при отрисовке в
        // тесте дают ноль текстовых элементов (меню в строке состояния —
        // ровно такой), и проверка на них зелёная, ничего не проверив. Числа
        // ниже — то, что эти экраны дают на самом деле.
        let state = AppState(credentialStore: InMemoryKeychain())
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())

        let screens: [(name: String, minimum: Int, strings: [String])] = [
            ("российские трекеры", 6,
             try RussianTrackersSection()
                .environmentObject(state).environmentObject(manager).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
            ("ключи провайдеров", 12,
             try ProviderKeysSection()
                .environmentObject(state).environmentObject(manager).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }),
        ]

        for (name, minimum, strings) in screens {
            #expect(strings.count >= minimum,
                    "\(name): отрисовано \(strings.count) строк вместо \(minimum)+ — проверка пустая")
            let english = strings.filter(isEnglishSentence)
            #expect(english.isEmpty, "\(name): \(english.joined(separator: " | "))")
        }
    }

    @Test("тип записи на плашке по-русски, а в промпте остаётся английским")
    func recordingTypeLabelsSplitByAudience() {
        // Одно поле служило двум хозяевам: `label` показывался на плашке записи
        // И подставлялся в модельный промпт «Recording type: …». Пока они были
        // одним значением, перевести экран значило сломать промпт, и тип записи
        // так и оставался английским. Теперь их два, и проверяются оба.
        for kind in RecordingContextKind.allCases {
            #expect(kind.displayLabel.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil,
                    "тип записи не по-русски: \(kind) → \(kind.displayLabel)")
            #expect(kind.label.range(of: "^[A-Za-z / ]+$", options: .regularExpression) != nil,
                    "промпт получит не то имя: \(kind) → \(kind.label)")
        }

        // И то, что видит человек, идёт из русского поля.
        let selection = RecordingContextSelection(mode: .lecture)
        #expect(selection.resolvedDisplayLabel(detected: .meeting) == "Лекция")
        #expect(selection.resolvedLabel(detected: .meeting) == "Lecture")
    }


    @Test("проверка ловит английский, а не пропускает всё подряд")
    func theCheckActuallyCatchesEnglish() {
        // Без этого предыдущий тест зелёный и со сломанным фильтром. Такое тут
        // уже было: проверка на подстроку проходила с удалённой защитой.
        #expect(isEnglishSentence("Save the answer as a Word document"))
        #expect(isEnglishSentence("Needs attention"))
        #expect(isEnglishSentence("Hide this meeting"))

        // И не ругается на то, что переводить нельзя.
        #expect(!isEnglishSentence("Яндекс Трекер"))
        #expect(!isEnglishSentence("platform.openai.com"))
        #expect(!isEnglishSentence("Google Calendar"))
        #expect(!isEnglishSentence("Ключ для OpenAI"))
    }
}
