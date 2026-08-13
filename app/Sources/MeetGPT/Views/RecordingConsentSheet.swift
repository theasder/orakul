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
                       "Запись берёт всех участников: ваш микрофон и системный звук звонка.")
                bullet("checkmark.shield",
                       "Во многих странах записывать разговор можно только с согласия всех участников. Предупредить их и получить согласие, где этого требует закон, — ваша ответственность.")
                bullet("lock.laptopcomputer",
                       "Расшифровка по умолчанию идёт на этом компьютере. Куски транскрипта уходят наружу только когда вы сами запускаете действие ИИ.")
            }

            HStack {
                // Ссылок на политику и условия здесь нет намеренно. Раньше они
                // вели на cruxwing.com — чужой документ про чужую обработку
                // данных, и к orakul он отношения не имеет: у orakul нет
                // сервера, куда что-то уходит. Своих страниц пока нет, а
                // ссылка в никуда на экране про согласие хуже её отсутствия.
                // Существенное сказано выше, списком.
                Spacer()
                Button("Не сейчас") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button("Понятно — начать запись") {
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
