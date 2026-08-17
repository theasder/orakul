import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

@MainActor
@Suite("Telegram в подсказке", .serialized)
struct TelegramGroundingTests {
    private enum EraseFailure: Error, Equatable { case denied }

    @Test("manager проверяет, сохраняет, запускает и полностью отключает Telegram")
    func managerOwnsConnectionLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-telegram-lifecycle-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(
            fileURL: root.appendingPathComponent("messages.json"))
        let keychain = InMemoryKeychain()
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter(),
            telegramHTTP: { request in
                let body: String
                if request.url!.path.hasSuffix("/getMe") {
                    body = #"{"ok":true,"result":{"id":44,"first_name":"Orakul","can_read_all_group_messages":true}}"#
                } else if request.url!.path.hasSuffix("/getWebhookInfo") {
                    body = #"{"ok":true,"result":{"url":""}}"#
                } else if request.url!.path.hasSuffix("/getChat") {
                    body = #"{"ok":true,"result":{"id":-1001,"type":"supergroup"}}"#
                } else if request.url!.path.hasSuffix("/getChatMember") {
                    body = #"{"ok":true,"result":{"status":"member"}}"#
                } else {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    body = #"{"ok":true,"result":[]}"#
                }
                return (Data(body.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }, telegramArchive: archive)

        let bot = try await manager.connectTelegram(
            token: "123:synthetic", allowedChatIDs: [-1001])
        #expect(bot.id == 44)
        #expect(manager.trackerStore.isTelegramConfigured)
        #expect(manager.trackerStore.telegramBotID() == 44)

        try await manager.disconnectTelegram()
        #expect(!manager.trackerStore.isTelegramConfigured)
        #expect(keychain.count == 0)
        #expect(await archive.offset() == nil)
    }

    @Test("Keychain-настройка подключает локальный архив к grounding")
    func configuredArchiveGrounds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-telegram-grounding-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(
            fileURL: root.appendingPathComponent("messages.json"))
        try await archive.activate(botID: 44)
        let message = TelegramSupergroups.Message(
            updateID: 1, chatID: -1001, messageID: 8, topicID: 3,
            chatTitle: "Запуск", author: "Ира",
            text: "Новый тариф запускаем в пятницу",
            timestamp: Date(timeIntervalSince1970: 1_770_000_000))
        try await archive.ingest(.init(messages: [message], nextOffset: 2),
                                 allowedChatIDs: [-1001])

        let keychain = InMemoryKeychain()
        RussianTrackerStore(store: keychain).setTelegram(
            token: "123:synthetic", allowedChatIDs: [-1001], botID: 44)
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter(),
            telegramHTTP: { request in
                try await Task.sleep(nanoseconds: 20_000_000)
                return (Data(#"{"ok":true,"result":[]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }, telegramArchive: archive)

        let snippets = await manager.groundingSnippets(goal: "какой новый тариф")
        await manager.telegramSource.stop()

        let telegram = snippets.first { $0.sourceID == "messenger:telegram" }
        #expect(telegram?.serverName == "Telegram")
        #expect(telegram?.toolName == "local_archive_search")
        #expect(telegram?.text.contains("Новый тариф запускаем в пятницу") == true)
        #expect(telegram?.text.contains("[Запуск · тема 3]") == true)
    }

    @Test("ошибка удаления архива сохраняет Keychain-настройку и архив")
    func failedEraseKeepsConnectionObservable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-telegram-erase-failure-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(
            fileURL: root.appendingPathComponent("messages.json"),
            removeItem: { _ in throw EraseFailure.denied })
        try await archive.activate(botID: 44)
        let message = TelegramSupergroups.Message(
            updateID: 1, chatID: -1001, messageID: 8,
            chatTitle: "Запуск", text: "Сохранённый тариф",
            timestamp: Date(timeIntervalSince1970: 1_770_000_000))
        try await archive.ingest(.init(messages: [message], nextOffset: 2),
                                 allowedChatIDs: [-1001])

        let keychain = InMemoryKeychain()
        RussianTrackerStore(store: keychain).setTelegram(
            token: "123:synthetic", allowedChatIDs: [-1001], botID: 44)
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter(),
            telegramHTTP: { request in
                try await Task.sleep(nanoseconds: 20_000_000)
                return (Data(#"{"ok":true,"result":[]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }, telegramArchive: archive)
        try await manager.telegramSource.start(
            token: "123:synthetic", allowedChatIDs: [-1001], botID: 44)

        await #expect(throws: EraseFailure.denied) {
            try await manager.disconnectTelegram()
        }
        #expect(manager.trackerStore.isTelegramConfigured)
        #expect(keychain.count == 3)
        #expect((await archive.search("тариф", allowedChatIDs: [-1001])).count == 1)
        await manager.telegramSource.stop()
    }
}
