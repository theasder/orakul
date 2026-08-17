import Foundation
import OrakulCore

/// Durable local search index for messages delivered by Telegram after setup.
/// The bot token never enters this file; it remains in Keychain.
actor TelegramMessageArchive {
    struct Hit: Equatable, Sendable {
        let message: TelegramSupergroups.Message
        let excerpt: String
        let score: Double
    }

    private struct Snapshot: Codable {
        var botID: Int64?
        var nextOffset: Int64?
        /// When Telegram last delivered an update id (including unsupported or
        /// malformed updates). After a week without updates the Bot API may
        /// choose the next id randomly, so the old sequential offset expires.
        var offsetRecordedAt: Date?
        var messages: [TelegramSupergroups.Message]
    }

    static let shared: TelegramMessageArchive = {
        let base: URL
        if AppState.isUnderTest {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("cruxwing-tests/Telegram", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        let root = AppState.isUnderTest ? base
            : base.appendingPathComponent("MeetGPT/Telegram", isDirectory: true)
        return TelegramMessageArchive(fileURL: root.appendingPathComponent("messages.json"))
    }()

    private let fileURL: URL
    private let removeItem: @Sendable (URL) throws -> Void
    private var snapshot: Snapshot

    init(fileURL: URL,
         removeItem: @escaping @Sendable (URL) throws -> Void = {
             try FileManager.default.removeItem(at: $0)
         }) {
        self.fileURL = fileURL
        self.removeItem = removeItem
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode(Snapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = Snapshot(
                botID: nil, nextOffset: nil, offsetRecordedAt: nil, messages: [])
        }
    }

    /// Telegram offsets are scoped to a bot. Reusing one after a token change
    /// can jump past the new bot's first updates, so identity changes reset the
    /// archive before polling starts.
    func activate(botID: Int64, allowedChatIDs: Set<Int64>? = nil) throws {
        if snapshot.botID != botID {
            let previous = snapshot
            snapshot = Snapshot(
                botID: botID, nextOffset: nil, offsetRecordedAt: nil, messages: [])
            do { try persist() } catch {
                snapshot = previous
                throw error
            }
            return
        }
        if let allowedChatIDs {
            let retained = snapshot.messages.filter { allowedChatIDs.contains($0.chatID) }
            if retained.count != snapshot.messages.count {
                let previous = snapshot
                snapshot.messages = retained
                do { try persist() } catch {
                    snapshot = previous
                    throw error
                }
            }
        }
    }

    /// Telegram documents that update ids stop being sequential after at least
    /// one week without updates. Passing an older, larger offset could then hide
    /// every new update forever. An absent timestamp (a pre-migration snapshot)
    /// is likewise not safe to reuse.
    func offset(now: Date = Date()) -> Int64? {
        guard let nextOffset = snapshot.nextOffset,
              let recordedAt = snapshot.offsetRecordedAt,
              now.timeIntervalSince(recordedAt) < 7 * 24 * 60 * 60 else {
            // Clear in memory before the next fetch. Telegram may choose a new,
            // lower random update_id; retaining the old high watermark would
            // make `ingest` revive it through max(...).
            snapshot.nextOffset = nil
            snapshot.offsetRecordedAt = nil
            return nil
        }
        return nextOffset
    }

    func count(allowedChatIDs: Set<Int64>) -> Int {
        snapshot.messages.count { allowedChatIDs.contains($0.chatID) }
    }

    /// Upserts by Telegram's chat/message identity. Edited updates replace the
    /// archived text and topic metadata instead of producing a second hit.
    func ingest(_ batch: TelegramSupergroups.Batch,
                allowedChatIDs: Set<Int64>, receivedAt: Date = Date()) throws {
        let previous = snapshot
        var byID = Dictionary(uniqueKeysWithValues: snapshot.messages.map {
            (Self.key(for: $0), $0)
        })
        for message in batch.messages where allowedChatIDs.contains(message.chatID) {
            byID[Self.key(for: message)] = message
        }
        snapshot.messages = byID.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.chatID != $1.chatID { return $0.chatID < $1.chatID }
            return $0.messageID < $1.messageID
        }
        if let received = batch.nextOffset {
            snapshot.nextOffset = max(snapshot.nextOffset ?? received, received)
            snapshot.offsetRecordedAt = receivedAt
        }
        do { try persist() } catch {
            // The next poll must retry the same offset if durable storage failed.
            // Advancing only in memory would acknowledge messages that vanish on quit.
            snapshot = previous
            throw error
        }
    }

    func search(_ query: String, allowedChatIDs: Set<Int64>, limit: Int = 10) -> [Hit] {
        let allowed = snapshot.messages.filter { allowedChatIDs.contains($0.chatID) }
        let sessions = allowed.map { message -> RecallIndex.Session in
            let topic = message.topicID.map { " · тема \($0)" } ?? ""
            let author = message.author.map { "[\($0)] " } ?? ""
            return RecallIndex.Session(
                id: Self.key(for: message),
                title: "\(message.chatTitle)\(topic)",
                date: ISO8601DateFormatter().string(from: message.timestamp).prefix(10).description,
                digest: author + message.text)
        }
        let messagesByID = Dictionary(uniqueKeysWithValues: allowed.map {
            (Self.key(for: $0), $0)
        })
        return RecallIndex(sessions: sessions).search(query, limit: limit).compactMap { hit in
            guard let message = messagesByID[hit.session.id] else { return nil }
            return Hit(message: message, excerpt: hit.excerpt, score: hit.score)
        }
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try removeItem(fileURL)
        }
        snapshot = Snapshot(
            botID: nil, nextOffset: nil, offsetRecordedAt: nil, messages: [])
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func key(for message: TelegramSupergroups.Message) -> String {
        "\(message.chatID):\(message.messageID)"
    }
}
