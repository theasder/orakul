import AppKit
import Foundation
import OrakulCore
import PDFKit
import UniformTypeIdentifiers

enum ContextImporter {
    /// The only extensions a folder import is allowed to inspect. Keep this
    /// list explicit: `extractText` has a best-effort fallback for a file the
    /// user picked directly, but recursively trying that fallback on arbitrary
    /// binaries is both expensive and a data-leak footgun.
    ///
    /// Source-code extensions are intentionally included. A standing folder is
    /// commonly a project the user wants to discuss alongside a tutorial, and
    /// omitting the implementation files would make that feature misleading.
    static let supportedExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "log", "csv", "tsv",
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm",
        "json", "xml", "yaml", "yml", "toml", "ini", "cfg",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "css", "scss", "sass",
        "py", "rb", "go", "rs", "java", "kt", "kts", "cs", "php",
        "sh", "bash", "zsh", "fish", "sql", "graphql", "gql",
        "proto", "gradle", "properties"
    ]

    static let supportedExtensionlessNames: Set<String> = [
        "dockerfile", "makefile", "gemfile", "rakefile", "procfile",
        "license", "readme", "changelog", "authors", "contributors"
    ]

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
            || (url.pathExtension.isEmpty
                && supportedExtensionlessNames.contains(url.lastPathComponent.lowercased()))
    }

    /// File types accepted by the import picker.
    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .utf8PlainText, .pdf, .rtf]
        for ext in supportedExtensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    /// Extract plain text from the file at `url`.
    /// Dispatches on a background task — safe to call from @MainActor callers.
    static func importFile(at url: URL) async throws -> ImportedContextFile {
        let worker = Task.detached(priority: .userInitiated) { () -> ImportedContextFile in
            try Task.checkCancellation()
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

            // A ChatGPT/Claude export is JSON, so without this it would import
            // as raw JSON: huge, unreadable, and billed as oversized input.
            if url.pathExtension.lowercased() == "json",
               let data = try? Data(contentsOf: url),
               let export = ChatExportImporter.parse(data) {
                return ImportedContextFile(name: ChatExportImporter.fileName(for: export.source),
                                           text: export.text)
            }

            let text = try extractText(url: url)
            try Task.checkCancellation()
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                throw ImportError.empty
            }
            return ImportedContextFile(name: url.lastPathComponent, text: clean)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: -

    enum ImportError: LocalizedError {
        case empty
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .empty:               return "File contained no readable text."
            case .unreadable(let e):   return "Could not read file: \(e)"
            case .unsupported(let e):  return "Unsupported file type: .\(e)"
            }
        }
    }

    private static func extractText(url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try extractPDF(url: url)
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm":
            return try extractAttributed(url: url)
        case "", "txt", "md", "markdown", "log", "csv", "tsv", "json", "xml", "yml", "yaml":
            return try extractPlainText(url: url)
        default:
            // Last-ditch fallback: try UTF-8, then NSAttributedString.
            if let text = try? extractPlainText(url: url) { return text }
            if let text = try? extractAttributed(url: url) { return text }
            throw ImportError.unsupported(ext)
        }
    }

    private static func extractPDF(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw ImportError.unreadable("PDFKit could not open the document")
        }
        var out = ""
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            out += text
            if !text.hasSuffix("\n") { out += "\n" }
        }
        return out
    }

    private static func extractAttributed(url: URL) throws -> String {
        // NSAttributedString auto-detects docx / doc / rtf / html from the file extension.
        do {
            let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return attr.string
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
    }

    /// Кодировки в том порядке, в каком их стоит пробовать русскому продукту.
    ///
    /// Было: UTF-8 → UTF-16 → isoLatin1, и обе запасные молча портили русский
    /// текст. Измерено на файле «Аня: По тарифам решили поднять.» в CP1251:
    ///
    ///   UTF-16 (без метки) → «샭Ｚ⃏⃯»   — иероглифы, и это «успех»
    ///   isoLatin1          → «Àíÿ: Ïî òàðèôàì…» — классическая кракозябра
    ///   CP1251             → «Аня: По тарифам решили поднять.»
    ///
    /// То есть до Latin-1 дело даже не доходило: UTF-16 без метки берётся за
    /// любые байты и возвращает мусор, который потом уезжает в подсказку
    /// модели как «контекст». Испорченный контекст хуже отсутствующего —
    /// модель читает его всерьёз.
    ///
    /// `TranscriptFile` пробует UTF-8, затем UTF-16 ТОЛЬКО с меткой порядка
    /// байтов, затем CP1251, и проверяет, что вышел текст, а не картинка.
    /// Latin-1 остаётся последним — для честно западного файла.
    private static func extractPlainText(url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable("не удалось прочитать файл")
        }
        if let text = TranscriptFile.decode(data) { return text }
        if let latin = String(data: data, encoding: .isoLatin1),
           !latin.unicodeScalars.contains(where: {
               $0.value < 32 && $0 != "\t" && $0 != "\n" && $0 != "\r"
           }) {
            return latin
        }
        throw ImportError.unreadable("unknown text encoding")
    }
}
