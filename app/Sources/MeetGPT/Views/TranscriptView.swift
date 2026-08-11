import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var state: AppState
    /// Diarized label being renamed (drives the rename alert).
    @State private var renamingSpeaker: String?
    @State private var renameText = ""
    @State private var followsLatest = true
    @State private var pendingAutomaticScroll: Task<Void, Never>?
    @State private var lastAutomaticScrollAt: TimeInterval?

    private static let bottomID = "transcript-bottom"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.transcript)
    }

    @ViewBuilder private var trackedBody: some View {
        Group {
            if state.transcript.isEmpty && state.provisionalLines.isEmpty {
                TranscriptEmptyState(recording: state.status == .recording,
                                     transcription: state.transcriptionState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // AppKit rather than a SwiftUI list: `.textSelection(.enabled)`
                // never reports WHAT was selected, so asking about a highlighted
                // phrase is impossible without dropping to NSTextView.
                SelectableTranscriptText(
                    entries: state.transcript,
                    provisional: state.provisionalLines,
                    followsLatest: $followsLatest,
                    onSelectionChange: { state.updateTranscriptSelection($0) },
                    onRenameSpeaker: { speaker in
                        renameText = speaker
                        renamingSpeaker = speaker
                    })
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        JumpToLatestButton(accessibilityLabel: "Jump to latest transcript") {
                            followsLatest = true
                        }
                        .padding(Space.l)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if state.hasTranscriptSelection {
                        TranscriptSelectionBar(
                            onAsk: { state.askAboutTranscriptSelection() },
                            onClear: { state.clearTranscriptSelection() })
                            .padding(.bottom, Space.l)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.spring, value: state.hasTranscriptSelection)
                // The AppKit context menu cannot reach AppState directly, so the
                // "Спросить об этом" item posts and the view forwards it.
                .onReceive(NotificationCenter.default.publisher(for: .transcriptAskAboutSelection)) { _ in
                    state.askAboutTranscriptSelection()
                }
            }
        }
        .alert("Rename speaker", isPresented: Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { applyRename() }
            Button("Отмена", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text("Every \"\(renamingSpeaker ?? "")\" line becomes this name — in the transcript and in what the AI sees.")
        }
    }

    /// Rewrite every entry carrying the old label (ids preserved, so the list
    /// doesn't jump). Renames flow into the AI prompt via SystemInstructions.
    private func applyRename() {
        guard let old = renamingSpeaker else { return }
        let new = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSpeaker = nil
        guard !new.isEmpty, new != old else { return }
        state.transcript = state.transcript.map { entry in
            guard entry.speaker == old else { return entry }
            return TranscriptEntry(id: entry.id, source: entry.source, text: entry.text,
                                   timestamp: entry.timestamp, speaker: new,
                                   transcriptionEngine: entry.transcriptionEngine)
        }
    }

    /// Coalesce provisional/finalized updates onto the next main-loop turn and
    /// re-check reader intent before moving. A manual scroll cancels the task.
    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy) {
        guard followsLatest, pendingAutomaticScroll == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = LiveScrollPolicy.delayUntilNextScroll(
            lastScrollAt: lastAutomaticScrollAt, now: now
        )
        pendingAutomaticScroll = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled, followsLatest else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
            lastAutomaticScrollAt = ProcessInfo.processInfo.systemUptime
            pendingAutomaticScroll = nil
        }
    }
}

// MARK: - Row

/// Floating bar shown while transcript lines are selected. Deliberately over the
/// transcript rather than in a toolbar: the action belongs next to what it acts
/// on, and it disappears the moment the selection does.
private struct TranscriptSelectionBar: View {
    let onAsk: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Text("Selection")
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
            Button("Спросить об этом", action: onAsk)
                .buttonStyle(PrimaryButtonStyle())
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .accessibilityLabel("Снять выделение")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .softShadow()
    }
}

private struct TranscriptRow: View {
    @Environment(\.readingTextScale) private var readingTextScale
    let entry: TranscriptEntry
    let formatter: DateFormatter
    /// Invoked with the diarized label when the user asks to rename it.
    var onRenameSpeaker: (String) -> Void = { _ in }
    var isSelected: Bool = false
    /// `extending` is true for shift-click, which selects through to the anchor.
    var onSelect: (_ extending: Bool) -> Void = { _ in }
    var onAskAbout: () -> Void = {}

    @State private var hovering = false

    private var isYou: Bool { entry.source == .mic }
    private var accent: Color { SpeakerPalette.color(for: entry) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            // Left gutter: colored rule + timestamp
            VStack(spacing: Space.xs) {
                Text(formatter.string(from: entry.timestamp))
                    .font(Typo.mono)
                    .foregroundStyle(Theme.inkTertiary)
                    .monospacedDigit()
            }
            .frame(width: 56, alignment: .trailing)
            .padding(.top, 2)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.55))
                .frame(width: 2.5)

            VStack(alignment: .leading, spacing: Space.xs) {
                // A real diarized name adds information. Source fallbacks are
                // omitted for Local entries because its two audio tracks are
                // not trustworthy speaker identities.
                if let label = entry.attributionLabel {
                    Text(label)
                        .font(Typo.label)
                        .tracking(0.5)
                        .foregroundStyle(accent)
                }
                Text(entry.text)
                    .font(Typo.reading(scale: readingTextScale))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xxs)
        .padding(.horizontal, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(isSelected ? Theme.accentTint : (hovering ? Theme.surfaceHover.opacity(0.5) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        // A plain tap must not steal selection from the text itself, so the
        // whole-line selector lives on the gutter's modifier-click and the
        // context menu rather than on a bare tap over the words.
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { onSelect(false) }
        )
        .simultaneousGesture(
            TapGesture().modifiers(.shift).onEnded { onSelect(true) }
        )
        .contextMenu {
            Button("Спросить об этой реплике") { onSelect(false); onAskAbout() }
            if isSelected {
                Button("Спросить о выделенном") { onAskAbout() }
            }
            Divider()
            Button(isSelected ? "Deselect line" : "Select line") { onSelect(false) }
            if let speaker = entry.speaker {
                Divider()
                Button("Rename \"\(speaker)\"…") { onRenameSpeaker(speaker) }
            }
        }
        .animation(Motion.quick, value: isSelected)
    }
}

// MARK: - Provisional (interim) row

/// The in-progress utterance, dimmed, shown until the finalized line replaces it.
private struct ProvisionalRow: View {
    @Environment(\.readingTextScale) private var readingTextScale
    let source: TranscriptSource
    let text: String

    private var isYou: Bool { source == .mic }
    private var accent: Color { isYou ? Theme.speakerYou : Theme.speakerThem }

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Color.clear.frame(width: 56)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent.opacity(0.35))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(isYou ? "You" : "Them")
                    .font(Typo.label)
                    .tracking(0.5)
                    .foregroundStyle(accent.opacity(0.6))
                Text(text)
                    .font(Typo.reading(scale: readingTextScale))
                    .foregroundStyle(Theme.inkTertiary)   // dimmed = not yet finalized
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Live "transcribing" row

private struct TranscribingRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Color.clear.frame(width: 56)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.recordRed.opacity(0.4))
                .frame(width: 2.5, height: 16)
            BreathingDots(tint: Theme.recordRed)
            Text("Расшифровываю…")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
        }
        .padding(.top, Space.xs)
    }
}

// MARK: - Empty state

private struct TranscriptEmptyState: View {
    let recording: Bool
    let transcription: AppState.TranscriptionState

    private struct Presentation {
        let symbol: String
        let tint: Color
        let soft: Color
        let title: String
        let detail: String
        let showDots: Bool
    }

    /// What to show depends first on whether we're recording, then — while
    /// recording — on the transcription engine's lifecycle, so a first-run
    /// model download or a failure is legible instead of an eternal "Listening".
    private var presentation: Presentation {
        guard recording else {
            return Presentation(
                symbol: "waveform", tint: Theme.accent, soft: Theme.accentSoft,
                title: "Nothing captured yet",
                detail: "Press Start recording to capture system audio and your mic.",
                showDots: false)
        }
        switch transcription {
        case .preparing:
            return Presentation(
                symbol: "arrow.down.circle", tint: Theme.accent, soft: Theme.accentSoft,
                title: "Preparing on-device model",
                detail: "First run downloads the private speech model once (~150 MB). This can take a minute — after that, transcription is instant and never leaves your Mac.",
                showDots: true)
        case .failed(let message):
            return Presentation(
                symbol: "exclamationmark.triangle", tint: Theme.recordRed, soft: Theme.dangerSoft,
                title: "Transcription unavailable",
                detail: "\(message)\n\nCheck your connection, or switch the transcription engine in Settings (Deepgram / Whisper API).",
                showDots: false)
        case .idle, .ready:
            return Presentation(
                symbol: "ear", tint: Theme.recordRed, soft: Theme.dangerSoft,
                title: "Listening to the room",
                detail: "Transcript lines will appear here as people speak.",
                showDots: true)
        }
    }

    var body: some View {
        let p = presentation
        return VStack(spacing: Space.m) {
            ZStack {
                Circle()
                    .fill(p.soft)
                    .frame(width: 64, height: 64)
                Image(systemName: p.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(p.tint)
            }

            VStack(spacing: Space.xs) {
                Text(p.title)
                    .font(Typo.title)
                    .foregroundStyle(Theme.ink)
                Text(p.detail)
                    .font(Typo.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if p.showDots {
                BreathingDots(tint: p.tint).padding(.top, Space.xs)
            }
        }
        .padding(Space.xxl)
    }
}
