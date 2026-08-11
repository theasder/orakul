import Foundation
import MCP

/// Privacy-minimal structured telemetry for one connected-app operation.
///
/// This deliberately has no free-form string fields other than two identifiers
/// that are constrained below. Tool names are reduced to a safety class before
/// storage; arguments, query text, result content, URLs, credentials, and error
/// descriptions have nowhere to enter the record.
struct ConnectorTelemetryRecord: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case toolCall = "tool_call"
        case cacheLookup = "cache_lookup"
        case reconnect
    }

    enum ProviderCategory: String, Equatable, Sendable {
        case document
        case meeting
        case tracker
        case support
        case observability
        case automation
        case crm
        case analytics
        case communication
        case custom
        case other
    }

    enum ToolClass: String, Equatable, Sendable {
        case read
        case write
        case destructive
        /// Reconnect/cache operations do not invoke a tool.
        case none

        static func classify(_ toolName: String) -> Self {
            let normalized = toolName
                .replacingOccurrences(
                    of: "([a-z0-9])([A-Z])",
                    with: "$1_$2",
                    options: .regularExpression)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            let tokens = Set(normalized.split(separator: "_").map(String.init))
            let destructive = Set([
                "delete", "remove", "archive", "close", "cancel", "revoke",
                "drop", "purge", "trash",
            ])
            if !tokens.isDisjoint(with: destructive) { return .destructive }
            // Conservative: if a compound name contains any mutation verb
            // (`get_or_create_page`), classify the whole operation as a write.
            let write = Set([
                "create", "add", "send", "post", "append", "file", "schedule",
                "assign", "comment", "insert", "publish", "draft", "log", "record",
                "update", "modify", "set", "upsert",
            ])
            return tokens.isDisjoint(with: write) ? .read : .write
        }
    }

    enum CacheResult: String, Equatable, Sendable {
        case notApplicable = "not_applicable"
        case miss
        case freshHit = "fresh_hit"
        case staleFallback = "stale_fallback"
        case circuitOpen = "circuit_open"
    }

    enum StatusCategory: String, Equatable, Sendable {
        case success
        case timeout
        case offline
        case unauthorized
        case rateLimited = "rate_limited"
        case serverError = "server_error"
        case malformedResponse = "malformed_response"
        case reconnectSucceeded = "reconnect_succeeded"
        case reconnectFailed = "reconnect_failed"
        case canceled
        case otherFailure = "other_failure"

        var isRetryEligible: Bool {
            switch self {
            case .timeout, .offline, .rateLimited, .serverError, .reconnectFailed:
                return true
            case .success, .unauthorized, .malformedResponse,
                    .reconnectSucceeded, .canceled, .otherFailure:
                return false
            }
        }

        static func classify(_ error: Error) -> Self {
            if error is CancellationError { return .canceled }

            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    return .timeout
                case .notConnectedToInternet, .networkConnectionLost,
                        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                        .internationalRoamingOff, .dataNotAllowed:
                    return .offline
                case .userAuthenticationRequired:
                    return .unauthorized
                default:
                    break
                }
            }

            if let mcpError = error as? MCPError {
                switch mcpError {
                case .parseError:
                    return .malformedResponse
                case .connectionClosed:
                    return .offline
                case .transportError(let underlying):
                    return classify(underlying)
                default:
                    break
                }
            }

            if error is DecodingError { return .malformedResponse }

            // SDK transport errors preserve only a bounded description for
            // several HTTP failures. Inspect it for classification, then drop
            // it completely—the value is never copied into a telemetry record.
            let message = error.localizedDescription.lowercased()
            if message.contains("timed out") || message.contains("timeout")
                || containsHTTPStatus(in: message, range: 408...408) {
                return .timeout
            }
            if message.contains("offline") || message.contains("not connected")
                || message.contains("network connection") || message.contains("connection closed")
                || message.contains("cannot connect") {
                return .offline
            }
            if message.contains("unauthorized") || message.contains("authentication required")
                || message.contains("invalid_grant") || message.contains("invalid grant")
                || containsHTTPStatus(in: message, range: 401...403) {
                return .unauthorized
            }
            if message.contains("too many requests") || message.contains("rate limit")
                || containsHTTPStatus(in: message, range: 429...429) {
                return .rateLimited
            }
            if message.contains("parse error") || message.contains("invalid json")
                || message.contains("malformed") || message.contains("decoding") {
                return .malformedResponse
            }
            if message.contains("server error") || containsHTTPStatus(in: message, range: 500...599) {
                return .serverError
            }
            return .otherFailure
        }

        private static func containsHTTPStatus(in message: String,
                                               range: ClosedRange<Int>) -> Bool {
            for status in range where message.range(
                of: "\\b\(status)\\b", options: .regularExpression) != nil {
                return true
            }
            return false
        }
    }

    let operation: Operation
    let requestID: String
    let providerID: String
    let providerCategory: ProviderCategory
    let toolClass: ToolClass
    let cacheResult: CacheResult
    let cacheAgeMilliseconds: Int?
    let status: StatusCategory
    let elapsedMilliseconds: Int
    let retryCount: Int
    let retryEligible: Bool

    /// Stable key=value rendering for unified logs and deterministic assertions.
    /// Every value comes from a closed enum, bounded integer, or constrained ID.
    var logLine: String {
        [
            "event=connector_operation",
            "operation=\(operation.rawValue)",
            "request_id=\(requestID)",
            "provider_id=\(providerID)",
            "provider_category=\(providerCategory.rawValue)",
            "tool_class=\(toolClass.rawValue)",
            "cache_result=\(cacheResult.rawValue)",
            "cache_age_ms=\(cacheAgeMilliseconds.map(String.init) ?? "none")",
            "status=\(status.rawValue)",
            "elapsed_ms=\(elapsedMilliseconds)",
            "retry_count=\(retryCount)",
            "retry_eligible=\(retryEligible)",
        ].joined(separator: " ")
    }
}

/// Non-sensitive call metadata supplied by higher connector layers. There are
/// intentionally no query, argument, result, token, or error fields.
struct ConnectorTelemetryContext: Equatable, Sendable {
    var requestID: String?
    var cacheResult: ConnectorTelemetryRecord.CacheResult
    var cacheAgeMilliseconds: Int?
    var retryCount: Int

    init(requestID: String? = nil,
         cacheResult: ConnectorTelemetryRecord.CacheResult = .notApplicable,
         cacheAgeMilliseconds: Int? = nil,
         retryCount: Int = 0) {
        self.requestID = requestID
        self.cacheResult = cacheResult
        self.cacheAgeMilliseconds = cacheAgeMilliseconds
        self.retryCount = max(0, retryCount)
    }
}

@MainActor
protocol ConnectorTelemetrySink: AnyObject {
    func record(_ event: ConnectorTelemetryRecord)
}

/// Test sink; it never writes to disk, network, Console, or analytics services.
@MainActor
final class InMemoryConnectorTelemetrySink: ConnectorTelemetrySink {
    private(set) var records: [ConnectorTelemetryRecord] = []

    func record(_ event: ConnectorTelemetryRecord) {
        records.append(event)
    }

    var renderedLog: String {
        records.map(\.logLine).joined(separator: "\n")
    }
}

/// Production sink: local structured unified logging only. `logLine` is safe to
/// mark public because its type cannot contain connector payload or error text.
@MainActor
private final class UnifiedLogConnectorTelemetrySink: ConnectorTelemetrySink {
    static let shared = UnifiedLogConnectorTelemetrySink()

    func record(_ event: ConnectorTelemetryRecord) {
        Log.network.info("\(event.logLine, privacy: .public)")
    }
}

/// Clock/ID-injectable recorder shared by MCP connection, call, and cache paths.
@MainActor
final class ConnectorTelemetry {
    static let live = ConnectorTelemetry(sink: UnifiedLogConnectorTelemetrySink.shared)

    private let sink: any ConnectorTelemetrySink
    private let now: () -> TimeInterval
    private let requestID: () -> String

    init(sink: any ConnectorTelemetrySink,
         now: @escaping () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         },
         requestID: @escaping () -> String = { UUID().uuidString }) {
        self.sink = sink
        self.now = now
        self.requestID = requestID
    }

    func makeRequestID() -> String {
        Self.safeRequestID(requestID())
    }

    func start() -> TimeInterval { now() }

    @discardableResult
    func record(operation: ConnectorTelemetryRecord.Operation,
                server: MCPServerDescriptor,
                toolName: String? = nil,
                context: ConnectorTelemetryContext = ConnectorTelemetryContext(),
                status: ConnectorTelemetryRecord.StatusCategory,
                startedAt: TimeInterval,
                retryEligible: Bool? = nil) -> ConnectorTelemetryRecord {
        let event = ConnectorTelemetryRecord(
            operation: operation,
            requestID: Self.safeRequestID(context.requestID ?? makeRequestID()),
            providerID: Self.safeProviderID(server),
            providerCategory: Self.providerCategory(server),
            toolClass: toolName.map(ConnectorTelemetryRecord.ToolClass.classify) ?? .none,
            cacheResult: context.cacheResult,
            cacheAgeMilliseconds: context.cacheAgeMilliseconds.map { max(0, $0) },
            status: status,
            elapsedMilliseconds: max(0, Int(((now() - startedAt) * 1_000).rounded())),
            retryCount: max(0, context.retryCount),
            retryEligible: retryEligible ?? status.isRetryEligible)
        sink.record(event)
        return event
    }

    private static func safeRequestID(_ value: String) -> String {
        guard let uuid = UUID(uuidString: value) else { return "invalid" }
        return uuid.uuidString.lowercased()
    }

    private static func safeProviderID(_ server: MCPServerDescriptor) -> String {
        guard !server.isCustom else { return "custom" }
        let id = server.id.lowercased()
        let known = Set(MCPCatalog.providerContracts.map(\.id))
        return known.contains(id) ? id : "unknown"
    }

    private static func providerCategory(
        _ server: MCPServerDescriptor
    ) -> ConnectorTelemetryRecord.ProviderCategory {
        if server.isCustom { return .custom }
        switch server.id.lowercased() {
        case "notion": return .document
        case "fireflies", "zoom": return .meeting
        case "linear", "asana", "atlassian": return .tracker
        case "intercom": return .support
        case "sentry": return .observability
        case "zapier": return .automation
        case "attio", "hubspot", "affinity": return .crm
        case "posthog", "amplitude", "mixpanel", "google-analytics": return .analytics
        case "gmail": return .communication
        default: return .other
        }
    }
}
