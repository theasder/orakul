import Foundation

/// Prospective, read-only Telegram supergroup ingestion.
///
/// Telegram's Bot API cannot search or backfill chat history. This client only
/// receives updates delivered after a bot is connected; the app persists them
/// and searches that local archive. It intentionally exposes no send method.
public struct TelegramSupergroups: Sendable {
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let live: HTTP = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    public struct Message: Codable, Equatable, Sendable {
        public let updateID: Int64
        public let chatID: Int64
        public let messageID: Int64
        public let topicID: Int64?
        public let chatTitle: String
        public let author: String?
        public let text: String
        public let timestamp: Date
        public let isEdited: Bool

        public init(updateID: Int64, chatID: Int64, messageID: Int64,
                    topicID: Int64? = nil, chatTitle: String, author: String? = nil,
                    text: String, timestamp: Date, isEdited: Bool = false) {
            self.updateID = updateID
            self.chatID = chatID
            self.messageID = messageID
            self.topicID = topicID
            self.chatTitle = chatTitle
            self.author = author
            self.text = text
            self.timestamp = timestamp
            self.isEdited = isEdited
        }
    }

    public struct Batch: Equatable, Sendable {
        public let messages: [Message]
        /// The next offset must advance past every update, including unsupported
        /// or malformed message-shaped updates, so one bad item cannot wedge polling.
        public let nextOffset: Int64?

        public init(messages: [Message], nextOffset: Int64?) {
            self.messages = messages
            self.nextOffset = nextOffset
        }
    }

    public struct Bot: Equatable, Sendable {
        public let id: Int64
        public let username: String?
        public let canReadAllGroupMessages: Bool
    }

    public enum ConnectorError: Error, Equatable, LocalizedError, Sendable {
        case notConfigured
        case unauthorised
        case webhookConflict
        case notSupergroup(chatIDs: [Int64])
        case privacyEnabled(chatIDs: [Int64])
        case rateLimited(retryAfter: Int?)
        case http(Int)
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Укажите токен Telegram-бота и хотя бы один ID супергруппы."
            case .unauthorised:
                return "Telegram не принял токен бота. Проверьте токен в BotFather."
            case .webhookConflict:
                return "У бота уже включён webhook. Один бот не может одновременно получать обновления через webhook и orakul; создайте отдельного бота или удалите webhook."
            case .notSupergroup(let chatIDs):
                let ids = chatIDs.map(String.init).joined(separator: ", ")
                return "Чаты \(ids) не являются супергруппами Telegram. Укажите ID супергрупп вида -100…; обычные группы, каналы и личные чаты не поддерживаются."
            case .privacyEnabled(let chatIDs):
                let ids = chatIDs.map(String.init).joined(separator: ", ")
                return "Бот не может читать все сообщения в супергруппах \(ids). Проверьте ID и что бот добавлен; затем отключите режим приватности в BotFather или сделайте его администратором каждой группы."
            case .rateLimited(let seconds):
                return seconds.map { "Telegram ограничил частоту запросов. Повтор через \($0) с." }
                    ?? "Telegram ограничил частоту запросов. Повторите позже."
            case .http(let status):
                return "Telegram ответил ошибкой \(status)."
            case .unreadable:
                return "Telegram ответил в непонятном формате."
            }
        }
    }

    private let token: String
    private let http: HTTP

    public init(token: String, http: @escaping HTTP) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
    }

    /// Verifies the credential, long-poll/webhook compatibility, and whether
    /// the bot can see ordinary messages in every allowlisted supergroup.
    @discardableResult
    public func validate(allowedChatIDs: Set<Int64>) async throws -> Bot {
        guard !token.isEmpty, !allowedChatIDs.isEmpty else {
            throw ConnectorError.notConfigured
        }
        let me: GetMe = try await call("getMe")
        let bot = Bot(id: me.id, username: me.username,
                      canReadAllGroupMessages: me.canReadAllGroupMessages ?? false)

        let webhook: WebhookInfo = try await call("getWebhookInfo")
        guard webhook.url.isEmpty else { throw ConnectorError.webhookConflict }

        var notSupergroups: [Int64] = []
        var unreadable: [Int64] = []
        for chatID in allowedChatIDs.sorted() {
            let chat: ChatInfo
            do {
                chat = try await call("getChat", query: [
                    URLQueryItem(name: "chat_id", value: String(chatID)),
                ])
            } catch let error as ConnectorError {
                if error == .unauthorised { throw error }
                if case .rateLimited = error { throw error }
                unreadable.append(chatID)
                continue
            } catch {
                unreadable.append(chatID)
                continue
            }
            guard chat.type == "supergroup" else {
                notSupergroups.append(chatID)
                continue
            }

            let member: ChatMember
            do {
                member = try await call("getChatMember", query: [
                    URLQueryItem(name: "chat_id", value: String(chatID)),
                    URLQueryItem(name: "user_id", value: String(bot.id)),
                ])
            } catch let error as ConnectorError {
                if error == .unauthorised { throw error }
                if case .rateLimited = error { throw error }
                // A missing bot, wrong chat ID, or insufficient access is a
                // chat-specific visibility failure, not proof that privacy is off.
                unreadable.append(chatID)
                continue
            } catch {
                unreadable.append(chatID)
                continue
            }

            let active = member.status == "member"
                || member.status == "administrator" || member.status == "creator"
            // Privacy-disabled bots may be ordinary members. With privacy on,
            // only an administrator/creator receives every ordinary message.
            let canSeeAll = bot.canReadAllGroupMessages
                ? active
                : member.status == "administrator" || member.status == "creator"
            if !canSeeAll { unreadable.append(chatID) }
        }
        if !notSupergroups.isEmpty {
            throw ConnectorError.notSupergroup(chatIDs: notSupergroups)
        }
        if !unreadable.isEmpty {
            throw ConnectorError.privacyEnabled(chatIDs: unreadable)
        }
        return bot
    }

    /// Reads one Bot API update page. Filtering by the user's allowlist happens
    /// here and again at archive insertion as defense in depth.
    public func fetchUpdates(offset: Int64?, allowedChatIDs: Set<Int64>,
                             timeout: Int = 0) async throws -> Batch {
        guard !token.isEmpty, !allowedChatIDs.isEmpty else {
            throw ConnectorError.notConfigured
        }
        var query = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "timeout", value: String(max(0, min(timeout, 50)))),
            URLQueryItem(name: "allowed_updates", value: #"["message","edited_message"]"#),
        ]
        if let offset { query.append(URLQueryItem(name: "offset", value: String(offset))) }
        let updates: [Update] = try await call("getUpdates", query: query,
                                               timeout: TimeInterval(max(timeout + 8, 8)))
        let nextOffset = updates.map(\.updateID).max().map { $0 + 1 }
        let messages = updates.compactMap { update -> Message? in
            let source = update.editedMessage ?? update.message
            guard let source, source.chat.type == "supergroup",
                  allowedChatIDs.contains(source.chat.id),
                  let rawText = source.text ?? source.caption else { return nil }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let author = source.from?.displayName ?? source.senderChat?.title
            return Message(updateID: update.updateID, chatID: source.chat.id,
                           messageID: source.messageID, topicID: source.messageThreadID,
                           chatTitle: source.chat.title ?? String(source.chat.id),
                           author: author, text: text,
                           timestamp: Date(timeIntervalSince1970: TimeInterval(source.date)),
                           isEdited: update.editedMessage != nil)
        }
        return Batch(messages: messages, nextOffset: nextOffset)
    }

    private func call<Result: Decodable>(_ method: String,
                                          query: [URLQueryItem] = [],
                                          timeout: TimeInterval = 8) async throws -> Result {
        guard !token.isEmpty else { throw ConnectorError.notConfigured }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.telegram.org"
        components.path = "/bot\(token)/\(method)"
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ConnectorError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await http(request)
        if response.statusCode == 401 { throw ConnectorError.unauthorised }
        if response.statusCode == 429 {
            throw ConnectorError.rateLimited(retryAfter: Self.retryAfter(from: data))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectorError.http(response.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: data) else {
            throw ConnectorError.unreadable
        }
        guard envelope.ok, let result = envelope.result else {
            if envelope.errorCode == 401 { throw ConnectorError.unauthorised }
            if envelope.errorCode == 429 {
                throw ConnectorError.rateLimited(retryAfter: envelope.parameters?.retryAfter)
            }
            throw envelope.errorCode.map(ConnectorError.http) ?? ConnectorError.unreadable
        }
        return result
    }

    private static func retryAfter(from data: Data) -> Int? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.parameters?.retryAfter
    }
}

private extension TelegramSupergroups {
    struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let errorCode: Int?
        let parameters: ResponseParameters?

        enum CodingKeys: String, CodingKey {
            case ok, result, parameters
            case errorCode = "error_code"
        }
    }

    struct ErrorEnvelope: Decodable { let parameters: ResponseParameters? }
    struct ResponseParameters: Decodable {
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey { case retryAfter = "retry_after" }
    }
    struct GetMe: Decodable {
        let id: Int64
        let username: String?
        let canReadAllGroupMessages: Bool?
        enum CodingKeys: String, CodingKey {
            case id, username
            case canReadAllGroupMessages = "can_read_all_group_messages"
        }
    }
    struct WebhookInfo: Decodable { let url: String }
    struct ChatInfo: Decodable { let type: String }
    struct ChatMember: Decodable { let status: String }
    struct Update: Decodable {
        let updateID: Int64
        let message: TelegramMessage?
        let editedMessage: TelegramMessage?
        enum CodingKeys: String, CodingKey {
            case updateID = "update_id"
            case message
            case editedMessage = "edited_message"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            updateID = try values.decode(Int64.self, forKey: .updateID)
            // A malformed message must not pin the update offset forever. Keep
            // its update_id and discard only the unreadable payload.
            message = try? values.decodeIfPresent(TelegramMessage.self, forKey: .message)
            editedMessage = try? values.decodeIfPresent(
                TelegramMessage.self, forKey: .editedMessage)
        }
    }
    struct TelegramMessage: Decodable {
        let messageID: Int64
        let messageThreadID: Int64?
        let from: User?
        let senderChat: Chat?
        let date: Int64
        let chat: Chat
        let text: String?
        let caption: String?
        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case messageThreadID = "message_thread_id"
            case from
            case senderChat = "sender_chat"
            case date, chat, text, caption
        }
    }
    struct Chat: Decodable {
        let id: Int64
        let type: String
        let title: String?
    }
    struct User: Decodable {
        let firstName: String
        let lastName: String?
        let username: String?
        enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
            case lastName = "last_name"
            case username
        }
        var displayName: String {
            let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            return name.isEmpty ? (username ?? "") : name
        }
    }
}
