import Foundation

/// A saved, reusable bundle of context (files + notes). Lets a user "fix" the
/// context for repeating calls — save it once, re-apply it to any meeting.
struct ContextSet: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var files: [ImportedContextFile]
    var notes: String

    init(id: UUID = UUID(), name: String, files: [ImportedContextFile], notes: String) {
        self.id = id
        self.name = name
        self.files = files
        self.notes = notes
    }

    var sourceCount: Int {
        files.count + (notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }
}
