import SwiftUI
import OrakulCore

/// Настройки → «Подключённые приложения»: открытые трекеры на своём сервере.
///
/// Отдельно от GitHub: у того адрес зашит (`api.github.com`), а GitLab и Gitea
/// команда поднимает у себя — без поля адреса подключать некуда.
struct SelfHostedTrackersSection: View {
    @State private var expanded: SelfHostedTrackers.Service?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(SelfHostedTrackers.Service.allCases, id: \.self) { service in
                SelfHostedTrackerRow(
                    service: service,
                    isExpanded: expanded == service,
                    toggle: { expanded = expanded == service ? nil : service })
            }
        }
    }
}

private struct SelfHostedTrackerRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    let service: SelfHostedTrackers.Service
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
                      systemImage: isConfigured ? "checkmark.seal.fill" : "server.rack")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if isConfigured {
                    Button("Отключить") { disconnect() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.selfhosted.\(service.rawValue).disconnect")
                }
                Button(isExpanded ? "Свернуть" : (isConfigured ? "Изменить" : "Подключить")) {
                    toggle()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.selfhosted.\(service.rawValue).connect")
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
                    .accessibilityIdentifier("settings.selfhosted.\(service.rawValue).token")

                TextField("", text: $host, prompt: Text(service.hostPrompt))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Адрес сервера — \(service.title)")
                    .accessibilityIdentifier("settings.selfhosted.\(service.rawValue).host")

                HStack {
                    Button("Сохранить") { save() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canSave)
                        .accessibilityIdentifier("settings.selfhosted.\(service.rawValue).save")
                    Spacer()
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Токен без адреса некуда отправить, адрес без токена вернёт 401.
    private var canSave: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        isConfigured = store.selfHostedToken(for: service) != nil
        host = store.selfHostedHost(for: service) ?? ""
    }

    private func save() {
        store.setSelfHostedToken(token, for: service)
        store.setSelfHostedHost(host, for: service)
        token = ""
        load()
    }

    private func disconnect() {
        store.removeSelfHosted(service)
        token = ""; host = ""
        load()
    }
}
