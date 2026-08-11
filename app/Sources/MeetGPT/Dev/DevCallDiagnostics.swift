import Darwin
import Foundation

/// Explicitly-authorized, content-bearing diagnostics for development calls.
///
/// Production logging remains metadata-only. This writer is enabled only when
/// all of the following are true at process launch:
///
/// - the binary is a dev build;
/// - `CRUXWING_DEV_CALL_LOGS=1` was explicitly supplied;
/// - the normal live-test nonce is valid; and
/// - the live-test artifact root is a real owner-only (0700) directory.
///
/// Each call receives a bounded JSONL file in an owner-only subdirectory. The
/// payload is intentionally useful (assembled model requests, workflow
/// results, terminal answers, and execution/cost metadata), but credential-like
/// keys and token-shaped values are redacted before bytes reach the filesystem.
final class DevCallDiagnostics: @unchecked Sendable {
    struct Configuration: Sendable {
        let isDevBuild: Bool
        let enabledValue: String?
        let nonce: String?
        let artifactRoot: URL?
        let currentUserID: UInt32

        init(isDevBuild: Bool,
             enabledValue: String?,
             nonce: String?,
             artifactRoot: URL?,
             currentUserID: UInt32 = getuid()) {
            self.isDevBuild = isDevBuild
            self.enabledValue = enabledValue
            self.nonce = nonce
            self.artifactRoot = artifactRoot
            self.currentUserID = currentUserID
        }

        static var process: Configuration {
            let environment = ProcessInfo.processInfo.environment
            let root = environment["CRUXWING_LIVETEST_ARTIFACT_ROOT"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            return Configuration(
                isDevBuild: Config.isDevBuild,
                enabledValue: environment["CRUXWING_DEV_CALL_LOGS"],
                nonce: environment["CRUXWING_LIVETEST_NONCE"],
                artifactRoot: root)
        }
    }

    struct Limits: Sendable {
        let maximumStringBytes: Int
        let maximumEventBytes: Int
        let maximumFileBytes: Int
        let maximumFiles: Int
        let maximumCollectionItems: Int

        init(maximumStringBytes: Int = 64 * 1024,
             maximumEventBytes: Int = 256 * 1024,
             maximumFileBytes: Int = 4 * 1024 * 1024,
             maximumFiles: Int = 8,
             maximumCollectionItems: Int = 80) {
            self.maximumStringBytes = max(32, maximumStringBytes)
            self.maximumEventBytes = max(512, maximumEventBytes)
            self.maximumFileBytes = max(1_024, maximumFileBytes)
            self.maximumFiles = max(1, maximumFiles)
            self.maximumCollectionItems = max(1, maximumCollectionItems)
        }
    }

    struct Snapshot: Equatable, Sendable {
        let enabled: Bool
        let callID: String?
        let sessionID: String?
        let relativePath: String?
        let eventCount: Int
        let droppedEventCount: Int
        let bytesWritten: Int
    }

    static let shared = DevCallDiagnostics(configuration: .process)
    static let environmentOptIn = "CRUXWING_DEV_CALL_LOGS"
    static let directoryName = "dev-call-diagnostics"

    private let lock = NSLock()
    private let fileManager: FileManager
    private let limits: Limits
    private let directoryURL: URL?
    private let authorized: Bool
    private let currentUserID: UInt32

    private var activeCallID: String?
    private var activeSessionID: String?
    private var activeFileURL: URL?
    private var activeRelativePath: String?
    private var eventSequence = 0
    private var eventCount = 0
    private var droppedEventCount = 0
    private var bytesWritten = 0

    init(configuration: Configuration,
         limits: Limits = Limits(),
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.limits = limits
        self.currentUserID = configuration.currentUserID

        guard Self.optedIn(configuration.enabledValue),
              configuration.isDevBuild,
              let nonce = configuration.nonce,
              LiveTestHooks.validLiveTestNonce(nonce),
              let root = configuration.artifactRoot?.standardizedFileURL,
              LiveTestHooks.isOwnerOnlyArtifactRoot(
                root, currentUserID: configuration.currentUserID)
        else {
            authorized = false
            directoryURL = nil
            return
        }

        let directory = root.appendingPathComponent(
            Self.directoryName, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent().path == root.path else {
            authorized = false
            directoryURL = nil
            return
        }
        do {
            if fileManager.fileExists(atPath: directory.path) {
                guard LiveTestHooks.isOwnerOnlyArtifactRoot(
                    directory, currentUserID: configuration.currentUserID) else {
                    authorized = false
                    directoryURL = nil
                    return
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            guard LiveTestHooks.isOwnerOnlyArtifactRoot(
                directory, currentUserID: configuration.currentUserID) else {
                authorized = false
                directoryURL = nil
                return
            }
            authorized = true
            directoryURL = directory
        } catch {
            authorized = false
            directoryURL = nil
        }
    }

    var isEnabled: Bool { authorized }

    /// Starts a new per-call stream. `sessionID` is safe product metadata; a
    /// second random identifier keeps diagnostic correlation independent of
    /// saved-session filenames.
    @discardableResult
    func beginCall(sessionID: String, fields: [String: Any] = [:]) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard authorized, let directoryURL,
              LiveTestHooks.isOwnerOnlyArtifactRoot(
                directoryURL, currentUserID: currentUserID) else { return nil }

        if activeFileURL != nil {
            appendLocked(event: "call_replaced", fields: ["reason": "new_call"])
        }
        activeCallID = UUID().uuidString.lowercased()
        activeSessionID = String(sessionID.prefix(128))
        eventSequence = 0
        eventCount = 0
        droppedEventCount = 0
        bytesWritten = 0

        rotateLocked(in: directoryURL)
        let filename = "call-\(activeCallID!).jsonl"
        let fileURL = directoryURL.appendingPathComponent(filename)
        guard createOwnerOnlyFile(fileURL) else {
            activeCallID = nil
            activeSessionID = nil
            activeFileURL = nil
            activeRelativePath = nil
            return nil
        }
        activeFileURL = fileURL
        activeRelativePath = "\(Self.directoryName)/\(filename)"
        appendLocked(event: "call_started", fields: fields)
        return activeCallID
    }

    func record(event: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(event: event, fields: fields)
    }

    func endCall(fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard activeFileURL != nil else { return }
        appendLocked(event: "call_ended", fields: fields)
        activeFileURL = nil
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            enabled: authorized,
            callID: activeCallID,
            sessionID: activeSessionID,
            relativePath: activeRelativePath,
            eventCount: eventCount,
            droppedEventCount: droppedEventCount,
            bytesWritten: bytesWritten)
    }

    private static func optedIn(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "yes", "on"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func appendLocked(event: String, fields: [String: Any]) {
        guard authorized, let fileURL = activeFileURL else { return }
        eventSequence &+= 1
        let safeEvent = Self.sanitizeString(
            event, maximumBytes: min(128, limits.maximumStringBytes))
        let safeFields = sanitize(fields, depth: 0) as? [String: Any] ?? [:]
        var object: [String: Any] = [
            "schemaVersion": 1,
            "timestamp": Date().timeIntervalSince1970,
            "sequence": eventSequence,
            "callID": activeCallID ?? "",
            "sessionID": activeSessionID ?? "",
            "event": safeEvent,
            "fields": safeFields,
        ]
        guard var data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else {
            droppedEventCount &+= 1
            return
        }
        if data.count + 1 > limits.maximumEventBytes {
            object["fields"] = [
                "payloadTruncated": true,
                "originalBytes": data.count,
                "fieldNames": Array(safeFields.keys.sorted().prefix(
                    limits.maximumCollectionItems)),
            ]
            guard let replacement = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else {
                droppedEventCount &+= 1
                return
            }
            data = replacement
        }
        data.append(0x0A)
        guard data.count <= limits.maximumEventBytes,
              bytesWritten + data.count <= limits.maximumFileBytes,
              appendOwnerOnly(data, to: fileURL) else {
            droppedEventCount &+= 1
            return
        }
        bytesWritten += data.count
        eventCount &+= 1
    }

    private func sanitize(_ value: Any, depth: Int, key: String? = nil) -> Any {
        if let key, Self.isSecretKey(key) { return "[REDACTED]" }
        guard depth < 8 else { return "[TRUNCATED:depth]" }
        switch value {
        case let value as String:
            return Self.sanitizeString(value, maximumBytes: limits.maximumStringBytes)
        case let value as [String: Any]:
            var result: [String: Any] = [:]
            for entry in value.sorted(by: { $0.key < $1.key })
                .prefix(limits.maximumCollectionItems) {
                result[entry.key] = sanitize(
                    entry.value, depth: depth + 1, key: entry.key)
            }
            if value.count > limits.maximumCollectionItems {
                result["_truncatedItems"] = value.count - limits.maximumCollectionItems
            }
            return result
        case let value as [Any]:
            var result = value.prefix(limits.maximumCollectionItems).map {
                sanitize($0, depth: depth + 1)
            }
            if value.count > limits.maximumCollectionItems {
                result.append("[TRUNCATED:\(value.count - limits.maximumCollectionItems) items]")
            }
            return result
        case let value as URL:
            return Self.sanitizeString(value.absoluteString, maximumBytes: limits.maximumStringBytes)
        case let value as Date:
            return value.timeIntervalSince1970
        case is NSNull, is Bool, is Int, is Int8, is Int16, is Int32, is Int64,
             is UInt, is UInt8, is UInt16, is UInt32, is UInt64, is Double,
             is Float, is NSNumber:
            return value
        default:
            return Self.sanitizeString(
                String(describing: value), maximumBytes: limits.maximumStringBytes)
        }
    }

    private static func isSecretKey(_ raw: String) -> Bool {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return key == "token"
            || key == "credential"
            || key == "credentials"
            || key == "cookie"
            || key == "setcookie"
            || key == "password"
            || key == "authorization"
            || key == "accesstoken"
            || key == "refreshtoken"
            || key == "idtoken"
            || key == "bearertoken"
            || key == "apikey"
            || key == "clientsecret"
            || key == "privatekey"
            || key.hasSuffix("accesstoken")
            || key.hasSuffix("refreshtoken")
            || key.hasSuffix("apikey")
            || key.hasSuffix("clientsecret")
            || key.hasSuffix("privatekey")
    }

    private static let sensitivePatterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer [REDACTED]"),
            (#"(?i)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|client[_-]?secret|authorization|password)\b(\s*[:=]\s*)(?:Bearer\s+)?[\"']?[^\s,;\"']{4,}"#, "$1$2[REDACTED]"),
            (#"(?i)\b(?:sk-(?:proj-)?|xox[baprs]-|gh[pousr]_|AIza|ya29\.)[A-Za-z0-9._-]{6,}"#, "[REDACTED]"),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED]"),
            (#"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
        ]
        return specs.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()

    static func sanitizeString(_ raw: String, maximumBytes: Int) -> String {
        var value = raw
        for (regex, replacement) in sensitivePatterns {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(
                in: value, range: range, withTemplate: replacement)
        }
        guard value.utf8.count > maximumBytes else { return value }
        let marker = "\n[TRUNCATED]"
        let budget = max(0, maximumBytes - marker.utf8.count)
        let prefix = String(decoding: value.utf8.prefix(budget), as: UTF8.self)
        return prefix + marker
    }

    private func createOwnerOnlyFile(_ url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { return false }
        return ownerOnlyRegularFile(descriptor)
    }

    private func appendOwnerOnly(_ data: Data, to url: URL) -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard ownerOnlyRegularFile(descriptor) else { return false }
        let wroteAll = data.withUnsafeBytes { buffer -> Bool in
            guard var pointer = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        return wroteAll && fsync(descriptor) == 0
    }

    private func ownerOnlyRegularFile(_ descriptor: Int32) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == currentUserID,
              status.st_mode & 0o077 == 0,
              status.st_mode & 0o600 == 0o600 else { return false }
        return true
    }

    private func rotateLocked(in directory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        let candidates = contents.filter {
            $0.lastPathComponent.hasPrefix("call-") && $0.pathExtension == "jsonl"
                && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
        }.sorted {
            let lhs = (try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        let removeCount = max(0, candidates.count - limits.maximumFiles + 1)
        for file in candidates.prefix(removeCount) {
            try? fileManager.removeItem(at: file)
        }
    }
}
