import Foundation
import MCP

/// Create a Notion page from an assistant answer via the connected Notion MCP
/// server's create-page tool. Tool name + argument shape are resolved from the
/// server's LIVE schema (mirrors TaskWriteback), so a schema change degrades to
/// "unavailable" instead of a mis-call.
enum NotionExport {
    static let serverID = "notion"

    /// Preferred create-page tool names (hosted Notion MCP first), else the
    /// name heuristic below.
    static let preferredCreateTools = [
        "notion-create-pages", "create-pages", "create_pages",
        "notion-create-page", "create-page", "create_page",
    ]

    static func pickCreateTool(from tools: [Tool]) -> Tool? {
        for name in preferredCreateTools {
            if let tool = tools.first(where: { $0.name == name }) { return tool }
        }
        return tools.first { tool in
            let n = tool.name.lowercased()
            return n.contains("create") && n.contains("page")
        }
    }

    /// Markdown body Notion renders into blocks (headings, bullets). Earlier
    /// archived turns come first, oldest to newest — the page is the dialog,
    /// not just its last answer.
    static func markdown(title: String, date: Date, prompt: String,
                         answer: String, blindSpots: [String],
                         earlierExchanges: [AIExchange] = []) -> String {
        let df = DateFormatter()
        df.locale = DisplayFormatting.locale
        df.dateFormat = "d MMMM yyyy"

        var md = "# \(title)\n\n_orakul · \(df.string(from: date))_\n\n"
        for exchange in earlierExchanges {
            let earlierPrompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !earlierPrompt.isEmpty {
                md += "## Prompt\n\n\(earlierPrompt)\n\n"
            }
            md += "## Answer\n\n\(exchange.answer.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPrompt.isEmpty, cleanPrompt != "Prompt unavailable for this older saved answer." {
            md += "## Prompt\n\n\(cleanPrompt)\n\n"
        }
        md += "## Assistant answer\n\n\(answer.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !blindSpots.isEmpty {
            md += "## Blind spots\n\n"
                + blindSpots.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return md
    }

    /// Build tool arguments from the live schema. Hosted Notion MCP uses a
    /// nested `pages` array (title property + markdown content); simpler servers
    /// expose flat title/content string keys. nil when neither shape fits.
    static func arguments(title: String, content: String, tool: Tool) -> [String: Value]? {
        if tool.hasArgument("pages") {
            return ["pages": .array([
                .object([
                    "properties": .object(["title": .string(title)]),
                    "content": .string(content),
                ]),
            ])]
        }
        guard let titleKey = tool.stringArgumentKey(preferring: ["title", "name"]) else {
            return nil
        }
        var args: [String: Value] = [titleKey: .string(title)]
        for key in ["content", "body", "markdown", "text"] where tool.hasArgument(key) {
            args[key] = .string(content)
            break
        }
        return args
    }
}

extension MCPConnectionManager {
    /// Notion is a usable export target right now: connected + a create-page
    /// tool is present in its live schema.
    var canExportToNotion: Bool {
        isConnected(NotionExport.serverID)
            && NotionExport.pickCreateTool(from: tools(for: NotionExport.serverID)) != nil
    }

    /// Create a Notion page; returns the tool's text result (often the new
    /// page URL).
    func createNotionPage(title: String, content: String) async throws -> String {
        guard let server = servers.first(where: { $0.id == NotionExport.serverID }) else {
            throw MCPConnectionError.notConnected("Notion", nil)
        }
        let tools = tools(for: NotionExport.serverID)
        guard let tool = NotionExport.pickCreateTool(from: tools),
              let args = NotionExport.arguments(title: title, content: content, tool: tool) else {
            throw MCPConnectionError.notConnected("Notion", "no create-page tool available")
        }
        return try await callToolText(server: server, tool: tool.name, arguments: args)
    }
}
