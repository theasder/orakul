import Foundation
import Testing
@testable import MeetGPT

/// ChatGPT and Claude expose no API to read a user's conversations, so the only
/// sanctioned path is the user's own data export. Both ship a `conversations.json`
/// with completely different shapes — ChatGPT stores a message TREE, Claude a
/// flat list — and both are named the same, so detection is by shape.
@Suite("Chat export import")
struct ChatExportImporterTests {

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    /// ChatGPT: `mapping` is a dict of nodes keyed by uuid, each holding a message
    /// with `author.role` and `content.parts`. Order comes from `create_time`.
    private func chatGPTExport(title: String = "Pricing model",
                               extra: [[String: Any]] = []) -> Data {
        var conversations: [[String: Any]] = [[
            "title": title,
            "create_time": 1_750_000_000.0,
            "mapping": [
                "n2": ["id": "n2", "message": [
                    "author": ["role": "assistant"],
                    "create_time": 1_750_000_100.0,
                    "content": ["content_type": "text", "parts": ["Usage-based scales better."]],
                ]],
                "n1": ["id": "n1", "message": [
                    "author": ["role": "user"],
                    "create_time": 1_750_000_050.0,
                    "content": ["content_type": "text", "parts": ["Per-seat or usage-based?"]],
                ]],
                "sys": ["id": "sys", "message": [
                    "author": ["role": "system"],
                    "create_time": 1_750_000_000.0,
                    "content": ["content_type": "text", "parts": ["You are ChatGPT."]],
                ]],
            ],
        ]]
        conversations.append(contentsOf: extra)
        return json(conversations)
    }

    private func claudeExport() -> Data {
        json([[
            "uuid": "c1",
            "name": "Retention plan",
            "created_at": "2026-07-01T10:00:00Z",
            "chat_messages": [
                ["sender": "human", "text": "Why is NRR slipping?"],
                ["sender": "assistant", "content": [["type": "text", "text": "Expansion stalled."]]],
            ],
        ]])
    }

    @Test("parses a ChatGPT export into ordered, readable turns")
    func parsesChatGPT() throws {
        let result = try #require(ChatExportImporter.parse(chatGPTExport()))
        #expect(result.source == .chatGPT)

        let text = result.text
        #expect(text.contains("Pricing model"))
        #expect(text.contains("User: Per-seat or usage-based?"))
        #expect(text.contains("Assistant: Usage-based scales better."))

        // The tree is unordered in JSON; create_time decides the sequence.
        let user = try #require(text.range(of: "Per-seat or usage-based?"))
        let assistant = try #require(text.range(of: "Usage-based scales better."))
        #expect(user.lowerBound < assistant.lowerBound)
    }

    @Test("drops the system preamble, which is never meeting context")
    func dropsSystemMessages() throws {
        let result = try #require(ChatExportImporter.parse(chatGPTExport()))
        #expect(!result.text.contains("You are ChatGPT"))
    }

    @Test("parses a Claude export, including block-style content")
    func parsesClaude() throws {
        let result = try #require(ChatExportImporter.parse(claudeExport()))
        #expect(result.source == .claude)
        #expect(result.text.contains("Retention plan"))
        #expect(result.text.contains("User: Why is NRR slipping?"))
        // `content: [{type,text}]` must be flattened, not skipped.
        #expect(result.text.contains("Assistant: Expansion stalled."))
    }

    @Test("returns nil for JSON that is not a chat export, so the caller falls back")
    func rejectsUnrelatedJSON() {
        #expect(ChatExportImporter.parse(json(["hello": "world"])) == nil)
        #expect(ChatExportImporter.parse(json([["id": 1, "name": "not a chat"]])) == nil)
        #expect(ChatExportImporter.parse(Data("not json".utf8)) == nil)
        #expect(ChatExportImporter.parse(json([])) == nil)
    }

    @Test("keeps the newest conversations and says how many it dropped")
    func capsByRecencyAndSaysSo() throws {
        // 60 extra conversations, oldest first, past the 40 cap.
        let extra: [[String: Any]] = (0..<60).map { index in
            [
                "title": "Old thread \(index)",
                "create_time": Double(1_700_000_000 + index),
                "mapping": ["m": ["id": "m", "message": [
                    "author": ["role": "user"],
                    "create_time": Double(1_700_000_000 + index),
                    "content": ["content_type": "text", "parts": ["filler"]],
                ]]],
            ]
        }
        let result = try #require(ChatExportImporter.parse(chatGPTExport(extra: extra)))

        #expect(result.text.contains("of 61 conversations"))
        // The newest (create_time 1.75e9) must survive; the oldest must not.
        #expect(result.text.contains("Pricing model"))
        #expect(!result.text.contains("Old thread 0"))
        // The user must be told, not silently given a partial view.
        #expect(result.text.contains("Older conversations are NOT included"))
    }

    @Test("clips a single enormous message instead of blowing the budget")
    func clipsLongMessages() throws {
        let huge = String(repeating: "x", count: 10_000)
        let data = json([[
            "uuid": "c1", "name": "Log dump", "created_at": "2026-07-01T10:00:00Z",
            "chat_messages": [["sender": "human", "text": huge]],
        ]])
        let result = try #require(ChatExportImporter.parse(data))
        #expect(result.text.contains("[…]"))
        #expect(result.text.count < 10_000)
    }

    @Test("total output stays within the context budget")
    func respectsTotalBudget() throws {
        let big: [[String: Any]] = (0..<40).map { index in
            [
                "title": "Thread \(index)",
                "create_time": Double(1_760_000_000 + index),
                "mapping": ["m": ["id": "m", "message": [
                    "author": ["role": "user"],
                    "create_time": Double(1_760_000_000 + index),
                    "content": ["content_type": "text",
                                "parts": [String(repeating: "y", count: 1_900)]],
                ]]],
            ]
        }
        let result = try #require(ChatExportImporter.parse(json(big)))
        #expect(result.text.count <= ChatExportImporter.maxCharacters + 1_000)
    }
}
