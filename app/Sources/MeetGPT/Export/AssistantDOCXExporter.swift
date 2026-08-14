import Foundation

/// Immutable snapshot used by the exporter. Capturing all four fields before
/// opening the save panel prevents a later assistant run from changing the
/// document while it is being written.
struct AssistantAnswerDocument: Equatable {
    let title: String
    let prompt: String
    let answer: String
    let exportedAt: Date
    /// Blind-spot lines (already formatted, e.g. "Risk: … — …") appended as a
    /// bulleted section. Empty omits the section entirely.
    let blindSpots: [String]
    /// Archived turns BEFORE the live prompt/answer, oldest first. The share
    /// control names the file "Assistant chat", so it must contain the chat —
    /// exporting only the last answer shipped, and was reported immediately.
    let earlierExchanges: [AIExchange]

    init(title: String, prompt: String, answer: String, exportedAt: Date,
         blindSpots: [String] = [], earlierExchanges: [AIExchange] = []) {
        self.title = title
        self.prompt = prompt
        self.answer = answer
        self.exportedAt = exportedAt
        self.blindSpots = blindSpots
        self.earlierExchanges = earlierExchanges
    }
}

/// Prompting and defensive cleanup for the small, cached title-generation call.
enum AssistantAnswerTitle {
    static let systemPrompt = """
    Create a concise title for an exported assistant answer.
    Use 4 to 10 words and the same language as the answer.
    Describe the concrete subject or outcome, not the fact that this is an AI answer.
    Return only the title: no quotation marks, label, markdown, or final period.
    """

    static func userMessage(prompt: String, answer: String) -> String {
        let promptExcerpt = String(prompt.prefix(1_500))
        let answerExcerpt = String(answer.prefix(4_000))
        return """
        ORIGINAL USER PROMPT:
        \(promptExcerpt)

        ASSISTANT ANSWER:
        \(answerExcerpt)
        """
    }

    static func cleaned(_ raw: String, prompt: String) -> String {
        var value = raw
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if value.lowercased().hasPrefix("title:") {
            value = String(value.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let wrappers = CharacterSet(charactersIn: "#*_\"'“”‘’")
        value = value.trimmingCharacters(in: wrappers)
        value = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:;,-–—"))

        if value.count > 100 {
            let prefix = String(value.prefix(100))
            value = prefix.split(separator: " ").dropLast().joined(separator: " ")
            if value.isEmpty { value = prefix }
        }
        return value.isEmpty ? fallback(prompt: prompt) : value
    }

    /// The export name for an assistant dialog: plain, predictable, and free.
    ///
    /// This replaced a per-export LLM call that invented a topic title. That
    /// title cost credits and a round trip, varied between exports of the SAME
    /// dialog, and answered a question nobody asked — the file is the assistant
    /// chat for a given call, and saying so is enough to find it later.
    static func forDialog(meetingTitle: String, date: Date) -> String {
        let trimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "Assistant chat · \(String(trimmed.prefix(80)))" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Assistant chat · \(formatter.string(from: date))"
    }

    static func fallback(prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("Prompt unavailable for this older saved answer") else {
            return "Ответ orakul"
        }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let words = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*_\"'“”‘’ .?!:;,-–—"))
            .split(whereSeparator: \.isWhitespace)
        let candidate = words.prefix(8).joined(separator: " ")
        return candidate.isEmpty ? "Ответ orakul" : String(candidate.prefix(100))
    }
}

/// Produces a semantic Office Open XML document without a runtime dependency.
///
/// Design system:
/// - preset: standard_business_brief
/// - first-page pattern: memo_masthead
/// - named overrides: 23 pt black title; shaded prompt paragraph; quiet
///   Колонтитул с именем продукта и номером страницы справа.
enum AssistantDOCXExporter {
    enum ExportError: LocalizedError {
        case archiveTooLarge
        case tooManyParts

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge:
                return "The Word document is too large to package."
            case .tooManyParts:
                return "The Word document contains too many package parts."
            }
        }
    }

    static func makeDocument(_ document: AssistantAnswerDocument) throws -> Data {
        try StoredZIPWriter.makeArchive(entries: packageParts(for: document))
    }

    static func suggestedFilename(for title: String, date: Date? = nil) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        let scalars = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }
        var value = scalars.joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if value.count > 80 {
            value = String(value.prefix(80))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        if value.isEmpty { value = "Ответ orakul" }
        // Elegant, sortable, collision-free: append the export date with an
        // em-dash ("Project Falcon Budget Review — 2026-07-23.docx"). No date
        // keeps the bare name (callers that don't need dating, and tests).
        if let date {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            return "\(value) — \(df.string(from: date)).docx"
        }
        return value + ".docx"
    }

    /// Internal inspection seam used by tests to audit styles, numbering,
    /// relationships, and page geometry without depending on a ZIP library.
    static func packageParts(for document: AssistantAnswerDocument) -> [(name: String, data: Data)] {
        let xmlParts: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", rootRelationshipsXML),
            ("docProps/core.xml", corePropertiesXML(document)),
            ("docProps/app.xml", appPropertiesXML),
            ("word/document.xml", documentXML(document)),
            ("word/styles.xml", stylesXML),
            ("word/numbering.xml", numberingXML),
            ("word/settings.xml", settingsXML),
            ("word/header1.xml", headerXML),
            ("word/footer1.xml", footerXML),
            ("word/_rels/document.xml.rels", documentRelationshipsXML),
        ]
        return xmlParts.map { ($0.0, Data($0.1.utf8)) }
    }

    // MARK: Package metadata

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
      <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
      <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
      <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
      <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """

    private static let rootRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static let documentRelationshipsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
      <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
      <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
    </Relationships>
    """

    private static func corePropertiesXML(_ document: AssistantAnswerDocument) -> String {
        let timestamp = isoTimestamp(document.exportedAt)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:dcterms="http://purl.org/dc/terms/"
          xmlns:dcmitype="http://purl.org/dc/dcmitype/"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xml(document.title))</dc:title>
          <dc:subject>Выгрузка ответа orakul</dc:subject>
          <dc:creator>orakul</dc:creator>
          <cp:lastModifiedBy>orakul</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static let appPropertiesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
      xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
      <Application>orakul</Application>
      <AppVersion>1.0</AppVersion>
      <Company>orakul</Company>
    </Properties>
    """

    private static let settingsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:zoom w:percent="100"/>
      <w:defaultTabStop w:val="720"/>
      <w:compat/>
    </w:settings>
    """

    // MARK: Semantic styles and numbering

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:docDefaults>
        <w:rPrDefault><w:rPr>
          <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Arial Unicode MS"/>
          <w:sz w:val="22"/><w:szCs w:val="22"/>
          <w:lang w:val="en-US" w:eastAsia="zh-CN" w:bidi="ar-SA"/>
        </w:rPr></w:rPrDefault>
        <w:pPrDefault><w:pPr>
          <w:spacing w:before="0" w:after="120" w:line="264" w:lineRule="auto"/>
        </w:pPr></w:pPrDefault>
      </w:docDefaults>

      <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/><w:qFormat/>
        <w:pPr><w:spacing w:before="0" w:after="120" w:line="264" w:lineRule="auto"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Arial Unicode MS"/>
          <w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Title">
        <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:keepNext/><w:spacing w:before="0" w:after="80"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Arial Unicode MS"/>
          <w:b/><w:color w:val="000000"/><w:sz w:val="46"/><w:szCs w:val="46"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading1">
        <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:keepNext/><w:spacing w:before="320" w:after="160"/><w:outlineLvl w:val="0"/></w:pPr>
        <w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading2">
        <w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr>
        <w:rPr><w:b/><w:color w:val="2E74B5"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Heading3">
        <w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
        <w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr>
        <w:rPr><w:b/><w:color w:val="1F4D78"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Metadata">
        <w:name w:val="Metadata"/><w:basedOn w:val="Normal"/>
        <w:pPr><w:spacing w:before="0" w:after="240" w:line="240" w:lineRule="auto"/></w:pPr>
        <w:rPr><w:color w:val="6B7280"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="PromptText">
        <w:name w:val="Prompt Text"/><w:basedOn w:val="Normal"/>
        <w:pPr>
          <w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="2E74B5"/></w:pBdr>
          <w:shd w:val="clear" w:color="auto" w:fill="F4F6F9"/>
          <w:ind w:left="240" w:right="240"/>
          <w:spacing w:before="120" w:after="240" w:line="264" w:lineRule="auto"/>
        </w:pPr>
        <w:rPr><w:color w:val="0B2545"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Quote">
        <w:name w:val="Quote"/><w:basedOn w:val="Normal"/>
        <w:pPr>
          <w:pBdr><w:left w:val="single" w:sz="8" w:space="8" w:color="AAB7C6"/></w:pBdr>
          <w:ind w:left="360"/><w:spacing w:before="0" w:after="120" w:line="264" w:lineRule="auto"/>
        </w:pPr>
        <w:rPr><w:i/><w:color w:val="5B6470"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="CodeBlock">
        <w:name w:val="Code Block"/><w:basedOn w:val="Normal"/>
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F4F7"/>
          <w:ind w:left="240" w:right="240"/>
          <w:spacing w:before="0" w:after="40" w:line="240" w:lineRule="auto"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo" w:eastAsia="Arial Unicode MS"/>
          <w:color w:val="243142"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Header">
        <w:name w:val="header"/><w:basedOn w:val="Normal"/>
        <w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>
        <w:rPr><w:color w:val="7A8390"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>
      </w:style>
      <w:style w:type="paragraph" w:styleId="Footer">
        <w:name w:val="footer"/><w:basedOn w:val="Normal"/>
        <w:pPr><w:jc w:val="right"/><w:spacing w:before="0" w:after="0"/></w:pPr>
        <w:rPr><w:color w:val="7A8390"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>
      </w:style>
    </w:styles>
    """

    private static var numberingXML: String {
        func levels(format: String, bullet: Bool) -> String {
            (0..<9).map { level in
                let textIndent = 720 + (level * 360)
                let marker = bullet ? "•" : "%\(level + 1)."
                return """
                  <w:lvl w:ilvl="\(level)">
                    <w:start w:val="1"/><w:numFmt w:val="\(format)"/><w:lvlText w:val="\(marker)"/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                      <w:tabs><w:tab w:val="num" w:pos="\(textIndent)"/></w:tabs>
                      <w:ind w:left="\(textIndent)" w:hanging="360"/>
                      <w:spacing w:before="0" w:after="160" w:line="280" w:lineRule="auto"/>
                    </w:pPr>
                  </w:lvl>
                """
            }.joined(separator: "\n")
        }
        let decimalInstances = (2...257).map {
            "<w:num w:numId=\"\($0)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }.joined(separator: "\n  ")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="multilevel"/>
        \(levels(format: "bullet", bullet: true))
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="multilevel"/>
        \(levels(format: "decimal", bullet: false))
          </w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
          \(decimalInstances)
        </w:numbering>
        """
    }

    // MARK: Header, footer, and body

    private static let headerXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:p>
        <w:pPr><w:pStyle w:val="Header"/><w:tabs><w:tab w:val="right" w:pos="9360"/></w:tabs></w:pPr>
        <w:r><w:t>orakul</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>Выгрузка ответа</w:t></w:r>
      </w:p>
    </w:hdr>
    """

    private static let footerXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:p>
        <w:pPr><w:pStyle w:val="Footer"/><w:jc w:val="right"/></w:pPr>
        <w:r><w:t xml:space="preserve">Page </w:t></w:r>
        <w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple>
      </w:p>
    </w:ftr>
    """

    private static func documentXML(_ document: AssistantAnswerDocument) -> String {
        // Title, metadata, and the user's prompt are VERBATIM fields — never
        // parse them as markdown: the inline parser swallows angle-bracket
        // segments ("<Plan>") as HTML and would mangle a prompt's literal
        // *asterisks*. Only the assistant answer is markdown.
        var body: [String] = [
            paragraph(style: "Title", text: document.title, parseInline: false),
            paragraph(style: "Metadata",
                      text: "Assistant export • \(displayTimestamp(document.exportedAt))",
                      parseInline: false),
        ]
        // The whole dialog, oldest first. A single turn keeps the original
        // section headings; a multi-turn export numbers them so the file reads
        // as the conversation it is.
        let multiTurn = !document.earlierExchanges.isEmpty
        for (index, exchange) in document.earlierExchanges.enumerated() {
            body.append(paragraph(style: "Heading2", text: "Prompt \(index + 1)"))
            body.append(paragraph(style: "PromptText", text: exchange.prompt, parseInline: false))
            body.append(paragraph(style: "Heading1", text: "Answer \(index + 1)"))
            body.append(contentsOf: markdownBlocks(exchange.answer))
        }
        body.append(paragraph(
            style: "Heading2",
            text: multiTurn ? "Prompt \(document.earlierExchanges.count + 1)" : "Original prompt"))
        body.append(paragraph(style: "PromptText", text: document.prompt, parseInline: false))
        body.append(paragraph(
            style: "Heading1",
            text: multiTurn ? "Answer \(document.earlierExchanges.count + 1)" : "Assistant answer"))
        body.append(contentsOf: markdownBlocks(document.answer))
        // Blind spots the co-pilot surfaced during the call — a bulleted
        // section (numId 1 = the bullet list) after the answer.
        if !document.blindSpots.isEmpty {
            body.append(paragraph(style: "Heading1", text: "Blind spots"))
            for spot in document.blindSpots {
                body.append(listParagraph(text: spot, level: 0, numberID: 1))
            }
        }
        body.append("""
          <w:sectPr>
            <w:headerReference w:type="default" r:id="rId3"/>
            <w:footerReference w:type="default" r:id="rId4"/>
            <w:pgSz w:w="12240" w:h="15840" w:orient="portrait"/>
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"
              w:header="708" w:footer="708" w:gutter="0"/>
            <w:cols w:space="720"/>
            <w:docGrid w:linePitch="360"/>
          </w:sectPr>
        """)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
        \(body.joined(separator: "\n"))
          </w:body>
        </w:document>
        """
    }

    private static func markdownBlocks(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [String] = []
        var inCode = false
        var activeDecimalNumberID: Int?
        var nextDecimalNumberID = 2

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let beginsFence = trimmed.unicodeScalars.prefix(3).allSatisfy { $0.value == 96 }
                && trimmed.unicodeScalars.count >= 3
            if beginsFence {
                inCode.toggle()
                continue
            }
            if inCode {
                activeDecimalNumberID = nil
                result.append(paragraph(style: "CodeBlock", text: raw, parseInline: false))
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if isHorizontalRule(trimmed) { continue }

            let leadingSpaces = raw.prefix { $0 == " " || $0 == "\t" }
                .reduce(into: 0) { count, character in count += character == "\t" ? 4 : 1 }
            let level = min(8, leadingSpaces / 2)

            if let heading = heading(in: trimmed) {
                activeDecimalNumberID = nil
                result.append(paragraph(style: "Heading\(min(3, heading.level))", text: heading.text))
            } else if let bullet = bulletText(in: trimmed) {
                activeDecimalNumberID = nil
                result.append(listParagraph(text: bullet, level: level, numberID: 1))
            } else if let number = numberedItem(in: trimmed) {
                if activeDecimalNumberID == nil || number.ordinal == 1 {
                    activeDecimalNumberID = min(257, nextDecimalNumberID)
                    nextDecimalNumberID += 1
                }
                result.append(listParagraph(
                    text: number.text, level: level, numberID: activeDecimalNumberID ?? 2))
            } else if trimmed.hasPrefix(">") {
                activeDecimalNumberID = nil
                let quote = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                result.append(paragraph(style: "Quote", text: quote))
            } else if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                activeDecimalNumberID = nil
                // Preserve an isolated Markdown table row legibly. Full table
                // semantics are reserved for typed artifacts rather than
                // guessing column geometry from malformed streamed Markdown.
                result.append(paragraph(style: "CodeBlock", text: trimmed, parseInline: false))
            } else {
                activeDecimalNumberID = nil
                result.append(paragraph(style: "Normal", text: raw))
            }
        }
        return result.isEmpty ? [paragraph(style: "Normal", text: documentEmptyAnswer)] : result
    }

    private static let documentEmptyAnswer = "No answer text was available."

    private static func heading(in text: String) -> (level: Int, text: String)? {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), text.dropFirst(hashes).first?.isWhitespace == true else {
            return nil
        }
        return (hashes, text.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(in text: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "• "] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedItem(in text: String) -> (ordinal: Int, text: String)? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }
        guard index > text.startIndex, index < text.endIndex, text[index] == "." else { return nil }
        let ordinal = Int(text[..<index]) ?? 1
        let afterPeriod = text.index(after: index)
        guard afterPeriod < text.endIndex, text[afterPeriod].isWhitespace else { return nil }
        return (ordinal, String(text[text.index(after: afterPeriod)...]))
    }

    private static func isHorizontalRule(_ text: String) -> Bool {
        guard text.count >= 3 else { return false }
        let characters = Set(text.filter { !$0.isWhitespace })
        return characters.count == 1 && ["-", "*", "_"].contains(String(characters.first!))
    }

    private static func paragraph(style: String, text: String,
                                  parseInline: Bool = true) -> String {
        let runs = parseInline ? inlineRuns(text) : runXML(text: text)
        return """
          <w:p>
            <w:pPr><w:pStyle w:val="\(style)"/></w:pPr>
            \(runs)
          </w:p>
        """
    }

    private static func listParagraph(text: String, level: Int, numberID: Int) -> String {
        """
          <w:p>
            <w:pPr>
              <w:pStyle w:val="Normal"/>
              <w:numPr><w:ilvl w:val="\(level)"/><w:numId w:val="\(numberID)"/></w:numPr>
            </w:pPr>
            \(inlineRuns(text))
          </w:p>
        """
    }

    private static func inlineRuns(_ source: String) -> String {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return runXML(text: source)
        }

        var output = ""
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent
            let bold = intent?.contains(.stronglyEmphasized) == true
            let italic = intent?.contains(.emphasized) == true
            let code = intent?.contains(.code) == true
            output += runXML(text: text, bold: bold, italic: italic, code: code)
        }
        return output.isEmpty ? runXML(text: source) : output
    }

    private static func runXML(text: String, bold: Bool = false,
                               italic: Bool = false, code: Bool = false) -> String {
        var properties: [String] = []
        if bold { properties.append("<w:b/>") }
        if italic { properties.append("<w:i/>") }
        if containsEastAsianText(text) {
            // Word and LibreOffice do not consistently honor only w:eastAsia
            // when a run mixes Latin/Cyrillic and Han characters. A run-level
            // Unicode font keeps multilingual prompts and answers intact.
            properties.append("<w:rFonts w:ascii=\"Arial Unicode MS\" w:hAnsi=\"Arial Unicode MS\" w:cs=\"Arial Unicode MS\" w:eastAsia=\"Arial Unicode MS\" w:hint=\"eastAsia\"/>")
        } else if code {
            properties.append("<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\" w:eastAsia=\"Arial Unicode MS\"/>")
        }
        if code {
            properties.append("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F4F7\"/>")
            properties.append("<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/>")
        }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties.joined())</w:rPr>"
        return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r>"
    }

    private static func containsEastAsianText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
                || (0x20000...0x2FA1F).contains(value)
        }
    }

    // MARK: XML utilities

    private static func xml(_ input: String) -> String {
        var valid = ""
        for scalar in input.unicodeScalars {
            let value = scalar.value
            if value == 0x9 || value == 0xA || value == 0xD
                || (0x20...0xD7FF).contains(value)
                || (0xE000...0xFFFD).contains(value)
                || (0x10000...0x10FFFF).contains(value) {
                valid.unicodeScalars.append(scalar)
            }
        }
        return valid
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}

// MARK: - Dependency-free stored ZIP archive

private enum StoredZIPWriter {
    private struct CentralRecord {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func makeArchive(entries: [(name: String, data: Data)]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw AssistantDOCXExporter.ExportError.tooManyParts
        }
        var archive = Data()
        var central: [CentralRecord] = []
        central.reserveCapacity(entries.count)

        for entry in entries {
            guard archive.count <= Int(UInt32.max),
                  entry.data.count <= Int(UInt32.max) else {
                throw AssistantDOCXExporter.ExportError.archiveTooLarge
            }
            let name = Data(entry.name.utf8)
            guard name.count <= Int(UInt16.max) else {
                throw AssistantDOCXExporter.ExportError.archiveTooLarge
            }
            let size = UInt32(entry.data.count)
            let checksum = crc32(entry.data)
            let offset = UInt32(archive.count)

            archive.appendLE(UInt32(0x04034B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0x0021))
            archive.appendLE(checksum)
            archive.appendLE(size)
            archive.appendLE(size)
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))
            archive.append(name)
            archive.append(entry.data)
            central.append(CentralRecord(name: name, crc: checksum, size: size, offset: offset))
        }

        guard archive.count <= Int(UInt32.max) else {
            throw AssistantDOCXExporter.ExportError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)
        for record in central {
            archive.appendLE(UInt32(0x02014B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0x0021))
            archive.appendLE(record.crc)
            archive.appendLE(record.size)
            archive.appendLE(record.size)
            archive.appendLE(UInt16(record.name.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(0))
            archive.appendLE(record.offset)
            archive.append(record.name)
        }
        guard archive.count <= Int(UInt32.max) else {
            throw AssistantDOCXExporter.ExportError.archiveTooLarge
        }
        let centralSize = UInt32(archive.count) - centralOffset
        let count = UInt16(central.count)
        archive.appendLE(UInt32(0x06054B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(count)
        archive.appendLE(count)
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = (value & 1) == 1
                    ? (value >> 1) ^ 0xEDB88320
                    : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
