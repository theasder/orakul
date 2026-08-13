import Foundation
import Testing
@testable import MeetGPT

/// Attaching a folder is not attaching a file: a repo or a Downloads directory
/// can mean thousands of files and megabytes of text, and every one of those
/// characters is paid for on every request. These cover the budgets and the
/// exclusions that keep that from happening quietly.
@Suite("Context folders", .serialized)
struct ContextFolderTests {

    /// Builds a throwaway folder tree and hands back its URL.
    private func makeFolder(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cruxwing-folder-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ text: String, to url: URL, named name: String) throws {
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeDirectory(_ url: URL, named name: String) throws -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    private func scan(_ root: URL) async throws -> (files: [ImportedContextFile], skipped: [String]) {
        let bookmark = try ContextFolderScanner.bookmark(for: root)
        return try await ContextFolderScanner.scan(bookmark: bookmark)
    }

    @Test("reads the readable files in a folder")
    func readsFiles() async throws {
        let root = try makeFolder { url in
            try write("# Roadmap\nShip the connector.", to: url, named: "README.md")
            try write("owner,due\nana,friday", to: url, named: "tasks.csv")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.count == 2)
        #expect(result.files.contains { $0.name == "README.md" && $0.text.contains("Ship the connector") })
    }

    @Test("descends into subfolders, shallowest first")
    func descendsBreadthFirst() async throws {
        let root = try makeFolder { url in
            try write("top level", to: url, named: "top.md")
            let nested = try makeDirectory(url, named: "docs")
            try write("nested", to: nested, named: "deep.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.count == 2)
        // A top-level README must win the budget over something buried deeper.
        #expect(result.files.first?.name == "top.md")
        #expect(result.files.last?.name == "docs/deep.md")
    }

    @Test("never descends into build and dependency directories")
    func skipsIgnoredDirectories() async throws {
        let root = try makeFolder { url in
            try write("real", to: url, named: "notes.md")
            for ignored in ["node_modules", ".git", "build", "Pods"] {
                let directory = try makeDirectory(url, named: ignored)
                try write("noise", to: directory, named: "junk.md")
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["notes.md"])
    }

    @Test("ignores file types that are not worth extracting")
    func skipsUnreadableTypes() async throws {
        let root = try makeFolder { url in
            try write("keep", to: url, named: "keep.md")
            try write("binary-ish", to: url, named: "image.png")
            try write("archive", to: url, named: "bundle.zip")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["keep.md"])
    }

    @Test("indexes source code from an attached project")
    func readsProjectSourceCode() async throws {
        let root = try makeFolder { url in
            try write("struct TokenRefresher {}", to: url, named: "AuthService.swift")
            try write("export function retry() {}", to: url, named: "retry.ts")
            try write("FROM swift:latest", to: url, named: "Dockerfile")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["AuthService.swift", "Dockerfile", "retry.ts"])
    }

    @Test("never follows a symlink outside the selected folder")
    func rejectsSymlinkTraversal() async throws {
        let outside = try makeFolder { url in
            try write("SUPER-SECRET-OUTSIDE-ROOT", to: url, named: "secret.md")
        }
        let root = try makeFolder { url in
            try write("safe project note", to: url, named: "safe.md")
            try FileManager.default.createSymbolicLink(
                at: url.appendingPathComponent("linked-secret.md"),
                withDestinationURL: outside.appendingPathComponent("secret.md"))
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["safe.md"])
        #expect(!result.files.contains { $0.text.contains("SUPER-SECRET") })
    }

    @Test("never enters package descendants or hidden files")
    func rejectsPackagesAndHiddenFiles() async throws {
        let root = try makeFolder { url in
            try write("visible", to: url, named: "visible.md")
            try write("hidden", to: url, named: ".private.md")
            let package = try makeDirectory(url, named: "Example.app")
            try write("package secret", to: package, named: "inside.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["visible.md"])
    }

    @Test("rejects a raw file beyond the per-file byte cap")
    func capsRawFileBytes() async throws {
        let root = try makeFolder { url in
            let huge = Data(repeating: 0x61, count: Int(ContextFolderScanner.maxFileBytes) + 1)
            try huge.write(to: url.appendingPathComponent("oversized.md"), options: .atomic)
            try write("small", to: url, named: "small.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["small.md"])
        #expect(result.skipped.contains("oversized.md"))
    }

    @Test("stays inside the aggregate raw byte read cap")
    func capsTotalRawBytes() async throws {
        let root = try makeFolder { url in
            for index in 0..<5 {
                let data = Data(repeating: UInt8(0x61 + index),
                                count: Int(ContextFolderScanner.maxFileBytes))
                try data.write(
                    to: url.appendingPathComponent("raw-\(index).md"),
                    options: .atomic)
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.count == 4)
        #expect(result.skipped.contains("raw-4.md"))
    }

    @Test("an unreadable regular file is never indexed")
    func skipsUnreadableFile() async throws {
        let root = try makeFolder { url in
            try write("visible", to: url, named: "visible.md")
            try write("must not be read", to: url, named: "locked.md")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: url.appendingPathComponent("locked.md").path)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.map(\.name) == ["visible.md"])
    }

    @Test("deduplicates byte-identical files deterministically")
    func deduplicatesContent() async throws {
        let root = try makeFolder { url in
            try write("same implementation", to: url, named: "a.md")
            try write("same implementation", to: url, named: "b.md")
            try write("different", to: url, named: "c.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await scan(root)
        let second = try await scan(root)
        #expect(first.files.map(\.name) == ["a.md", "c.md"])
        #expect(first.files.map(\.name) == second.files.map(\.name))
        #expect(first.skipped.contains("b.md"))
    }

    @Test("caps the number of files and reports what it left out")
    func capsFileCount() async throws {
        let overflow = ContextFolderScanner.maxFiles + 5
        let root = try makeFolder { url in
            for index in 0..<overflow {
                try write("file \(index)", to: url, named: String(format: "doc-%03d.md", index))
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.count == ContextFolderScanner.maxFiles)
        // Silent truncation would read as "the whole folder is attached".
        #expect(result.skipped.count == 5)
    }

    @Test("truncates a single oversized file rather than dropping it")
    func truncatesLargeFile() async throws {
        let root = try makeFolder { url in
            try write(String(repeating: "a", count: ContextFolderScanner.maxFileChars * 2),
                      to: url, named: "huge.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.count == 1)
        #expect(result.files[0].charCount <= ContextFolderScanner.maxFileChars)
        #expect(result.files[0].text.hasSuffix("(truncated)"))
    }

    @Test("stays inside the total character budget")
    func respectsTotalBudget() async throws {
        let perFile = ContextFolderScanner.maxFileChars
        let needed = (ContextFolderScanner.maxTotalChars / perFile) + 3
        let root = try makeFolder { url in
            for index in 0..<needed {
                try write(String(repeating: "b", count: perFile),
                          to: url, named: String(format: "big-%03d.md", index))
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        let total = result.files.reduce(0) { $0 + $1.charCount }
        #expect(total <= ContextFolderScanner.maxTotalChars)
        #expect(!result.skipped.isEmpty)
    }

    @Test("an empty folder yields nothing and does not error")
    func emptyFolder() async throws {
        let root = try makeFolder { _ in }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await scan(root)
        #expect(result.files.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("a bookmark to a deleted folder fails cleanly")
    func deletedFolderFails() async throws {
        let root = try makeFolder { url in
            try write("gone soon", to: url, named: "notes.md")
        }
        let bookmark = try ContextFolderScanner.bookmark(for: root)
        try FileManager.default.removeItem(at: root)

        await #expect(throws: (any Error).self) {
            _ = try await ContextFolderScanner.scan(bookmark: bookmark)
        }
    }

    @Test("a cancelled scan publishes no partial index")
    func cancellationIsAtomic() async throws {
        let root = try makeFolder { url in
            for index in 0..<ContextFolderScanner.maxCandidateFiles {
                try write(String(repeating: "work (index) ", count: 300),
                          to: url, named: String(format: "file-%03d.md", index))
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try ContextFolderScanner.bookmark(for: root)

        let task = Task { try await ContextFolderScanner.scan(bookmark: bookmark) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("retrieval attaches only the relevant bounded project excerpts")
    func retrievesRelevantExcerpts() {
        let folder = ContextFolder(
            name: "Acme", path: "/redacted/acme", bookmark: Data(),
            files: [
                ImportedContextFile(name: "README.md", text: "Project overview and setup."),
                ImportedContextFile(name: "Sources/AuthService.swift",
                                    text: String(repeating: "authentication refresh token retry ", count: 300)),
                ImportedContextFile(name: "Finance/payroll.md",
                                    text: String(repeating: "salary payroll invoice ", count: 300)),
            ])

        let rendered = ContextFolderRetriever.render(
            folders: [folder], query: "How should refresh token retry work?")

        #expect(rendered.contains("AuthService.swift"))
        #expect(rendered.contains("refresh token"))
        #expect(!rendered.contains("payroll"))
        #expect(!rendered.contains("Project overview"))
        #expect(rendered.count <= ContextFolderRetriever.maxTotalChars)
    }

    @Test("a generic query gets one README fallback, not a folder dump")
    func genericFallbackIsSmall() {
        let folder = ContextFolder(
            name: "Project", path: "/redacted/project", bookmark: Data(),
            files: (0..<12).map { index in
                ImportedContextFile(
                    name: index == 7 ? "README.md" : "file-\(index).md",
                    text: String(repeating: "unrelated body \(index) ", count: 300))
            })

        let rendered = ContextFolderRetriever.render(
            folders: [folder], query: "xyzzy unmatched term")

        #expect(rendered.contains("README.md"))
        #expect(rendered.components(separatedBy: "=== Folder:").count - 1 == 1)
        #expect(rendered.count <= ContextFolderRetriever.maxSnippetChars + 128)
    }

    @Test("rapid prompt retrieval changes excerpts without detaching the folder")
    @MainActor
    func rapidPromptsKeepFolderAttached() async throws {
        let root = try makeFolder { url in
            try write("refresh token rotation", to: url, named: "auth.md")
            try write("database migration rollback", to: url, named: "database.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        state.contextFiles.append(ImportedContextFile(name: "Pinned.md", text: "always included"))
        await state.attachContextFolder(url: root)

        let auth = state.promptContext(query: "refresh token")
        let database = state.promptContext(query: "migration rollback")

        #expect(auth.contains("auth.md"))
        #expect(!auth.contains("database.md"))
        #expect(database.contains("database.md"))
        #expect(!database.contains("auth.md"))
        // Preserve the existing loose-file contract for every request.
        #expect(auth.contains("Pinned.md") && database.contains("Pinned.md"))
        #expect(state.contextFolders.count == 1)
    }

    @Test("cancelled folder attachment is quiet and leaves no grant")
    @MainActor
    func cancelledAttachmentDoesNotPublish() async throws {
        let root = try makeFolder { url in
            for index in 0..<100 {
                try write(String(repeating: "content ", count: 1_000),
                          to: url, named: "\(index).md")
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(llm: MockLLMGateway(response: "unused"))

        let task = Task { await state.attachContextFolder(url: root) }
        task.cancel()
        await task.value

        #expect(state.contextFolders.isEmpty)
        #expect(state.lastError == nil)
        #expect(!state.contextImporting)
    }

    @Test("folder errors never expose the selected raw path")
    @MainActor
    func errorsRedactRawPath() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-client-name/\(UUID().uuidString)/missing")
        let state = AppState(llm: MockLLMGateway(response: "unused"))

        await state.attachContextFolder(url: missing)

        #expect(state.lastError != nil)
        #expect(state.lastError?.contains(missing.path) == false)
    }

    @Test("refresh failure is index-safe and never exposes the stored path")
    @MainActor
    func rescanFailureIsSafeAndRedacted() async throws {
        let root = try makeFolder { url in
            try write("temporary project context", to: url, named: "README.md")
        }
        let state = AppState(llm: MockLLMGateway(response: "unused"))
        await state.attachContextFolder(url: root)
        let id = try #require(state.contextFolders.first?.id)
        try FileManager.default.removeItem(at: root)

        await state.rescanContextFolder(id: id)

        #expect(state.contextFolders.count == 1)
        #expect(state.lastError?.contains("Не удалось обновить") == true)
        #expect(state.lastError?.contains(root.path) == false)
        #expect(!state.contextImporting)
    }

    @Test("folder contents reach the composed context tagged with their folder")
    @MainActor
    func foldersReachComposedContext() async throws {
        let root = try makeFolder { url in
            try write("Ship the connector.", to: url, named: "README.md")
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AppState(llm: MockLLMGateway(response: "unused"))
        await state.attachContextFolder(url: root)

        #expect(state.contextFolders.count == 1)
        // Two folders can both hold a README; the folder name is what tells the
        // model which project it belongs to.
        #expect(state.composedContext.contains("\(root.lastPathComponent)/README.md"))
        #expect(state.composedContext.contains("Ship the connector."))
        #expect(state.allContextFiles.count == 1)
        #expect(state.totalContextChars > 0)

        state.detachContextFolder(id: state.contextFolders[0].id)
        #expect(state.contextFolders.isEmpty)
        #expect(state.composedContext.isEmpty)
    }
}
