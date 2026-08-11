import SwiftUI

/// One-time consent gate before the first recording (launch loop M10.1).
/// A meeting recorder captures OTHER people — App Review expects the app to put
/// consent responsibility in front of the operator, and several jurisdictions
/// require all-party consent. Recording cannot start until this is affirmed.
struct RecordingConsentSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.m) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Перед записью")
                    .font(Typo.title)
                    .foregroundStyle(Theme.ink)
            }

            VStack(alignment: .leading, spacing: Space.m) {
                bullet("person.2.wave.2",
                       "Recording captures everyone on the call — your microphone and the meeting's system audio.")
                bullet("checkmark.shield",
                       "Many jurisdictions require every participant's consent to record. You are responsible for telling participants and obtaining consent where the law requires it.")
                bullet("lock.laptopcomputer",
                       "Transcription runs on this Mac by default. Transcript excerpts leave your device only when you run an AI action.")
            }

            HStack {
                Link("Privacy policy", destination: URL(string: "https://cruxwing.com/privacy")!)
                    .font(Typo.caption)
                Link("Terms", destination: URL(string: "https://cruxwing.com/terms")!)
                    .font(Typo.caption)
                Spacer()
                Button("Не сейчас") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button("I understand — start recording") {
                    state.acceptRecordingConsent()
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .background(Theme.canvas)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
