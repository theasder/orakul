import SwiftUI
import UniformTypeIdentifiers

/// Which external document connector a prompt sheet is collecting a link for.
enum SourceKind: Int, Identifiable {
    case doc, sheet, notion
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .doc:    return "Google Doc"
        case .sheet:  return "Google Sheet"
        case .notion: return "Notion page"
        }
    }
    var placeholder: String {
        switch self {
        case .doc:    return "https://docs.google.com/document/d/…"
        case .sheet:  return "https://docs.google.com/spreadsheets/d/…"
        case .notion: return "https://www.notion.so/…"
        }
    }
    var systemImage: String {
        switch self {
        case .doc:    return "doc.richtext"
        case .sheet:  return "tablecells"
        case .notion: return "note.text"
        }
    }
}

/// Sidebar section: files, connected documents, and free-form notes folded into
/// every AI request as additional context. Context sets pin a bundle for reuse.
struct ContextSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @State private var showImporter = false
    @State private var showFolderImporter = false
    @State private var promptKind: SourceKind?
    @State private var showSaveSet = false
    @State private var showMCPImport = false

    private var busy: Bool {
        state.contextImporting || state.firefliesImporting || state.calendarImporting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Header carries the volatile piece (the clear icon) as a fixed-size
            // item so its appearance can never squeeze the toolbar — typing the
            // first note character used to crush the Clear button.
            //
            // The raw character count was removed (operator request): it is not
            // a number anyone acts on, and it read as a limit that does not
            // exist. The token/credit rail under the prompts is where input size
            // actually matters.
            HStack(spacing: Space.s) {
                SectionLabel("Context")
                Spacer()
                if state.totalContextChars > 0 {
                    Button { state.clearAllContext() } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .help("Clear all context (files and notes)")
                    .accessibilityLabel("Clear all context")
                }
            }

            // Two stable controls only — this row cannot overflow the sidebar.
            // Import actions (incl. Fireflies/Agenda) live inside Add source.
            HStack(spacing: Space.xs) {
                addSourceMenu
                if busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                setsMenu
            }
            .padding(.leading, -Space.m) // align the quiet button's text to the label

            if !state.contextFiles.isEmpty {
                VStack(spacing: Space.xs) {
                    ForEach(state.contextFiles) { file in
                        FileChip(file: file) { state.removeContextFile(id: file.id) }
                    }
                }
            }

            if !state.contextFolders.isEmpty {
                VStack(spacing: Space.xs) {
                    ForEach(state.contextFolders) { folder in
                        FolderChip(
                            folder: folder,
                            busy: state.contextImporting,
                            onRefresh: { Task { await state.rescanContextFolder(id: folder.id) } },
                            onRemove: { state.detachContextFolder(id: folder.id) })
                    }
                }
            }

            NotesField(text: $state.contextNotes)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: ContextImporter.allowedTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await state.importContext(from: urls) }
            case .failure(let error):
                state.lastError = "Import failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await state.attachContextFolder(url: url) }
            case .failure(let error):
                state.lastError = "Could not attach folder: \(error.localizedDescription)"
            }
        }
        .sheet(item: $promptKind) { kind in SourcePromptSheet(kind: kind) }
        .sheet(isPresented: $showSaveSet) { SaveSetSheet() }
        .sheet(isPresented: $showMCPImport) { MCPImportSheet() }
    }

    private var addSourceMenu: some View {
        Menu {
            Button { showImporter = true } label: { Label("Files…", systemImage: "paperclip") }
            Button { showFolderImporter = true } label: { Label("Folder…", systemImage: "folder.badge.plus") }
            Button { promptKind = .doc } label: { Label("Google Doc…", systemImage: "doc.richtext") }
            Button { promptKind = .sheet } label: { Label("Google Sheet…", systemImage: "tablecells") }
            Button { promptKind = .notion } label: { Label("Notion page…", systemImage: "note.text") }
            Button { showMCPImport = true } label: { Label("Connected app…", systemImage: "app.connected.to.app.below.fill") }
            if mcp.prefersMCP("fireflies") || state.googleConnected {
                Divider()
            }
            if mcp.prefersMCP("fireflies") {
                Button { Task { await state.importAndEnhanceWithFireflies() } } label: {
                    Label(
                        state.transcript.isEmpty
                            ? "Latest Fireflies transcript"
                            : "Fireflies + enhance transcript",
                        systemImage: "flame"
                    )
                }
                .disabled(state.firefliesImporting || state.enhancingTranscript)
            }
            if state.googleConnected {
                Button { Task { await state.pullAgenda() } } label: {
                    Label("Calendar agenda", systemImage: "calendar")
                }
                .disabled(state.calendarImporting)
            }
        } label: {
            Label("Add source", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle(prominent: true))
        .fixedSize()
        .disabled(state.contextImporting)
    }

    @ViewBuilder
    private var setsMenu: some View {
        Menu {
            Button("Save current as set…") { showSaveSet = true }
                .disabled(state.totalContextChars == 0)
            if !state.contextSets.isEmpty {
                Divider()
                ForEach(state.contextSets) { set in
                    Menu("\(set.name) · \(set.sourceCount)") {
                        Button("Apply") { state.applyContextSet(id: set.id) }
                        Button("Delete", role: .destructive) { state.deleteContextSet(id: set.id) }
                    }
                }
            }
        } label: {
            Label("Sets", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle())
        .fixedSize()
    }

}

// MARK: - Connector link prompt

private struct SourcePromptSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.dismiss) private var dismiss
    let kind: SourceKind
    @State private var link = ""

    /// Notion resolves through the keyless MCP connection (Connected apps).
    private var notionViaMCP: Bool { mcp.prefersMCP("notion") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Attach a \(kind.title)", systemImage: kind.systemImage)
                .font(Typo.title)
                .foregroundStyle(Theme.ink)
            Text("Paste the link. Its text is added as a context source.")
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
            if kind == .notion, !notionViaMCP {
                Text("Connect Notion first: Settings → Connected apps (one click, no keys).")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.accentText)
            }
            if kind != .notion, !state.googleHasDocsScope {
                Text("Connect Google (Settings) with Docs & Sheets access first.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.accentText)
            }
            TextField("", text: $link, prompt: Text(kind.placeholder))
                .textFieldStyle(.plain)
                .padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Add") {
                    let url = link
                    dismiss()
                    Task {
                        switch kind {
                        case .doc:    await state.importGoogleDoc(from: url)
                        case .sheet:  await state.importGoogleSheet(from: url)
                        case .notion: await importNotionViaMCP(url: url)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
        .background(Theme.canvas)
    }

    /// Fetch the pasted page through the keyless MCP connection.
    @MainActor
    private func importNotionViaMCP(url: String) async {
        guard !state.contextImporting else { return }
        state.contextImporting = true
        defer { state.contextImporting = false }
        do {
            let document = try await mcp.notionFetchDocument(urlOrID: url)
            state.contextFiles.append(ImportedContextFile(name: "Notion · \(document.title)",
                                                          text: document.text))
            state.lastError = nil
        } catch {
            state.lastError = error.localizedDescription
        }
    }
}

// MARK: - Save context set

private struct SaveSetSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Save context set", systemImage: "square.stack.3d.up")
                .font(Typo.title)
                .foregroundStyle(Theme.ink)
            Text("Save the current files + notes as a reusable set you can apply to a future call.")
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
            TextField("", text: $name, prompt: Text("e.g. Acme weekly sync"))
                .textFieldStyle(.plain)
                .padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button("Save") { state.saveContextSet(name: name); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
        .background(Theme.canvas)
    }
}

private struct FileChip: View {
    let file: ImportedContextFile
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(Typo.callout)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: Space.xs)
            // Always rendered (so it is keyboard-reachable); hover just raises it.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.4)
            .accessibilityLabel("Remove \(file.name)")
            .help("Remove")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(file.name)
        .animation(Motion.quick, value: hovering)
    }
}

/// An attached folder. Unlike a file chip this carries a count and a refresh,
/// because a folder's contents change under the user and a stale scan that looks
/// identical to a fresh one is how a request quietly runs on last week's files.
private struct FolderChip: View {
    let folder: ContextFolder
    let busy: Bool
    let onRefresh: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        let files = "\(folder.files.count) file\(folder.files.count == 1 ? "" : "s")"
        return folder.skipped.isEmpty ? files : "\(files) · \(folder.skipped.count) left out"
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(Typo.callout)
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(folder.skipped.isEmpty ? Theme.inkTertiary : Theme.amber)
            }
            Spacer(minLength: Space.xs)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .disabled(busy)
            .opacity(hovering ? 1 : 0.4)
            .accessibilityLabel("Refresh \(folder.name)")
            .help("Re-read this folder")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.4)
            .accessibilityLabel("Detach \(folder.name)")
            .help("Detach")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(folder.path)
        .animation(Motion.quick, value: hovering)
    }
}

private struct NotesField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(Typo.callout)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(Space.s)
                .frame(minHeight: 84, maxHeight: 180)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: 1)
                )
                .focused($focused)

            if text.isEmpty {
                Text("Agenda, prior decisions, bios, links…")
                    .font(Typo.callout)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, Space.m)
                    .padding(.leading, Space.m)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.quick, value: focused)
    }
}
