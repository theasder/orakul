import SwiftUI

/// The hero control of the sidebar — a single, full-width record button that
/// shifts between a loud "start" pill and a calm, glowing "stop" state with a
/// live timer.
struct RecordPill: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.toggleRecording()
        } label: {
            HStack(spacing: Space.s) {
                glyph
                Text(label)
                    .font(Typo.headline)
                    .foregroundStyle(foreground)
                Spacer(minLength: 0)
                if state.isSessionLive {
                    RecordingElapsedLabel(clock: state.recordingClock)
                        .font(Typo.monoL)
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, Space.l)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(background)
            .overlay(
                Capsule().strokeBorder(borderColor, lineWidth: isRecording ? 1.5 : 0)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.status == .starting || state.status == .stopping)
        .scaleEffect(hovering && isInteractive ? 1.015 : 1)
        .softShadow(isRecording ? 0.4 : 0.9)
        .shadow(color: isRecording ? Theme.recordRed.opacity(0.18) : .clear, radius: 14, y: 3)
        .onHover { hovering = $0 }
        .keyboardShortcut("r", modifiers: [.command])
        .animation(Motion.spring, value: state.status)
        .animation(Motion.quick, value: hovering)
        .help(state.isSessionLive ? "Остановить и оформить (⌘R)" : "Начать запись (⌘R)")
    }

    private var isRecording: Bool { state.status == .recording }
    private var isInteractive: Bool { state.status == .idle || state.isSessionLive || isError }
    private var isError: Bool { if case .error = state.status { return true } else { return false } }

    @ViewBuilder
    private var glyph: some View {
        switch state.status {
        case .recording:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.recordRed)
                .frame(width: 13, height: 13)
        case .paused:
            // Still the stop square, because that is what the button does —
            // but drawn in the paused colour so the row does not read as live.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.amber)
                .frame(width: 13, height: 13)
        case .starting, .stopping:
            ProgressView().controlSize(.small).scaleEffect(0.8).tint(.white)
        default:
            Circle()
                .fill(.white)
                .frame(width: 13, height: 13)
        }
    }

    private var label: String {
        switch state.status {
        case .idle:     return "Начать запись"
        case .starting: return "Запускаю…"
        case .recording: return "Стоп"
        // Stop still means finish-and-write-up from paused; resume is a
        // separate control, so this button never carries two meanings.
        case .paused:   return "Стоп"
        case .stopping: return "Останавливаю…"
        case .error:    return "Ещё раз"
        }
    }

    @ViewBuilder
    private var background: some View {
        switch state.status {
        case .recording:
            Theme.surface
        case .starting, .stopping:
            Theme.accent.opacity(0.7)
        default:
            LinearGradient(
                colors: [Theme.accent, Theme.accentHover],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var foreground: Color {
        isRecording ? Theme.ink : .white
    }

    private var borderColor: Color {
        isRecording ? Theme.recordRed.opacity(0.55) : .clear
    }
}


/// Pause and resume, beside the stop pill rather than inside it.
///
/// Deliberately a second control. Overloading the primary button would give it
/// two meanings depending on state, which is the ambiguity this whole item
/// exists to remove: stop always finishes and writes up.
struct PauseResumeButton: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        if state.isSessionLive {
            Button {
                if state.isPaused { state.resumeRecording() } else { state.pauseRecording() }
            } label: {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.isPaused ? Theme.amber : Theme.ink)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle().fill(hovering ? Theme.surfaceHover : Theme.surface)
                    )
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(state.isPaused
                  ? "Продолжить (⇧⌘P) — звонок и транскрипт сохраняются"
                  : "Пауза (⇧⌘P) — запись останавливается, звонок не заканчивается")
            .accessibilityLabel(state.isPaused ? "Продолжить запись" : "Поставить запись на паузу")
            .accessibilityIdentifier("recording.pauseResume")
        }
    }
}
