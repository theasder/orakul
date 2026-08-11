import Foundation
import Testing
@testable import MeetGPT

@Suite("Assistant DOCX exporter")
struct AssistantDOCXExporterTests {
    private let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleDocument(long: Bool = false) -> AssistantAnswerDocument {
        let repeated = long
            ? (1...18).map { index in
                """
                ## Workstream \(index)
                The team will validate the release plan with customers, document the evidence, and record every owner before the next checkpoint.
                - Owner: **Команда продукта**
                - Проверка: клиент подтвердил результат
                1. Gather evidence
                2. Review the result
                > 这是一个跨语言会议摘要。
                """
            }.joined(separator: "\n\n")
            : """
              ## Decision
              Ship **Friday** after the final review.
              - Owner: Команда продукта
                - Confirm rollback steps
              1. Gather evidence
              2. Review the result
              > 这是一个跨语言会议摘要。
              \u{0060}\u{0060}\u{0060}swift
              let ready = true
              \u{0060}\u{0060}\u{0060}
              """
        return AssistantAnswerDocument(
            title: "Launch & Rollout <Plan>",
            prompt: "Summarize решение & 下一步 without inventing facts.",
            answer: repeated + "\u{0001}",
            exportedAt: exportedAt
        )
    }

    private func strings(for document: AssistantAnswerDocument) throws -> [String: String] {
        var output: [String: String] = [:]
        for part in AssistantDOCXExporter.packageParts(for: document) {
            output[part.name] = try #require(String(data: part.data, encoding: .utf8))
        }
        return output
    }

    // Reported from a real call: the share control "is not saving whole
    // dialog, it is saving last answer". The archive of earlier turns exists —
    // exports just never included it.

    @Test("an export carries every archived turn, in order, before the live one")
    func exportsWholeDialog() throws {
        let history = [
            AIExchange(prompt: "What did we decide about pricing?",
                       answer: "Pricing ships with the March release."),
            AIExchange(prompt: "Who owns the rollout?",
                       answer: "Ana owns rollout; Bo drafts the FAQ.")
        ]
        let document = AssistantAnswerDocument(
            title: "Assistant chat · Weekly sync",
            prompt: "Summarize the open risks.",
            answer: "The only open risk is the untested backfill.",
            exportedAt: exportedAt,
            earlierExchanges: history)

        let xmlText = try #require(strings(for: document)["word/document.xml"])
        // Every archived turn is present…
        #expect(xmlText.contains("What did we decide about pricing?"))
        #expect(xmlText.contains("Pricing ships with the March release."))
        #expect(xmlText.contains("Who owns the rollout?"))
        #expect(xmlText.contains("Ana owns rollout; Bo drafts the FAQ."))
        // …and the dialog reads in the order it happened, live turn last.
        let pricing = try #require(xmlText.range(of: "What did we decide about pricing?"))
        let rollout = try #require(xmlText.range(of: "Who owns the rollout?"))
        let live = try #require(xmlText.range(of: "The only open risk is the untested backfill."))
        #expect(pricing.lowerBound < rollout.lowerBound)
        #expect(rollout.lowerBound < live.lowerBound)
    }

    @Test("a single-turn export keeps the original section headings")
    func singleTurnHeadingsUnchanged() throws {
        let xmlText = try #require(strings(for: sampleDocument())["word/document.xml"])
        #expect(xmlText.contains("Original prompt"))
        #expect(xmlText.contains("Assistant answer"))
    }

    @Test("the Notion markdown export carries the whole dialog too")
    func notionMarkdownWholeDialog() {
        let md = NotionExport.markdown(
            title: "Assistant chat",
            date: exportedAt,
            prompt: "Summarize the open risks.",
            answer: "The backfill is untested.",
            blindSpots: [],
            earlierExchanges: [
                AIExchange(prompt: "First question?", answer: "First answer.")
            ])
        #expect(md.contains("First question?"))
        #expect(md.contains("First answer."))
        #expect(md.contains("The backfill is untested."))
        let first = md.range(of: "First answer.")!
        let live = md.range(of: "The backfill is untested.")!
        #expect(first.lowerBound < live.lowerBound)
    }

    @Test("the Google Docs HTML export carries the whole dialog too")
    func googleDocsHTMLWholeDialog() {
        let html = AssistantDocHTML.build(
            title: "Assistant chat",
            date: exportedAt,
            prompt: "Summarize the open risks.",
            answer: "The backfill is untested.",
            blindSpots: [],
            earlierExchanges: [
                AIExchange(prompt: "First question?", answer: "First answer.")
            ])
        #expect(html.contains("First question?"))
        #expect(html.contains("First answer."))
        #expect(html.contains("The backfill is untested."))
    }

    @Test("package has semantic styles, real numbering, relationships, and exact content")
    func semanticPackage() throws {
        let document = sampleDocument()
        let parts = AssistantDOCXExporter.packageParts(for: document)
        let names = Set(parts.map(\.name))
        #expect(names == [
            "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "docProps/app.xml",
            "word/document.xml", "word/styles.xml", "word/numbering.xml",
            "word/settings.xml", "word/header1.xml", "word/footer1.xml",
            "word/_rels/document.xml.rels",
        ])

        for part in parts where part.name.hasSuffix(".xml") || part.name.hasSuffix(".rels") {
            #expect(throws: Never.self) {
                _ = try XMLDocument(data: part.data, options: [])
            }
        }

        let xml = try strings(for: document)
        let body = try #require(xml["word/document.xml"])
        let styles = try #require(xml["word/styles.xml"])
        let numbering = try #require(xml["word/numbering.xml"])
        let relationships = try #require(xml["word/_rels/document.xml.rels"])

        #expect(body.contains("Launch &amp; Rollout &lt;Plan&gt;"))
        #expect(body.contains("Summarize решение &amp; 下一步 without inventing facts."))
        #expect(body.contains("Команда продукта"))
        #expect(body.contains("这是一个跨语言会议摘要"))
        #expect(!body.unicodeScalars.contains { $0.value == 1 })
        #expect(body.contains(#"<w:numId w:val="1"/>"#))
        #expect(body.contains(#"<w:numId w:val="2"/>"#))
        #expect(body.contains(#"<w:pStyle w:val="CodeBlock"/>"#))
        #expect(body.contains(#"<w:pgSz w:w="12240" w:h="15840" w:orient="portrait"/>"#))
        #expect(body.contains(#"w:top="1440" w:right="1440" w:bottom="1440" w:left="1440""#))
        #expect(body.contains(#"w:header="708" w:footer="708""#))

        #expect(styles.contains(#"w:styleId="Normal""#))
        #expect(styles.contains(#"w:styleId="Title""#))
        #expect(styles.contains(#"w:styleId="Heading1""#))
        #expect(styles.contains(#"w:styleId="PromptText""#))
        #expect(styles.contains(#"w:after="120" w:line="264""#))
        #expect(styles.contains(#"w:fill="F4F6F9""#))
        #expect(numbering.contains(#"w:left="720" w:hanging="360""#))
        #expect(numbering.contains(#"w:after="160" w:line="280""#))
        #expect(relationships.contains("relationships/header"))
        #expect(relationships.contains("relationships/footer"))
    }

    @Test("stored ZIP is deterministic and can emit the visual QA fixture")
    func archiveAndFixture() throws {
        let document = sampleDocument(long: true)
        let first = try AssistantDOCXExporter.makeDocument(document)
        let second = try AssistantDOCXExporter.makeDocument(document)
        #expect(first == second)
        #expect(Array(first.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        #expect(first.count > 10_000)

        if let path = ProcessInfo.processInfo.environment["CRUXWING_DOCX_QA_PATH"],
           !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try first.write(to: url, options: .atomic)
        }
    }

    @Test("LLM title cleanup, fallback, and filenames stay safe")
    func titleAndFilename() {
        #expect(AssistantAnswerTitle.cleaned(
            "  **\"Roadmap Delivery Decisions\"**  \nignored", prompt: "Fallback")
            == "Roadmap Delivery Decisions")
        #expect(AssistantAnswerTitle.fallback(
            prompt: "What did we decide about the enterprise launch timeline?")
            == "What did we decide about the enterprise launch")
        #expect(AssistantAnswerTitle.fallback(
            prompt: "Prompt unavailable for this older saved answer.")
            == "Cruxwing Assistant Answer")
        #expect(AssistantDOCXExporter.suggestedFilename(
            for: "Launch / rollout: owner?") == "Launch rollout owner.docx")
    }
}
