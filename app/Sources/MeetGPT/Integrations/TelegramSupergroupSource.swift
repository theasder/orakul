import Foundation
import OrakulCore

/// Owns Telegram long polling for the lifetime of the app. Search never calls
/// Telegram: it reads the durable archive populated by this actor.
actor TelegramSupergroupSource {
    private let archive: TelegramMessageArchive
    private let http: TelegramSupergroups.HTTP
    private var token: String?
    private var allowedChatIDs: Set<Int64> = []
    private var pollingTask: Task<Void, Never>?

    init(archive: TelegramMessageArchive = .shared,
         http: @escaping TelegramSupergroups.HTTP = TelegramSupergroups.live) {
        self.archive = archive
        self.http = http
    }

    func validate(token: String, allowedChatIDs: Set<Int64>) async throws
        -> TelegramSupergroups.Bot {
        try await TelegramSupergroups(token: token, http: http)
            .validate(allowedChatIDs: allowedChatIDs)
    }

    func start(token: String, allowedChatIDs: Set<Int64>, botID: Int64? = nil) async throws {
        await stop()
        if let botID {
            try await archive.activate(botID: botID, allowedChatIDs: allowedChatIDs)
        }
        self.token = token
        self.allowedChatIDs = allowedChatIDs
        pollingTask = Task { [weak self] in
            await self?.pollUntilCancelled()
        }
    }

    func ensureStarted(token: String, allowedChatIDs: Set<Int64>, botID: Int64? = nil) async throws {
        guard self.token != token || self.allowedChatIDs != allowedChatIDs
                || pollingTask == nil else { return }
        try await start(token: token, allowedChatIDs: allowedChatIDs, botID: botID)
    }

    func stop() async {
        let task = pollingTask
        task?.cancel()
        pollingTask = nil
        token = nil
        allowedChatIDs = []
        // A cancelled request may still return one page. Wait before archive
        // reset so that late page cannot recreate data after disconnect.
        await task?.value
    }

    /// One page, exposed for deterministic tests and the first post-connect sync.
    @discardableResult
    func syncOnce(timeout: Int = 0) async throws -> TelegramSupergroups.Batch {
        guard let token, !allowedChatIDs.isEmpty else {
            throw TelegramSupergroups.ConnectorError.notConfigured
        }
        let client = TelegramSupergroups(token: token, http: http)
        let batch = try await client.fetchUpdates(
            offset: await archive.offset(), allowedChatIDs: allowedChatIDs, timeout: timeout)
        try await archive.ingest(batch, allowedChatIDs: allowedChatIDs)
        return batch
    }

    func search(_ query: String, limit: Int = 10) async -> [TelegramMessageArchive.Hit] {
        guard !allowedChatIDs.isEmpty else { return [] }
        return await archive.search(query, allowedChatIDs: allowedChatIDs, limit: limit)
    }

    func archivedCount() async -> Int {
        await archive.count(allowedChatIDs: allowedChatIDs)
    }

    func disconnectAndEraseArchive() async throws {
        await stop()
        try await archive.reset()
    }

    private func pollUntilCancelled() async {
        var fallbackDelay: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            do {
                _ = try await syncOnce(timeout: 25)
                fallbackDelay = 1_000_000_000
            } catch TelegramSupergroups.ConnectorError.rateLimited(let retryAfter) {
                let seconds = UInt64(max(1, retryAfter ?? 5))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                // Transient network/API failures must not discard the offset or
                // kill ingestion forever. Backoff caps at one minute.
                try? await Task.sleep(nanoseconds: fallbackDelay)
                fallbackDelay = min(fallbackDelay * 2, 60_000_000_000)
            }
        }
    }
}
