import Foundation
import Testing
import MCP
@testable import MeetGPT

/// DOCX name + blind-spot section, the Google-Docs HTML builder, and the Notion
/// create-page resolution — the three export targets for an assistant answer.
@Suite("Answer export targets")
struct AnswerExportTargetsTests {
    private let date = Date(timeIntervalSince1970: 1_784_000_000)  // 2026-07-13

    // MARK: DOCX

    @Test("filename gains an elegant dated form, bare form unchanged (pinned)")
    func filenameDated() {
        #expect(AssistantDOCXExporter.suggestedFilename(for: "Launch / rollout: owner?")
            == "Launch rollout owner.docx")
        let dated = AssistantDOCXExporter.suggestedFilename(for: "Falcon Budget", date: date)
        #expect(dated.hasPrefix("Falcon Budget — 2026-07-1"))
        #expect(dated.hasSuffix(".docx"))
    }

    @Test("blind spots become a bulleted section in the Word document")
    func docxBlindSpots() throws {
        let doc = AssistantAnswerDocument(
            title: "Sync", prompt: "p", answer: "The answer.", exportedAt: date,
            blindSpots: ["Risk: Budget unraised — flagged twice", "Ask: Who owns rollout?"])
        let parts = AssistantDOCXExporter.packageParts(for: doc)
        let body = String(data: parts.first { $0.name == "word/document.xml" }!.data,
                          encoding: .utf8)!
        #expect(body.contains("Blind spots"))
        #expect(body.contains("Budget unraised"))
        #expect(body.contains("Who owns rollout?"))
        // Rendered as list paragraphs (numId 1 = bullets).
        #expect(body.contains(#"<w:numId w:val="1"/>"#))
    }

    @Test("no blind spots omits the section")
    func docxNoBlindSpots() throws {
        let doc = AssistantAnswerDocument(title: "S", prompt: "p", answer: "a", exportedAt: date)
        let parts = AssistantDOCXExporter.packageParts(for: doc)
        let body = String(data: parts.first { $0.name == "word/document.xml" }!.data,
                          encoding: .utf8)!
        #expect(!body.contains("Blind spots"))
    }

    // MARK: Google Docs HTML

    @Test("HTML builder renders headings, bullets, bold, and escapes markup")
    func googleHTML() {
        let html = AssistantDocHTML.build(
            title: "Q3 <Plan>", date: date, prompt: "Summarize & decide",
            answer: "## Section\n- point **one**\n- point two\n\nA paragraph.",
            blindSpots: ["Risk: cost <not> raised"])
        #expect(html.contains("<h1>Q3 &lt;Plan&gt;</h1>"))          // escaped title
        #expect(html.contains("Summarize &amp; decide"))            // escaped prompt
        #expect(html.contains("<h3>Section</h3>"))
        #expect(html.contains("<li>point <b>one</b></li>"))
        #expect(html.contains("<p>A paragraph.</p>"))
        #expect(html.contains("<li>Risk: cost &lt;not&gt; raised</li>"))
    }

    // MARK: Notion

    @Test("Notion markdown carries prompt, answer, and blind spots")
    func notionMarkdown() {
        let md = NotionExport.markdown(
            title: "Weekly", date: date, prompt: "the prompt",
            answer: "the answer", blindSpots: ["Risk: X"])
        #expect(md.hasPrefix("# Weekly"))
        #expect(md.contains("## Prompt\n\nthe prompt"))
        #expect(md.contains("## Assistant answer\n\nthe answer"))
        #expect(md.contains("## Blind spots\n\n- Risk: X"))
    }

    @Test("create-page tool is picked from the live schema, with nested pages args")
    func notionToolResolution() {
        let createTool = Tool(
            name: "notion-create-pages", description: "Create pages",
            inputSchema: .object(["properties": .object(["pages": .object([:])])]))
        let searchTool = Tool(
            name: "search", description: "Search",
            inputSchema: .object(["properties": .object(["query": .object([:])])]))

        let picked = NotionExport.pickCreateTool(from: [searchTool, createTool])
        #expect(picked?.name == "notion-create-pages")
        // No create tool present → nil (Notion option stays hidden).
        #expect(NotionExport.pickCreateTool(from: [searchTool]) == nil)

        let args = NotionExport.arguments(title: "T", content: "body", tool: createTool)
        #expect(args?["pages"] != nil)   // nested pages array shape
    }
}
