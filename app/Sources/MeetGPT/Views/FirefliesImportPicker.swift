import SwiftUI

/// Choose a past Fireflies meeting to open as a saved call.
///
/// Reached from the History header, next to New call — both answer "give me a
/// different meeting to work on", one from this Mac and one from Fireflies.
/// Picking one imports it, saves it, and opens it, so the user lands in the
/// call they chose instead of having to find it again in the list they came
/// from.
struct FirefliesImportPicker: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header

            if state.firefliesImportBusy && state.firefliesMeetings.isEmpty {
                loading
            } else if let error = state.firefliesImportError, state.firefliesMeetings.isEmpty {
                failure(error)
            } else {
                list
            }
        }
        .padding(Space.l)
        .frame(width: 460, height: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from Fireflies")
                    .font(.system(size: 14, weight: .semibold))
                Text("Its transcript opens as a saved call — ready for Blind Spots and questions.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var loading: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text("Loading your Fireflies meetings…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { state.loadFirefliesMeetings() }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // A failure AFTER a successful list — an import that could not be
            // read — belongs above the rows, where the user is still choosing.
            if let error = state.firefliesImportError, !state.firefliesMeetings.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(state.firefliesMeetings) { meeting in
                        MeetingRow(meeting: meeting, disabled: state.firefliesImportBusy) {
                            state.importFirefliesMeeting(meeting) { imported in
                                // Close only on success: a failed import leaves
                                // the picker up with its reason, rather than
                                // dropping the user back with nothing to show
                                // for the tap.
                                if imported { isPresented = false }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: FirefliesPastCalls.MeetingSummary
    let disabled: Bool
    let onImport: () -> Void
    @State private var hovering = false

    /// Date, duration and who was there — the three things that let someone
    /// recognise a call whose title is "Weekly sync".
    private var subtitle: String {
        var parts: [String] = []
        if let date = meeting.date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if let seconds = meeting.durationSeconds, seconds > 0 {
            parts.append("\(Int((seconds / 60).rounded())) min")
        }
        if !meeting.participants.isEmpty {
            parts.append(meeting.participants.prefix(3).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onImport) {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Theme.accentText : Theme.inkTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Space.s)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
        .help("Import this meeting and open it")
        .accessibilityLabel("\(meeting.displayTitle). \(subtitle)")
        .accessibilityHint("Imports this Fireflies meeting and opens it as a saved call")
    }
}
