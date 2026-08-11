import SwiftUI

/// The floating co-pilot card: recording status, the call goal, and the latest
/// blind-spot suggestions — compact enough to sit beside the meeting window.
struct OverlayView: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    /// Newest few suggestions, newest first.
    private var latest: [Suggestion] { Array(state.suggestions.suffix(3).reversed()) }

    private var goal: String {
        state.callGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header

            if !goal.isEmpty {
                Label(goal, systemImage: "target")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }

            if latest.isEmpty {
                Text(state.isRecording
                     ? (goal.isEmpty ? "Set a goal in Cruxwing to get live suggestions." : "Watching for blind spots…")
                     : "Not recording.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(latest) { suggestion in
                        OverlaySuggestionRow(
                            suggestion: suggestion,
                            onAsk: { state.askSuggestion(suggestion) },
                            onDismiss: { state.dismissSuggestion(id: suggestion.id) })
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(width: 340, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            StatusDot(color: state.isRecording ? Theme.recordRed : Theme.inkTertiary,
                      live: state.isRecording)
            if state.isRecording {
                RecordingElapsedLabel(clock: state.recordingClock)
                    .font(Typo.mono)
                    .foregroundStyle(Theme.ink)
            } else {
                Text("orakul")
                    .font(Typo.mono)
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            Button {
                state.toggleRecording()
            } label: {
                Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    .foregroundStyle(state.isRecording ? Theme.recordRed : Theme.accent)
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .disabled(state.isBusy)
            .accessibilityLabel(state.isRecording ? "Stop recording" : "Start recording")
            .help(state.isRecording ? "Stop recording" : "Start recording")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 20))
            .accessibilityLabel("Скрыть плашку")
            .help("Скрыть плашку")
        }
    }
}

/// One compact suggestion line: kind icon, title, hover actions.
private struct OverlaySuggestionRow: View {
    let suggestion: Suggestion
    let onAsk: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch suggestion.kind {
        case .question:    return Theme.accent
        case .risk:        return Theme.recordRed
        case .missingInfo: return Theme.speakerThem
        case .advice:      return Theme.speakerYou
        // The overlay is a peripheral strip read at a glance, so a hunch gets the
        // tint and the icon but not the claim/test block — that needs the sidebar's
        // width to be readable rather than a wall of small text over the call.
        case .hypothesis:  return Theme.amber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: suggestion.kind.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if hovering, !suggestion.detail.isEmpty {
                    Text(suggestion.detail)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Space.xs)
            // Stable buttons (opacity on hover) — inserting them on hover
            // re-truncated the title under the cursor and hid them from
            // keyboard users.
            Button(action: onAsk) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.35)
            .accessibilityLabel("Спросить ассистента об этой подсказке")
            .help("Send to the assistant")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.35)
            .accessibilityLabel("Скрыть подсказку")
            .help("Скрыть")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
