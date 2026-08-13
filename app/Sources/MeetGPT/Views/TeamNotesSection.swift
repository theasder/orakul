import SwiftUI
import OrakulCore

/// Настройки → «Подключённые приложения»: база знаний команды.
///
/// Адрес здесь НЕ обязателен, в отличие от трекеров: Outline бывает облачным.
/// Требовать адрес значило бы не пустить тех, у кого он облачный.
struct TeamNotesSection: View {
    @State private var expanded: TeamNotes.Service?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(TeamNotes.Service.allCases, id: \.self) { service in
                TeamNoteRow(
                    service: service,
                    isExpanded: expanded == service,
                    toggle: { expanded = expanded == service ? nil : service })
            }
        }
    }
}

private struct TeamNoteRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    let service: TeamNotes.Service
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var token = ""
    @State private var host = ""
    @State private var isConfigured = false

    private var store: RussianTrackerStore { mcp.trackerStore }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(service.title,
                      systemImage: isConfigured ? "checkmark.seal.fill" : "book.closed")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isConfigured {
                    Button("Отключить") { disconnect() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.notes.\(service.rawValue).disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isConfigured ? "Изменить" : "Подключить")) {
                    toggle()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.notes.\(service.rawValue).connect")
            }

            if isExpanded {
                Text(service.credentialHint)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("", text: $token, prompt: Text("токен"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Токен \(service.title)")
                    .accessibilityIdentifier("settings.notes.\(service.rawValue).token")

                TextField("", text: $host, prompt: Text(service.hostPrompt))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Адрес сервера — \(service.title)")
                    .accessibilityIdentifier("settings.notes.\(service.rawValue).host")

                HStack {
                    Button("Сохранить") { save() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canSave)
                        .accessibilityIdentifier("settings.notes.\(service.rawValue).save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Достаточно токена: пустой адрес означает облако сервиса.
    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        isConfigured = store.notesToken(for: service) != nil
        host = store.notesHost(for: service) ?? ""
    }

    private func save() {
        store.setNotesToken(token, for: service)
        store.setNotesHost(host, for: service)
        token = ""
        load()
    }

    private func disconnect() {
        store.removeNotes(service)
        token = ""; host = ""
        load()
    }
}
