import SwiftUI

/// Which of the three window panes are visible — sidebar, transcript,
/// assistant. Backlog item 3: the window can be a transcript-only reading
/// pane, an assistant-only answer pane, or any other combination.
///
/// One invariant carries the whole design: **at least one pane is always
/// visible.** Toggling the last visible pane is a no-op rather than an error,
/// and a persisted value that decodes to all-hidden is corrected on read — a
/// window with zero panes is not a layout, it is a bug with a memory.
struct PaneLayout: Equatable, Codable {
    var sidebar: Bool
    var transcript: Bool
    var assistant: Bool

    static let all = PaneLayout(sidebar: true, transcript: true, assistant: true)

    enum Pane: String, CaseIterable {
        case sidebar, transcript, assistant

        /// Menu titles. "Transcript" not "Meeting column": named for what the
        /// user reads, not for the type that renders it.
        var title: String {
            switch self {
            case .sidebar: return "Sidebar"
            case .transcript: return "Transcript"
            case .assistant: return "Assistant"
            }
        }
    }

    func isVisible(_ pane: Pane) -> Bool {
        switch pane {
        case .sidebar: return sidebar
        case .transcript: return transcript
        case .assistant: return assistant
        }
    }

    var visibleCount: Int {
        [sidebar, transcript, assistant].filter { $0 }.count
    }

    /// The layout with `pane` flipped — unless that would hide the last
    /// visible pane, in which case the layout is returned unchanged.
    func toggling(_ pane: Pane) -> PaneLayout {
        if isVisible(pane) && visibleCount == 1 { return self }
        var next = self
        switch pane {
        case .sidebar: next.sidebar.toggle()
        case .transcript: next.transcript.toggle()
        case .assistant: next.assistant.toggle()
        }
        return next
    }

    // MARK: - Persistence

    /// Decode a persisted value, correcting anything unusable to `.all`.
    /// Junk, an old schema, or a legally-encoded all-hidden state all land on
    /// the default — the failure mode of a bad layout must be "everything
    /// visible", never "nothing visible".
    static func decode(_ raw: String?) -> PaneLayout {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PaneLayout.self, from: data),
              decoded.visibleCount > 0 else { return .all }
        return decoded
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// The store both entry points share: the View-menu commands (MeetGPTApp) and
/// the window layout (ContentView). Its own object rather than a field on
/// AppState so the feature lives in one file — and so commands, which exist
/// outside the window's environment, can reach it without threading state
/// through the scene.
@MainActor
final class PaneLayoutStore: ObservableObject {
    static let shared = PaneLayoutStore()

    @Published private(set) var layout: PaneLayout {
        didSet { UserDefaults.standard.set(layout.encoded, forKey: Self.key) }
    }

    static let key = "layout.panes"

    init(defaults: UserDefaults = .standard) {
        layout = PaneLayout.decode(defaults.string(forKey: Self.key))
    }

    func toggle(_ pane: PaneLayout.Pane) {
        layout = layout.toggling(pane)
    }

    /// Test seam: set a known state without touching UserDefaults semantics.
    func replace(_ layout: PaneLayout) {
        self.layout = layout.visibleCount > 0 ? layout : .all
    }
}

/// The View-menu section. Lives beside the store so the shortcut table is in
/// one place: ⌥⌘1 sidebar, ⌥⌘2 transcript, ⌥⌘3 assistant — option added so
/// plain ⌘1-3 stay free for future tab-style navigation.
struct PaneCommands: Commands {
    @ObservedObject var store: PaneLayoutStore

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(Array(PaneLayout.Pane.allCases.enumerated()), id: \.element) { index, pane in
                Button(store.layout.isVisible(pane) ? "Hide \(pane.title)" : "Show \(pane.title)") {
                    store.toggle(pane)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
    }
}
