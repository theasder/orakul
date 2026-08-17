import Foundation
import Testing
import OrakulCore
@testable import MeetGPT

@Suite("Локальный архив Telegram", .serialized)
struct TelegramMessageArchiveTests {
    private func location() -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-telegram-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("messages.json"))
    }

    private func message(update: Int64, chat: Int64 = -1001, id: Int64 = 7,
                         topic: Int64? = 11, text: String,
                         edited: Bool = false) -> TelegramSupergroups.Message {
        TelegramSupergroups.Message(
            updateID: update, chatID: chat, messageID: id, topicID: topic,
            chatTitle: "Запуск", author: "Ира", text: text,
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_770_000_000 + update)),
            isEdited: edited)
    }

    @Test("offset, allowlist, edit, topic, dedupe и поиск переживают перезапуск")
    func ingestAndSearchAreDurable() async throws {
        let (root, file) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(fileURL: file)
        try await archive.activate(botID: 44)
        try await archive.ingest(.init(messages: [
            message(update: 10, text: "Старый тариф"),
            message(update: 11, text: "Исправленный тариф", edited: true),
            message(update: 12, chat: -9999, id: 8, text: "Чужой секрет"),
        ], nextOffset: 13), allowedChatIDs: [-1001])

        #expect(await archive.offset() == 13)
        #expect(await archive.count(allowedChatIDs: [-1001]) == 1)
        let hits = await archive.search("тариф", allowedChatIDs: [-1001])
        #expect(hits.count == 1)
        #expect(hits.first?.message.text == "Исправленный тариф")
        #expect(hits.first?.message.topicID == 11)
        #expect(hits.first?.message.isEdited == true)
        #expect((await archive.search("секрет", allowedChatIDs: [-1001])).isEmpty)

        let reopened = TelegramMessageArchive(fileURL: file)
        #expect(await reopened.offset() == 13)
        #expect((await reopened.search("тариф", allowedChatIDs: [-1001])).count == 1)
    }

    @Test("другой bot id не наследует offset и сообщения")
    func botIdentityScopesTheOffset() async throws {
        let (root, file) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(fileURL: file)
        try await archive.activate(botID: 44)
        try await archive.ingest(.init(messages: [message(update: 20, text: "Тариф")],
                                       nextOffset: 21), allowedChatIDs: [-1001])

        try await archive.activate(botID: 55)
        #expect(await archive.offset() == nil)
        #expect(await archive.count(allowedChatIDs: [-1001]) == 0)
    }

    @Test("offset истекает после недели без обновлений, но сообщения остаются")
    func staleOffsetExpiresDurably() async throws {
        let (root, file) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let receivedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let archive = TelegramMessageArchive(fileURL: file)
        try await archive.activate(botID: 44)
        try await archive.ingest(
            .init(messages: [message(update: 20, text: "Тариф")], nextOffset: 21),
            allowedChatIDs: [-1001], receivedAt: receivedAt)

        #expect(await archive.offset(
            now: receivedAt.addingTimeInterval(7 * 24 * 60 * 60 - 1)) == 21)
        #expect(await archive.offset(
            now: receivedAt.addingTimeInterval(7 * 24 * 60 * 60)) == nil)

        // First post-expiry update may have a lower random id. It becomes the
        // new sequential watermark instead of reviving the old offset 21.
        let resumedAt = receivedAt.addingTimeInterval(8 * 24 * 60 * 60)
        try await archive.ingest(
            .init(messages: [message(update: 3, id: 8, text: "Новый тариф")],
                  nextOffset: 4),
            allowedChatIDs: [-1001], receivedAt: resumedAt)
        #expect(await archive.offset(now: resumedAt) == 4)

        let reopened = TelegramMessageArchive(fileURL: file)
        #expect(await reopened.offset(now: resumedAt) == 4)
        #expect((await reopened.search("тариф", allowedChatIDs: [-1001])).count == 2)
    }

    @Test("disconnect ждёт poller и удаляет архив")
    func disconnectErasesArchive() async throws {
        let (root, file) = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TelegramMessageArchive(fileURL: file)
        try await archive.activate(botID: 44)
        try await archive.ingest(.init(messages: [message(update: 30, text: "Тариф")],
                                       nextOffset: 31), allowedChatIDs: [-1001])
        let source = TelegramSupergroupSource(archive: archive, http: { request in
            try await Task.sleep(nanoseconds: 20_000_000)
            return (Data(#"{"ok":true,"result":[]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        })
        try await source.start(token: "123:synthetic", allowedChatIDs: [-1001], botID: 44)
        try await source.disconnectAndEraseArchive()

        #expect(await archive.offset() == nil)
        #expect(await archive.count(allowedChatIDs: [-1001]) == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
