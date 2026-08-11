import SwiftUI

/// Shown once, straight after the first real meeting ends.
///
/// Deliberately small. It arrives while the user is trying to leave a call, so
/// it asks the cheapest possible question first — one tap — and treats
/// everything after that as optional. A form here would be answered by nobody
/// and would sour the moment it is trying to learn from.
///
/// Order matters: rating, then the note, then the email. Leading with the email
/// turns feedback into lead capture, which people answer far less often and far
/// less honestly.
struct FirstMeetingFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var rating: FirstMeetingPrompt.Rating?
    @State private var note = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How did that go?")
                    .font(.title3.weight(.semibold))
                Text("Your first call with Cruxwing just ended. One tap tells us more than any download number.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                ratingButton(.good, label: "It worked", symbol: "hand.thumbsup")
                ratingButton(.bad, label: "It didn't", symbol: "hand.thumbsdown")
            }

            // Everything below appears only after a rating. An empty text field
            // on arrival reads as homework, and suppresses the one-tap answer
            // this is mostly here to collect.
            if rating != nil {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("What happened? (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)

                    // No .textContentType(.emailAddress): that overload is
                    // macOS 14+, and the app ships for Ventura. Autofill is not
                    // worth dropping a supported OS for one optional field.
                    TextField("Email, if you're open to a follow-up (optional)", text: $email)
                        .textFieldStyle(.roundedBorder)

                    Text("Nothing else is attached — no transcript, no audio, no meeting name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            HStack {
                // "Not now" is honest about what it does: the prompt will not
                // come back either way, and a label implying otherwise is a lie.
                Button("Не сейчас") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отправить") {
                    guard let rating else { return }
                    // Disk first, network second, and the sheet closes without
                    // waiting for either. Somebody who has just left a call
                    // should not watch a spinner, and a failed upload stays
                    // queued for the next launch rather than costing them the
                    // answer they already typed.
                    FirstMeetingPrompt.record(rating: rating, note: note, email: email)
                    Task { await FeedbackUploader.flush() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rating == nil)
            }
        }
        .padding(22)
        .frame(width: 420)
        .animation(.easeOut(duration: 0.15), value: rating)
    }

    private func ratingButton(
        _ value: FirstMeetingPrompt.Rating, label: String, symbol: String
    ) -> some View {
        Button {
            rating = value
        } label: {
            Label(label, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(rating == value ? .accentColor : .secondary)
        .accessibilityAddTraits(rating == value ? [.isSelected] : [])
    }
}
