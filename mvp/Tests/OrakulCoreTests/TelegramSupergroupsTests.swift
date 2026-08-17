import Foundation
import Testing
@testable import OrakulCore

@Suite("Telegram Bot API: супергруппы")
struct TelegramSupergroupsTests {
    private func http(status: Int = 200,
                      response: @escaping @Sendable (URLRequest) -> String)
        -> TelegramSupergroups.HTTP {
        { request in
            (Data(response(request).utf8),
             HTTPURLResponse(url: request.url!, statusCode: status,
                             httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("getMe и пустой webhook подтверждают бота с выключенной приватностью")
    func validatesReadableBot() async throws {
        let recorder = Recorder()
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            recorder.record(request)
            if request.url!.path.hasSuffix("/getMe") {
                return #"{"ok":true,"result":{"id":44,"is_bot":true,"username":"orakul_test_bot","first_name":"Orakul","can_read_all_group_messages":true}}"#
            }
            if request.url!.path.hasSuffix("/getWebhookInfo") {
                return #"{"ok":true,"result":{"url":"","has_custom_certificate":false,"pending_update_count":0}}"#
            }
            if request.url!.path.hasSuffix("/getChat") {
                return #"{"ok":true,"result":{"id":-1001,"type":"supergroup","title":"Проект"}}"#
            }
            return #"{"ok":true,"result":{"status":"member"}}"#
        })

        let bot = try await client.validate(allowedChatIDs: [-1001])
        #expect(bot.id == 44)
        #expect(bot.username == "orakul_test_bot")
        #expect(recorder.all.map { $0.url!.lastPathComponent }
            == ["getMe", "getWebhookInfo", "getChat", "getChatMember"])
    }

    @Test("выключенная приватность не маскирует неверный allowlist или отсутствующего бота")
    func readableBotStillVerifiesMembership() async {
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            if request.url!.path.hasSuffix("/getMe") {
                return #"{"ok":true,"result":{"id":44,"first_name":"O","can_read_all_group_messages":true}}"#
            }
            if request.url!.path.hasSuffix("/getWebhookInfo") {
                return #"{"ok":true,"result":{"url":""}}"#
            }
            if request.url!.path.hasSuffix("/getChat") {
                return #"{"ok":true,"result":{"id":-1001,"type":"supergroup"}}"#
            }
            return #"{"ok":true,"result":{"status":"left"}}"#
        })
        await #expect(throws: TelegramSupergroups.ConnectorError
            .privacyEnabled(chatIDs: [-1001])) {
            try await client.validate(allowedChatIDs: [-1001])
        }
    }

    @Test("активный webhook диагностируется до long polling")
    func detectsWebhookConflict() async {
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            if request.url!.path.hasSuffix("/getMe") {
                return #"{"ok":true,"result":{"id":44,"first_name":"O","can_read_all_group_messages":true}}"#
            }
            return #"{"ok":true,"result":{"url":"https://example.test/hook"}}"#
        })
        await #expect(throws: TelegramSupergroups.ConnectorError.webhookConflict) {
            try await client.validate(allowedChatIDs: [-1001])
        }
    }

    @Test("privacy mode допускается только когда бот администратор allowlist-чата")
    func diagnosesPrivacyPerChat() async {
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            if request.url!.path.hasSuffix("/getMe") {
                return #"{"ok":true,"result":{"id":44,"first_name":"O","can_read_all_group_messages":false}}"#
            }
            if request.url!.path.hasSuffix("/getWebhookInfo") {
                return #"{"ok":true,"result":{"url":""}}"#
            }
            if request.url!.path.hasSuffix("/getChat") {
                return #"{"ok":true,"result":{"id":-1001,"type":"supergroup"}}"#
            }
            let chat = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "chat_id" }?.value
            return chat == "-1001"
                ? #"{"ok":true,"result":{"status":"administrator"}}"#
                : #"{"ok":true,"result":{"status":"member"}}"#
        })
        await #expect(throws: TelegramSupergroups.ConnectorError
            .privacyEnabled(chatIDs: [-1002])) {
            try await client.validate(allowedChatIDs: [-1001, -1002])
        }
    }

    @Test("обычная группа диагностируется до проверки membership")
    func rejectsNonSupergroups() async throws {
        let recorder = Recorder()
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            recorder.record(request)
            if request.url!.path.hasSuffix("/getMe") {
                return #"{"ok":true,"result":{"id":44,"first_name":"O","can_read_all_group_messages":true}}"#
            }
            if request.url!.path.hasSuffix("/getWebhookInfo") {
                return #"{"ok":true,"result":{"url":""}}"#
            }
            return #"{"ok":true,"result":{"id":-77,"type":"group","title":"Старая группа"}}"#
        })

        await #expect(throws: TelegramSupergroups.ConnectorError
            .notSupergroup(chatIDs: [-77])) {
            try await client.validate(allowedChatIDs: [-77])
        }
        #expect(!recorder.all.contains { $0.url?.path.hasSuffix("/getChatMember") == true })
        let copy = try #require(TelegramSupergroups.ConnectorError
            .notSupergroup(chatIDs: [-77]).errorDescription)
        #expect(copy.contains("не являются супергруппами"))
        #expect(copy.contains("-100"))
    }

    @Test("offset проходит мимо чужих, отредактированных и повреждённых сообщений")
    func parsesAllowedUpdatesAndAlwaysAdvances() async throws {
        let body = #"{"ok":true,"result":[{"update_id":10,"message":{"message_id":1,"message_thread_id":7,"from":{"first_name":"Ира","last_name":"П."},"date":1770000000,"chat":{"id":-1001,"type":"supergroup","title":"Проект"},"text":"Первый тариф"}},{"update_id":11,"message":{"message_id":"broken"}},{"update_id":12,"message":{"message_id":2,"date":1770000001,"chat":{"id":-9999,"type":"supergroup","title":"Чужой"},"text":"Секрет"}},{"update_id":13,"edited_message":{"message_id":1,"message_thread_id":8,"from":{"first_name":"Ира"},"date":1770000002,"chat":{"id":-1001,"type":"supergroup","title":"Проект"},"text":"Исправленный тариф"}}]}"#
        let recorder = Recorder()
        let client = TelegramSupergroups(token: "123:synthetic", http: http { request in
            recorder.record(request); return body
        })
        let batch = try await client.fetchUpdates(
            offset: 10, allowedChatIDs: [-1001], timeout: 0)

        #expect(batch.nextOffset == 14)
        #expect(batch.messages.map(\.text) == ["Первый тариф", "Исправленный тариф"])
        #expect(batch.messages.last?.topicID == 8)
        #expect(batch.messages.last?.isEdited == true)
        let query = URLComponents(url: try #require(recorder.last?.url),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "offset" && $0.value == "10" })
        #expect(query.contains { $0.name == "allowed_updates"
            && $0.value == #"["message","edited_message"]"# })
    }

    @Test("невалидный JSON, 401 и 429 не превращаются в пустой архив")
    func errorsStayDistinct() async {
        let malformed = TelegramSupergroups(token: "t", http: http { _ in "not-json" })
        await #expect(throws: TelegramSupergroups.ConnectorError.unreadable) {
            try await malformed.fetchUpdates(offset: nil, allowedChatIDs: [-1])
        }

        let unauthorised = TelegramSupergroups(token: "t", http: http(status: 401) { _ in "{}" })
        await #expect(throws: TelegramSupergroups.ConnectorError.unauthorised) {
            try await unauthorised.fetchUpdates(offset: nil, allowedChatIDs: [-1])
        }

        let limited = TelegramSupergroups(token: "t", http: http(status: 429) { _ in
            #"{"ok":false,"error_code":429,"parameters":{"retry_after":9}}"#
        })
        await #expect(throws: TelegramSupergroups.ConnectorError.rateLimited(retryAfter: 9)) {
            try await limited.fetchUpdates(offset: nil, allowedChatIDs: [-1])
        }
    }
}
