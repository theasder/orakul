import Foundation

/// An image pinned to the next AI message (sent to the vision model).
struct Attachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let imageData: Data

    init(id: UUID = UUID(), name: String, imageData: Data) {
        self.id = id
        self.name = name
        self.imageData = imageData
    }
}

/// What the composer's "+" is asking the file importer to pick.
enum AttachKind: Identifiable {
    case image, file, folder, audio, video
    var id: Int { hashValue }
}
