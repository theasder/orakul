import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right column: the AI workspace. Header + prompt chip cloud on top, the
/// streamed response filling the rest.
struct AIStudioView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @State private var draft: PromptDraft?
    @State private var showWriteback = false
    @State private var exportingDOCX = false
    @State private var exportingElsewhere = false

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.aiStudio)
    }

    @ViewBuilder private var trackedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.l)
                .padding(.top, kContentTopInset)
                .padding(.bottom, Space.m)

            SectionLabel("Промпты")
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)

            // Natural height, always whole rows: with many prompts the tail
            // folds into an inline "+N more" chip (see QuickPromptsBar) —
            // pixel-clipping cut chips mid-row and read as broken.
            // The chip grid is the one block allowed to scroll: in a short
            // window something must give, and it must never be the composer or
            // the response. ViewThatFits picks the PLAIN grid whenever its
            // natural height fits, and only falls back to the scrolling copy
            // when the window is truly too short — unlike the previous
            // ScrollView+layoutPriority pair, which was greedy in TALL windows
            // (a ScrollView's ideal height is unbounded, so priority 1 made it
            // absorb the surplus and open dead space above the budget bar
            // while squeezing the composer).
            ViewThatFits(in: .vertical) {
                QuickPromptsBar(onNewPrompt: { draft = .blank() },
                               onEditPrompt: { draft = .from($0) })
                    .padding(.horizontal, Space.l)
                    .padding(.bottom, Space.s)
                ScrollView {
                    QuickPromptsBar(onNewPrompt: { draft = .blank() },
                                   onEditPrompt: { draft = .from($0) })
                        .padding(.horizontal, Space.l)
                        .padding(.bottom, Space.s)
                }
                .scrollContentBackground(.hidden)
            }

            // The token-increasing options + usage gauge live WITH the
            // buttons they price, not buried in Settings.
            PromptBudgetBar()
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.m)

            Hairline().padding(.horizontal, Space.l)

            ResponseView()
                .frame(minHeight: 160)

            Hairline().padding(.horizontal, Space.l)

            AskComposer(onSaveAsPrompt: { draft = .fromText($0) })
                .padding(Space.l)
        }
        // Adopt the window's height so the composer pins to the bottom and
        // the flexible regions above split what remains.
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $draft) { item in
            PromptEditorView(draft: item).environmentObject(state)
        }
        .sheet(isPresented: $state.showFactCheck) {
            FactCheckSheet().environmentObject(state)
        }
        .sheet(isPresented: $showWriteback) {
            TaskWritebackSheet(tasks: state.currentTaskItems ?? [])
                .environmentObject(mcp)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Ассистент")
                    .font(Typo.title)
                    .foregroundStyle(Theme.ink)
            }
            if state.aiStreaming {
                BreathingDots(tint: Theme.accent).padding(.leading, Space.xs)
            }
            Spacer()
            // Write-back: file the Tasks-button items into a connected tracker.
            if let items = state.currentTaskItems, !items.isEmpty, !state.aiStreaming {
                Button {
                    showWriteback = true
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Отправить задачи в трекер")
                .help("Завести эти задачи в трекере")
            }
            // Refine the visible answer (item 20). User-invoked only; hidden
            // for structured answers (a DACI, a fact check) whose contract a
            // free rewrite would break. Revert restores the pre-refine text
            // while it is still on screen.
            if state.isRefining {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                    .help("Refining…")
            } else {
                if state.canRevertRefine {
                    Button { state.revertRefine() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Вернуть исходный")
                    .help("Вернуть ответ, каким он был до правки")
                }
                if state.canRefineCurrentAnswer {
                    Menu {
                        ForEach(AnswerRefine.Kind.allCases) { kind in
                            Button {
                                state.refineCurrentAnswer(kind)
                            } label: {
                                Label(kind.label, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Уточнить ответ")
                    .help("Сжать или развернуть ответ — ещё один проход ИИ, его можно отменить")
                }
            }
            // One share control rather than a separate Export menu and copy
            // icon. They were gated differently — copy on `hasContent`, export
            // on `canExportAssistantAnswer` — so an answer that failed either
            // check showed a lone copy button and no way to reach Word at all.
            // Copy is now the first item in the same menu it always belonged in.
            if state.hasContent {
                Menu {
                    Button {
                        copyResponse()
                    } label: {
                        Label("Скопировать ответ", systemImage: "doc.on.doc")
                    }
                    .disabled(state.aiStreaming)

                    if !state.aiHistory.isEmpty {
                        Button {
                            copyWholeDialog()
                        } label: {
                            Label("Скопировать весь диалог", systemImage: "doc.on.doc.fill")
                        }
                        .disabled(state.aiStreaming)
                    }

                    if state.canExportAssistantAnswer {
                        Divider()
                        Button {
                            exportResponseAsDOCX()
                        } label: {
                            Label("Документ Word (.docx)", systemImage: "arrow.down.doc")
                        }
                        // Google Docs — only with a Google account connected.
                        if state.canExportToGoogleDocs {
                            Button {
                                exportTo { await state.exportAssistantAnswerToGoogleDocs() }
                            } label: {
                                Label("Google Документы", systemImage: "doc.text")
                            }
                        }
                        // Google Sheets — only when the answer actually contains
                        // a table. One entry per table, each naming its own size,
                        // because "export to Sheets" on an answer with two tables
                        // is an ambiguous instruction.
                        ForEach(state.answerSpreadsheetProposals, id: \.summary) { proposal in
                            Button {
                                exportTo { await state.exportAnswerTableToGoogleSheets(proposal) }
                            } label: {
                                Label(proposal.summary, systemImage: "tablecells")
                            }
                        }
                        // Undo sits next to what it undoes. Creating a file in
                        // someone's Drive should be as cheap to reverse as it was
                        // to do.
                        if let title = state.lastCreatedSpreadsheetTitle {
                            Button {
                                exportTo { await state.undoLastSpreadsheetExport() }
                            } label: {
                                Label("Убрать «\(title)» в корзину", systemImage: "arrow.uturn.backward")
                            }
                        }
                        // Notion — only when Notion is integrated with a create tool.
                        if state.canExportToNotion {
                            Button {
                                exportTo { await state.exportAssistantAnswerToNotion() }
                            } label: {
                                Label("Страница Notion", systemImage: "n.square")
                            }
                        }
                    }
                } label: {
                    if exportingDOCX || exportingElsewhere {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(exportingDOCX || exportingElsewhere)
                .accessibilityLabel("Поделиться ответом")
                .help("Скопировать ответ или выгрузить его — вместе с запросом и слепыми зонами — в Word, Google Docs или Notion")
            }
        }
    }

    /// Run a Google Docs / Notion export with the shared busy flag so the
    /// Export menu shows progress and can't be double-fired.
    private func exportTo(_ action: @escaping () async -> Void) {
        guard !exportingElsewhere else { return }
        exportingElsewhere = true
        Task { @MainActor in
            defer { exportingElsewhere = false }
            await action()
        }
    }

    private func copyResponse() {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Copy the exchange, not just the answer — pasted alone, an answer
        // loses the question it addresses (operator request).
        let prompt = state.aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt.isEmpty
            ? state.aiResponse
            : "\(prompt)\n\n\(state.aiResponse)"
        pb.setString(text, forType: .string)
    }

    private func copyWholeDialog() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(state.dialogClipboardText, forType: .string)
    }

    private func exportResponseAsDOCX() {
        guard !exportingDOCX else { return }
        exportingDOCX = true
        Task { @MainActor in
            defer { exportingDOCX = false }
            do {
                let document = try await state.prepareCurrentAnswerExport()
                let data = try AssistantDOCXExporter.makeDocument(document)
                let panel = NSSavePanel()
                panel.title = "Выгрузить ответ ассистента"
                panel.message = "Сохранит в документ Word ответ, исходный запрос, слепые зоны и заголовок, придуманный моделью."
                panel.prompt = "Выгрузить"
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                if let docx = UTType(filenameExtension: "docx") {
                    panel.allowedContentTypes = [docx]
                }
                let suggested = AssistantDOCXExporter.suggestedFilename(
                    for: document.title, date: document.exportedAt)
                panel.nameFieldStringValue = suggested.lowercased().hasSuffix(".docx")
                    ? suggested
                    : suggested + ".docx"

                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            } catch {
                state.lastError = "Выгрузка в Word не удалась: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Free-form ask composer

/// Synchronous presentation state for files selected in the system importer.
/// AppState owns the resulting image/context data; this small queue closes the
/// otherwise blank interval while that data is read, decoded, or transcribed.
struct ComposerAttachmentFeedback: Equatable {
    enum Kind: Equatable {
        case image, file, folder, audio, video

        init(_ kind: AttachKind) {
            switch kind {
            case .image: self = .image
            case .file:  self = .file
            case .folder: self = .folder
            case .audio: self = .audio
            case .video: self = .video
            }
        }

        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .file:  return "doc"
            case .folder: return "folder"
            case .audio: return "waveform"
            case .video: return "film"
            }
        }
    }

    enum Phase: Equatable {
        case importing
        case ready(contextFileID: UUID)
        case failed
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        let kind: Kind
        var phase: Phase
    }

    private(set) var items: [Item] = []

    var hasImportingItems: Bool {
        items.contains { $0.phase == .importing }
    }

    var hasImportingMedia: Bool {
        items.contains {
            $0.phase == .importing && ($0.kind == .audio || $0.kind == .video)
        }
    }

    /// Returns stable ids so the eventual async completion can update exactly
    /// the selection that started it, even if another import begins meanwhile.
    @discardableResult
    mutating func stage(urls: [URL], kind: AttachKind) -> [UUID] {
        let staged = urls.map {
            Item(id: UUID(), name: $0.lastPathComponent,
                 kind: Kind(kind), phase: .importing)
        }
        items.append(contentsOf: staged)
        return staged.map(\.id)
    }

    /// A successfully decoded image is represented by the real thumbnail in
    /// pendingImages. Only failed placeholders remain in this queue.
    mutating func finishImages(ids: [UUID], imported: [Attachment]) {
        var available = imported
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if let match = available.firstIndex(where: { $0.name == items[index].name }) {
                available.remove(at: match)
                items.remove(at: index)
            } else {
                items[index].phase = .failed
            }
        }
    }

    /// Documents and media become standing context, so their ready chips stay
    /// visible until that exact context file is removed.
    mutating func finishContext(ids: [UUID], imported: [ImportedContextFile]) {
        var available = imported
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if let match = available.firstIndex(where: { $0.name == items[index].name }) {
                let file = available.remove(at: match)
                items[index].phase = .ready(contextFileID: file.id)
            } else {
                items[index].phase = .failed
            }
        }
    }

    /// Successful folders are represented by AppState's persistent folder chip
    /// (including after relaunch); only failed placeholders remain here.
    mutating func finishFolders(ids: [UUID], imported: [ContextFolder]) {
        var available = imported
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if let match = available.firstIndex(where: { $0.name == items[index].name }) {
                available.remove(at: match)
                items.remove(at: index)
            } else {
                items[index].phase = .failed
            }
        }
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func reconcile(contextFileIDs: Set<UUID>) {
        items.removeAll { item in
            switch item.phase {
            case .ready(let id):
                return !contextFileIDs.contains(id)
            case .importing, .failed:
                return false
            }
        }
    }
}

/// A chat-style input so the user can ask the assistant anything, not just run
/// the canned quick prompts. Submits on ↵.
private struct AskComposer: View {
    @EnvironmentObject var state: AppState
    var onSaveAsPrompt: (String) -> Void
    @State private var text = ""
    @State private var attachKind: AttachKind?
    @State private var attachmentFeedback = ComposerAttachmentFeedback()
    /// Folder scans are cancellable from their progress chip. Keying by staged
    /// chip id keeps two rapid selections independent.
    @State private var attachmentTasks: [UUID: Task<Void, Never>] = [:]
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Sending is allowed WHILE an answer streams — `ask` supersedes the run in
    /// flight, which is what pressing ↵ means in a chat. Gating on
    /// `!aiStreaming` made ↵ a silent no-op: reported as "I wrote a message and
    /// it wasn't shown, the app didn't react".
    private var canSend: Bool {
        (!trimmed.isEmpty || !state.pendingImages.isEmpty)
            && !attachmentFeedback.hasImportingItems
    }
    private var allPrompts: [QuickPrompt] {
        QuickPrompts.all.map { state.promptForCurrentRecording($0) }
            + state.customPrompts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !state.pendingImages.isEmpty || !state.contextFolders.isEmpty
                || !attachmentFeedback.items.isEmpty || state.attaching {
                attachmentStrip
            }

            HStack(alignment: .center, spacing: Space.s) {
                attachMenu
                TextField(dictationPlaceholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                dictationButton
                sendButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
        }
        .animation(Motion.quick, value: focused)
        .animation(Motion.quick, value: state.pendingImages)
        .animation(Motion.quick, value: attachmentFeedback)
        // Text pushed from elsewhere (a transcript selection). Appends rather
        // than replaces so a half-typed question survives, and focuses the field
        // because the quote is only half the prompt — the user still asks it.
        .onChange(of: state.composerDraft) { draft in
            guard let draft, !draft.isEmpty else { return }
            let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = existing.isEmpty ? draft : existing + "\n\n" + draft
            state.composerDraft = nil
            focused = true
        }
        .fileImporter(isPresented: importerPresented,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: attachKind != .folder) { result in
            handleImport(result)
        }
        .onChange(of: state.contextFiles.map(\.id)) { ids in
            attachmentFeedback.reconcile(contextFileIDs: Set(ids))
        }
    }

    // MARK: Subviews

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(state.pendingImages) { image in
                    ImageChip(image: image) { state.removeImage(id: image.id) }
                }
                ForEach(state.contextFolders) { folder in
                    ComposerFolderChip(folder: folder) {
                        state.detachContextFolder(id: folder.id)
                    }
                }
                ForEach(attachmentFeedback.items) { item in
                    ComposerAttachmentStatusChip(item: item) {
                        removeAttachment(item)
                    }
                }
                // Preserve feedback for media imports started from another UI,
                // but do not duplicate the named composer chip.
                if state.attaching && !attachmentFeedback.hasImportingMedia {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Расшифровываю…").font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 60)
    }

    private var attachMenu: some View {
        Menu {
            Button { open(.image) } label: { Label("Изображение", systemImage: "photo") }
            Button { open(.file) }  label: { Label("Создать", systemImage: "doc") }
            Button { open(.folder) } label: { Label("Папка…", systemImage: "folder.badge.plus") }
            Button { open(.audio) } label: { Label("Звук", systemImage: "waveform") }
            Button { open(.video) } label: { Label("Видео", systemImage: "film") }
            Divider()
            Menu {
                ForEach(allPrompts) { prompt in
                    Button { text = prompt.prompt; focused = true } label: {
                        Text("\(prompt.icon)  \(prompt.title)")
                    }
                }
            } label: { Label("Начать с промпта", systemImage: "text.badge.star") }
            if !trimmed.isEmpty {
                Button { onSaveAsPrompt(text) } label: { Label("Сохранить как промпт…", systemImage: "bookmark") }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.surfaceHover))
        }
        .menuStyle(.button)   // .borderlessButton is deprecated; .button is the native style
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Приложить картинку, файл, папку, аудио, видео — или вставить подсказку")
    }

    // MARK: Dictation

    private var dictationPlaceholder: String {
        if state.dictationWindowStart != nil {
            return "Беру со звонка — нажмите ещё раз, чтобы применить"
        }
        switch state.dictation.state {
        case .listening:    return "Слушаю — нажмите ещё раз, чтобы остановить"
        case .transcribing: return "Расшифровываю…"
        default:            return "Спросите что угодно, приложите файл или начните с подсказки…"
        }
    }

    /// Toggle rather than hold-to-talk: a hold gesture inside a text field
    /// fights with text selection, and a toggle is reachable from the keyboard.
    ///
    /// Works during a recording too — there it captures a window of the LIVE
    /// transcript (both microphone and system audio) rather than opening a
    /// second capture, so what the other side just said can become the prompt.
    private var dictationButton: some View {
        let dictation = state.dictation
        let fromCall = state.dictationWindowStart != nil
        let capturing = dictation.isListening || fromCall
        let busy = dictation.state == .transcribing
        return Button {
            Task { await state.toggleDictation(into: $text) }
        } label: {
            ZStack {
                Circle()
                    .fill(capturing ? Theme.recordRed.opacity(0.16) : Theme.surfaceHover)
                // A ring that tracks input level, so a dead microphone is
                // visibly dead instead of looking like a slow transcription.
                // Only meaningful for the app's own capture; the call route has
                // the recorder's own meters already on screen.
                if dictation.isListening {
                    Circle()
                        .strokeBorder(Theme.recordRed.opacity(0.55), lineWidth: 1.5)
                        .scaleEffect(1 + CGFloat(min(dictation.level, 1)) * 0.35)
                }
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: capturing ? "mic.fill" : (state.isRecording ? "waveform" : "mic"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(capturing ? Theme.recordRed : Theme.inkSecondary)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(capturing ? "Остановить захват" : "Продиктовать запрос")
        .help(capturing
              ? "Остановить и вставить сказанное"
              : (state.isRecording
                 ? "Взять то, что говорят на звонке, как запрос"
                 : "Продиктовать вместо набора"))
        .animation(Motion.quick, value: capturing)
        .animation(Motion.quick, value: dictation.level)
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(canSend ? .white : Theme.inkTertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(canSend ? Theme.accent : Theme.surfaceHover))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Отправить")
        .help(attachmentFeedback.hasImportingItems
              ? "Дождитесь, пока вложения загрузятся"
              : (canSend ? "Ask (↵)" : "Приложите файл или напишите сообщение"))
    }

    // MARK: Importer

    private var importerPresented: Binding<Bool> {
        Binding(get: { attachKind != nil }, set: { if !$0 { attachKind = nil } })
    }

    private var allowedTypes: [UTType] {
        switch attachKind {
        case .image: return [.image]
        case .file:  return ContextImporter.allowedTypes
        case .folder: return [.folder]
        case .audio: return [.audio]
        case .video: return [.movie, .video, .audiovisualContent]
        case nil:    return [.data]
        }
    }

    private func open(_ kind: AttachKind) { attachKind = kind }

    private func handleImport(_ result: Result<[URL], Error>) {
        let kind = attachKind
        attachKind = nil
        switch result {
        case .failure(let error):
            state.lastError = "Не удалось загрузить: \(error.localizedDescription)"
        case .success(let urls):
            guard let kind, !urls.isEmpty else { return }
            // This mutation is deliberately before Task creation: the very
            // first frame after the picker closes already names every file.
            let stagedIDs = attachmentFeedback.stage(urls: urls, kind: kind)
            let previousImageIDs = Set(state.pendingImages.map(\.id))
            let previousContextIDs = Set(state.contextFiles.map(\.id))
            let previousFolderIDs = Set(state.contextFolders.map(\.id))
            let task = Task { @MainActor in
                defer {
                    for id in stagedIDs { attachmentTasks[id] = nil }
                }
                switch kind {
                case .image:
                    await state.attachImages(urls)
                    guard !Task.isCancelled else { return }
                    let imported = state.pendingImages.filter { !previousImageIDs.contains($0.id) }
                    attachmentFeedback.finishImages(ids: stagedIDs, imported: imported)
                case .file:
                    await state.importContext(from: urls)
                    guard !Task.isCancelled else { return }
                    let imported = state.contextFiles.filter { !previousContextIDs.contains($0.id) }
                    attachmentFeedback.finishContext(ids: stagedIDs, imported: imported)
                case .folder:
                    guard let url = urls.first else { return }
                    await state.attachContextFolder(url: url)
                    guard !Task.isCancelled else { return }
                    let imported = state.contextFolders.filter { !previousFolderIDs.contains($0.id) }
                    attachmentFeedback.finishFolders(ids: stagedIDs, imported: imported)
                case .audio, .video:
                    await state.attachMedia(urls)
                    guard !Task.isCancelled else { return }
                    let imported = state.contextFiles.filter { !previousContextIDs.contains($0.id) }
                    attachmentFeedback.finishContext(ids: stagedIDs, imported: imported)
                }
            }
            for id in stagedIDs { attachmentTasks[id] = task }
        }
    }

    private func removeAttachment(_ item: ComposerAttachmentFeedback.Item) {
        switch item.phase {
        case .importing:
            attachmentTasks[item.id]?.cancel()
            attachmentTasks[item.id] = nil
        case .ready(let contextFileID):
            state.removeContextFile(id: contextFileID)
        case .failed:
            break
        }
        attachmentFeedback.remove(id: item.id)
    }

    private func submit() {
        guard canSend else { return }
        state.ask(text)
        text = ""
    }
}

/// Named progress/ready/error chip for non-image attachments (and for images
/// before their thumbnail data is available).
struct ComposerAttachmentStatusChip: View {
    let item: ComposerAttachmentFeedback.Item
    let onRemove: () -> Void

    private var status: String {
        switch item.phase {
        case .importing:
            if item.kind == .audio || item.kind == .video { return "Расшифровываю…" }
            return item.kind == .folder ? "Строю индекс…" : "Загружаю…"
        case .ready:
            return "Готово"
        case .failed:
            return "Импорт не удался"
        }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if item.phase == .importing {
                        ProgressView().controlSize(.small).scaleEffect(0.55)
                    }
                    Text(status)
                        .font(Typo.caption)
                        .foregroundStyle(item.phase == .failed
                                         ? Theme.recordRed : Theme.inkTertiary)
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.phase == .importing
                                ? "Отменить \(item.name)"
                                : "Убрать \(item.name)")
        }
        .padding(.horizontal, Space.s)
        .frame(height: 44)
        .background(Theme.surfaceHover, in: RoundedRectangle(
            cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Вложение \(item.name), \(status)")
        .help("\(item.name) — \(status)")
    }
}

/// Standing folder context stays visible in the chat composer after Send and
/// after view reconstruction. Its indexed-file count makes the bounded nature
/// of the attachment explicit instead of implying every byte is sent.
struct ComposerFolderChip: View {
    let folder: ContextFolder
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(folder.files.count) indexed")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Убрать папку \(folder.name)")
        }
        .padding(.horizontal, Space.s)
        .frame(height: 44)
        .background(Theme.surfaceHover, in: RoundedRectangle(
            cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Папка \(folder.name), файлов в индексе: \(folder.files.count)")
        .help("Под каждый запрос берутся подходящие куски; папка целиком не отправляется")
    }
}

/// A pinned-image thumbnail with a hover remove control.
private struct ImageChip: View {
    let image: Attachment
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.ink)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Убрать изображение")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .onHover { hovering = $0 }
        .help(image.name)
        .animation(Motion.quick, value: hovering)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = NSImage(data: image.imageData) {
            Image(nsImage: nsImage).resizable().scaledToFill()
        } else {
            Theme.surfaceSunken
        }
    }
}
