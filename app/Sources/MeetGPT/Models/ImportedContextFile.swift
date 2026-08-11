import Foundation

struct ImportedContextFile: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    var charCount: Int { text.count }
}
