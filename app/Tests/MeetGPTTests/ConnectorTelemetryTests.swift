import Foundation
import MCP
import Testing
@testable import MeetGPT

private final class ConnectorTelemetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 10_000

    var value: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        storedValue += seconds
        lock.unlock()
    }
}

@MainActor
private final class ConnectorTelemetryIDSequence {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        values.isEmpty
            ? "ffffffff-ffff-ffff-ffff-ffffffffffff"
            : values.removeFirst()
    }
}

private struct ConnectorFixtureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite("Privacy-safe connector telemetry")
struct ConnectorTelemetryTests {
    private struct FailureScenario {
        let label: String
        let error: any Error
        let expected: ConnectorTelemetryRecord.StatusCategory
        let retryEligible: Bool
    }

    private func server(_ id: String = "notion") -> MCPServerDescriptor {
        MCPCatalog.providerContracts.first { $0.id == id }!.descriptor
    }

    private func harness(
        requestIDs: [String] = ["00000000-0000-0000-0000-000000000001"],
        toolCall: @escaping MCPConnectionManager.ToolCallOverride
    ) -> (MCPConnectionManager, InMemoryConnectorTelemetrySink, ConnectorTelemetryClock) {
        let sink = InMemoryConnectorTelemetrySink()
        let clock = ConnectorTelemetryClock()
        let ids = ConnectorTelemetryIDSequence(requestIDs)
        let telemetry = ConnectorTelemetry(
            sink: sink,
            now: { clock.value },
            requestID: { ids.next() })
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            toolCallOverride: toolCall,
            connectorTelemetry: telemetry)
        return (manager, sink, clock)
    }

    @Test("timeout, offline, 401, 429, 5xx, and malformed connector results emit bounded status and retry telemetry")
    func failureStatusMatrixAndRetryEligibility() async {
        let privateErrorCanary = "ERROR_TEXT_MUST_NOT_ENTER_TELEMETRY"
        let scenarios: [FailureScenario] = [
            FailureScenario(
                label: "timeout",
                error: URLError(.timedOut),
                expected: .timeout,
                retryEligible: true),
            FailureScenario(
                label: "offline",
                error: URLError(.notConnectedToInternet),
                expected: .offline,
                retryEligible: true),
            FailureScenario(
                label: "401",
                error: ConnectorFixtureFailure(
                    message: "HTTP 401 unauthorized \(privateErrorCanary)"),
                expected: .unauthorized,
                retryEligible: false),
            FailureScenario(
                label: "429",
                error: ConnectorFixtureFailure(
                    message: "HTTP 429 too many requests \(privateErrorCanary)"),
                expected: .rateLimited,
                retryEligible: true),
            FailureScenario(
                label: "5xx",
                error: ConnectorFixtureFailure(
                    message: "Server error: 503 \(privateErrorCanary)"),
                expected: .serverError,
                retryEligible: true),
            FailureScenario(
                label: "malformed",
                error: MCPError.parseError(privateErrorCanary),
                expected: .malformedResponse,
                retryEligible: false),
        ]

        for (index, scenario) in scenarios.enumerated() {
            var clock: ConnectorTelemetryClock!
            let (manager, sink, createdClock) = harness(
                requestIDs: [String(
                    format: "00000000-0000-0000-0000-%012d", index + 1)]) { _, _, _ in
                    clock.advance(0.125)
                    throw scenario.error
                }
            clock = createdClock

            do {
                _ = try await manager.callToolText(
                    server: server(),
                    tool: "search_records",
                    arguments: ["query": .string("PRIVATE_QUERY")],
                    telemetryContext: ConnectorTelemetryContext(
                        cacheResult: .miss,
                        retryCount: 2))
                Issue.record("\(scenario.label) fixture unexpectedly succeeded")
            } catch {
                // The transport error remains available to product error UI;
                // only the telemetry projection is privacy-minimal.
            }

            #expect(sink.records.count == 1)
            guard let event = sink.records.first else { continue }
            #expect(event.operation == .toolCall)
            #expect(event.providerID == "notion")
            #expect(event.providerCategory == .document)
            #expect(event.toolClass == .read)
            #expect(event.cacheResult == .miss)
            #expect(event.cacheAgeMilliseconds == nil)
            #expect(event.status == scenario.expected, "\(scenario.label)")
            #expect(event.elapsedMilliseconds == 125)
            #expect(event.retryCount == 2)
            #expect(event.retryEligible == scenario.retryEligible)
            #expect(!sink.renderedLog.contains(privateErrorCanary))
        }
    }

    @Test("reconnect failure then success carries retry ordinal and eligibility")
    func reconnectFailureThenSuccessTelemetry() async {
        let sink = InMemoryConnectorTelemetrySink()
        let clock = ConnectorTelemetryClock()
        let ids = ConnectorTelemetryIDSequence([
            "10000000-0000-0000-0000-000000000001",
            "10000000-0000-0000-0000-000000000002",
        ])
        let telemetry = ConnectorTelemetry(
            sink: sink,
            now: { clock.value },
            requestID: { ids.next() })
        var attempt = 0
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter(),
            connectionAttemptOverride: { _ in
                attempt += 1
                clock.advance(0.050)
                if attempt == 1 { throw URLError(.notConnectedToInternet) }
                return []
            },
            connectorTelemetry: telemetry)

        await manager.connect(server())
        await manager.connect(server())

        #expect(sink.records.count == 2)
        #expect(sink.records[0].operation == .reconnect)
        #expect(sink.records[0].status == .reconnectFailed)
        #expect(sink.records[0].retryCount == 0)
        #expect(sink.records[0].retryEligible)
        #expect(sink.records[0].elapsedMilliseconds == 50)
        #expect(sink.records[1].status == .reconnectSucceeded)
        #expect(sink.records[1].retryCount == 1)
        #expect(!sink.records[1].retryEligible)
        #expect(sink.records[1].elapsedMilliseconds == 50)
        #expect(manager.state(of: "notion") == .connected(toolCount: 0))
    }

    @Test("cache hits and stale fallbacks report result and age without cached content")
    func cacheResultAndAgeTelemetry() async {
        let cachedContentCanary = "IMPORTED_CONTENT_MUST_NOT_ENTER_TELEMETRY"
        let cacheClock = ConnectorTelemetryClock()
        let cache = MCPResultCache(now: { Date(timeIntervalSince1970: cacheClock.value) })
        let key = MCPResultCache.key(
            sourceID: "mcp:notion",
            tool: "search",
            query: "PRIVATE_QUERY_MUST_NOT_ENTER_TELEMETRY")
        await cache.store(key, text: cachedContentCanary, serverID: "notion")

        let (manager, sink, _) = harness(
            requestIDs: [
                "20000000-0000-0000-0000-000000000001",
                "20000000-0000-0000-0000-000000000002",
            ]) { _, _, _ in "unused" }

        cacheClock.advance(12.345)
        let fresh = await cache.fresh(key)
        manager.recordConnectorCacheTelemetry(
            server: server(),
            toolName: "search",
            requestID: "20000000-0000-0000-0000-000000000001",
            result: .freshHit,
            age: fresh?.age,
            retryCount: 0)

        cacheClock.advance(MCPResultCache.defaultTTL)
        let stale = await cache.stale(key)
        manager.recordConnectorCacheTelemetry(
            server: server(),
            toolName: "search",
            requestID: "20000000-0000-0000-0000-000000000002",
            result: .staleFallback,
            age: stale?.age,
            retryCount: 3)

        #expect(sink.records.map(\.cacheResult) == [.freshHit, .staleFallback])
        #expect(sink.records.allSatisfy { $0.toolClass == .read })
        #expect(sink.records[0].cacheAgeMilliseconds == 12_345)
        #expect(sink.records[1].cacheAgeMilliseconds == 312_345)
        #expect(sink.records[1].retryCount == 3)
        #expect(!sink.renderedLog.contains(cachedContentCanary))
        #expect(!sink.renderedLog.contains("PRIVATE_QUERY_MUST_NOT_ENTER_TELEMETRY"))
    }

    @Test("read, write, and destructive tools emit class only")
    func toolSafetyClassificationOnly() async throws {
        var clock: ConnectorTelemetryClock!
        let rawToolNames = [
            "search_PRIVATE_READ_CANARY",
            "create_PRIVATE_WRITE_CANARY",
            "delete_PRIVATE_DESTRUCTIVE_CANARY",
        ]
        let (manager, sink, createdClock) = harness(
            requestIDs: [
                "30000000-0000-0000-0000-000000000001",
                "30000000-0000-0000-0000-000000000002",
                "30000000-0000-0000-0000-000000000003",
            ]) { _, _, _ in
                clock.advance(0.001)
                return "accepted"
            }
        clock = createdClock

        for tool in rawToolNames {
            _ = try await manager.callToolText(
                server: server(), tool: tool, arguments: nil)
        }

        #expect(sink.records.map(\.toolClass) == [.read, .write, .destructive])
        for tool in rawToolNames {
            #expect(!sink.renderedLog.contains(tool))
        }
    }

    @Test("connector telemetry records and log rendering exclude tokens, queries, imported content, arguments, tool names, and error text")
    func secretCanariesNeverReachRecordsOrLogRendering() async {
        let token = "TOKEN_CANARY_9f761"
        let query = "QUERY_CANARY_launch_pricing"
        let imported = "IMPORTED_CONTENT_CANARY_customer_contract"
        let argument = "ARGUMENT_CANARY_private_team_id"
        let errorText = "ERROR_CANARY_provider_payload"
        let rawTool = "create_SECRET_TOOL_CANARY_record"
        let custom = MCPServerDescriptor(
            id: "custom-\(token)",
            name: "Private \(query)",
            endpoint: URL(string: "https://example.invalid/\(imported)")!,
            symbol: "puzzlepiece.extension",
            isCustom: true)
        var call = 0
        let (manager, sink, _) = harness(
            requestIDs: [
                "40000000-0000-0000-0000-000000000001",
                "40000000-0000-0000-0000-000000000002",
            ]) { _, _, _ in
                call += 1
                if call == 1 { return imported }
                throw ConnectorFixtureFailure(
                    message: "Server error: 503 \(errorText) \(token) \(query)")
            }
        let secretArguments: [String: Value] = [
            "authorization": .string(token),
            "query": .string(query),
            "team_id": .string(argument),
            "content": .string(imported),
        ]

        _ = try? await manager.callToolText(
            server: custom, tool: rawTool, arguments: secretArguments)
        _ = try? await manager.callToolText(
            server: custom, tool: rawTool, arguments: secretArguments)

        #expect(sink.records.count == 2)
        #expect(sink.records.allSatisfy { $0.providerID == "custom" })
        #expect(sink.records.allSatisfy { $0.providerCategory == .custom })
        #expect(sink.records.allSatisfy { $0.toolClass == .write })
        #expect(sink.records.map(\.status) == [.success, .serverError])

        let recordRendering = sink.records.map(String.init(describing:)).joined(separator: "\n")
        let allRendering = sink.renderedLog + "\n" + recordRendering
        for canary in [token, query, imported, argument, errorText, rawTool,
                       "authorization", "team_id", "content"] {
            #expect(!allRendering.contains(canary), "telemetry leaked \(canary)")
        }

        // Exact stable markers consumed by local diagnostics/manifest proof.
        for marker in [
            "event=connector_operation",
            "operation=tool_call",
            "request_id=40000000-0000-0000-0000-000000000001",
            "provider_id=custom",
            "provider_category=custom",
            "tool_class=write",
            "cache_result=not_applicable",
            "cache_age_ms=none",
            "status=success",
            "elapsed_ms=0",
            "retry_count=0",
            "retry_eligible=false",
        ] {
            #expect(sink.renderedLog.contains(marker), "missing marker \(marker)")
        }
    }
}
