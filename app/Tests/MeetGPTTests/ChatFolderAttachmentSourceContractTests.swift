import Foundation
import Testing
@testable import MeetGPT

/// SwiftUI's system file importer cannot be driven headlessly, so this narrow
/// source contract complements the executable state/chip tests: it proves the
/// chat composer (not only the sidebar Context panel) exposes directory picking
/// and routes the selected URL into the bounded folder attachment pipeline.
@Suite("Chat folder attachment source contract")
struct ChatFolderAttachmentSourceContractTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("chat plus menu selects folders and indexes them asynchronously")
    func composerFolderPickerContract() throws {
        let source = try read("Sources/MeetGPT/Views/AIStudioView.swift")
        #expect(source.contains("Button { open(.folder) }"))
        #expect(source.contains("case .folder: return [.folder]"))
        #expect(source.contains("allowsMultipleSelection: attachKind != .folder"))
        #expect(source.contains("await state.attachContextFolder(url: url)"))
        #expect(source.contains("Строю индекс…"))
    }

    @Test("standing folder chips render from AppState and can be removed")
    func persistentChipContract() throws {
        let source = try read("Sources/MeetGPT/Views/AIStudioView.swift")
        #expect(source.contains("ForEach(state.contextFolders)"))
        #expect(source.contains("ComposerFolderChip(folder: folder)"))
        #expect(source.contains("state.detachContextFolder(id: folder.id)"))
    }

    @Test("recursive scanning is cancellable, bounded, and off the UI actor")
    func scannerSafetyContract() throws {
        let source = try read("Sources/MeetGPT/Context/ContextFolder.swift")
        #expect(source.contains("Task.detached(priority: .userInitiated)"))
        #expect(source.contains("withTaskCancellationHandler"))
        #expect(source.contains("maxFileBytes"))
        #expect(source.contains("maxTotalBytes"))
        #expect(source.contains("maxEnumeratedEntries"))
        #expect(source.contains("isSymbolicLinkKey"))
        #expect(source.contains("skipsPackageDescendants"))
    }

    @Test("model pipelines use query-time folder retrieval")
    func requestEconomyContract() throws {
        let source = try read("Sources/MeetGPT/AppState.swift")
        #expect(source.contains("func promptContext(query: String)"))
        #expect(source.contains("ContextFolderRetriever.render("))
        #expect(!source.contains("let context = composedContext"))
        #expect(!source.contains("let context = self.composedContext"))
    }
}
