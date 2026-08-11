import Darwin
import Foundation
import Testing
@testable import MeetGPT

private final class DiagnosticLLMGateway: LLMGateway, @unchecked Sendable {
    func streamChat(system: String, user: String, images: [Data], model: LLMModel,
                    onDelta: @escaping (String) -> Void) async throws -> String {
        let response = "Use OpenRouter failover and verify the completed workflow."
        onDelta(response)
        return response
    }
}

@MainActor
@Suite("Dev call diagnostics")
struct DevCallDiagnosticsTests {
    private let nonce = String(repeating: "a", count: 64)

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cruxwing-dev-call-diagnostics-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func logger(root: URL,
                        isDevBuild: Bool = true,
                        enabled: String? = "1",
                        limits: DevCallDiagnostics.Limits = .init()) -> DevCallDiagnostics {
        DevCallDiagnostics(
            configuration: .init(
                isDevBuild: isDevBuild,
                enabledValue: enabled,
                nonce: nonce,
                artifactRoot: root),
            limits: limits)
    }

    private func logFiles(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent(
            DevCallDiagnostics.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
    }

    @Test("production and opt-out gates create no diagnostic artifact")
    func disabledGatesWriteNothing() throws {
        let productionRoot = try makeRoot()
        let optOutRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: productionRoot)
            try? FileManager.default.removeItem(at: optOutRoot)
        }

        let production = logger(root: productionRoot, isDevBuild: false)
        let optOut = logger(root: optOutRoot, enabled: "0")
        #expect(!production.isEnabled)
        #expect(!optOut.isEnabled)
        #expect(production.beginCall(sessionID: "prod") == nil)
        #expect(optOut.beginCall(sessionID: "off") == nil)
        production.record(event: "assistant_request", fields: ["prompt": "private"])
        optOut.record(event: "assistant_request", fields: ["prompt": "private"])
        #expect(try logFiles(in: productionRoot).isEmpty)
        #expect(try logFiles(in: optOutRoot).isEmpty)
    }

    @Test("authorized JSONL contains bounded workflow evidence with owner-only modes")
    func writesExpectedOwnerOnlyEvidence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = logger(root: root)
        let callID = try #require(diagnostics.beginCall(
            sessionID: "session-42",
            fields: ["activeTranscriptionEngine": "deepgram"]))
        diagnostics.record(event: "assistant_request", fields: [
            "exchangeID": "exchange-7",
            "requestBody": [
                "system": "System instructions",
                "user": "Transcript plus the user's prompt",
                "selection": "auto:openAI",
                "model": "auto",
            ],
            "estimatedInputTokens": 123,
        ])
        diagnostics.record(event: "workflow_step", fields: [
            "label": "Search Linear", "status": "succeeded",
            "detail": "2 results found",
        ])
        diagnostics.record(event: "assistant_terminal", fields: [
            "response": "The workflow completed with a relevant answer.",
            "provider": "openrouter", "latencyMs": 240,
            "chargedCredits": 2,
        ])
        diagnostics.endCall(fields: ["transcriptEntries": 8])

        let directory = root.appendingPathComponent(
            DevCallDiagnostics.directoryName, isDirectory: true)
        let files = try logFiles(in: root)
        let file = try #require(files.first)
        let directoryMode = try #require((FileManager.default.attributesOfItem(
            atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try #require((FileManager.default.attributesOfItem(
            atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue)
        #expect(directoryMode & 0o777 == 0o700)
        #expect(fileMode & 0o777 == 0o600)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(callID))
        #expect(text.contains("assistant_request"))
        #expect(text.contains("Transcript plus the user's prompt"))
        #expect(text.contains("Search Linear"))
        #expect(text.contains("openrouter"))
        #expect(text.contains("chargedCredits"))
        #expect(text.split(separator: "\n").count == 5)

        let rows = try text.split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any])
        }
        let request = try #require(rows.first {
            $0["event"] as? String == "assistant_request"
        })
        let fields = try #require(request["fields"] as? [String: Any])
        let requestBody = try #require(fields["requestBody"] as? [String: Any])
        #expect(requestBody["selection"] as? String == "auto:openAI")
        #expect(requestBody["model"] as? String == "auto")
    }

    @Test("structured and embedded credentials are redacted before persistence")
    func redactsSecrets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = logger(root: root)
        _ = diagnostics.beginCall(sessionID: "secret-test")
        let jwt = "eyJabcdefghijk.eyJmnopqrstuv.abcdefghijklmnop"
        diagnostics.record(event: "request", fields: [
            "accessToken": "access-secret-123456",
            "nested": [
                "api_key": "sk-proj-supersecret123456",
                "clientSecret": "oauth-client-secret-999",
            ],
            "prompt": "Authorization: Bearer live-bearer-secret-123456 "
                + "refresh_token=refresh-secret-654321 jwt=\(jwt)",
            "private": "-----BEGIN PRIVATE KEY-----\nabc123secret\n-----END PRIVATE KEY-----",
            "inputTokens": 321,
        ])
        diagnostics.endCall()

        let file = try #require(try logFiles(in: root).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in [
            "access-secret-123456", "sk-proj-supersecret123456",
            "oauth-client-secret-999", "live-bearer-secret-123456",
            "refresh-secret-654321", jwt, "abc123secret",
        ] {
            #expect(!text.contains(forbidden))
        }
        #expect(text.contains("[REDACTED]"))
        #expect(text.contains("inputTokens"))
        #expect(text.contains("321"))
    }

    @Test("long calls are bounded and old per-call logs rotate")
    func boundsAndRotates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = logger(
            root: root,
            limits: .init(
                maximumStringBytes: 96,
                maximumEventBytes: 700,
                maximumFileBytes: 1_400,
                maximumFiles: 2,
                maximumCollectionItems: 8))

        for call in 0..<4 {
            _ = diagnostics.beginCall(sessionID: "session-\(call)")
            for event in 0..<20 {
                diagnostics.record(event: "payload", fields: [
                    "index": event,
                    "body": String(repeating: "bounded-\(call)-", count: 80),
                ])
            }
            diagnostics.endCall()
        }

        let files = try logFiles(in: root)
        #expect(files.count == 2)
        for file in files {
            let size = try #require((FileManager.default.attributesOfItem(
                atPath: file.path)[.size] as? NSNumber)?.intValue)
            #expect(size <= 1_400)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("[TRUNCATED]"))
        }
        #expect(diagnostics.snapshot().droppedEventCount > 0)
    }

    @Test("assistant pipeline emits assembled request, workflow, and terminal answer")
    func appStatePipelineIntegration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = logger(root: root)
        _ = diagnostics.beginCall(sessionID: "pipeline-session")
        let state = AppState(
            llm: DiagnosticLLMGateway(), devCallDiagnostics: diagnostics)
        state.transcript = [TranscriptEntry(
            source: .system,
            text: "OpenAI is unavailable, but OpenRouter has sufficient funds.")]

        state.runPrompt(.custom(
            id: "diagnostic-prompt", icon: "sparkles", title: "Advice",
            prompt: "Give advice and explain the provider workflow."))
        await state.aiTask?.value
        for _ in 0..<100 where state.aiStreaming { await Task.yield() }
        diagnostics.endCall()

        let file = try #require(try logFiles(in: root).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("assistant_prompt"))
        #expect(text.contains("assistant_request"))
        #expect(text.contains("workflow_plan"))
        #expect(text.contains("workflow_terminal_snapshot"))
        #expect(text.contains("assistant_terminal"))
        #expect(text.contains("OpenRouter has sufficient funds"))
        #expect(text.contains("Give advice and explain the provider workflow"))
        #expect(text.contains("Use OpenRouter failover"))
    }
}
