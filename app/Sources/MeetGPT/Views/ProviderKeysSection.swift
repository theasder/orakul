import SwiftUI

/// Настройки → ИИ: ключи провайдеров.
///
/// Стоит выше выбора модели, потому что модель без ключа не работает. В готовом
/// установщике ключей нет ни одного — это осознанный выбор сборки, — поэтому
/// для скачавшего приложение человека это первый экран, где вообще нужно
/// что-то сделать.
///
/// Ключ вводится один раз и лежит в Связке ключей. Расход идёт по договору
/// пользователя с провайдером: orakul не посредник и денег не берёт.
struct ProviderKeysSection: View {
    /// Хранилище берётся у менеджера подключений, а не создаётся здесь: у него
    /// оно построено на том же `KeychainStore`, что и остальные секреты, и в
    /// тестах это фальшивая Связка ключей.
    @EnvironmentObject private var mcp: MCPConnectionManager
    @State private var expanded: LLMProvider?
    @State private var configured: Set<LLMProvider> = []

    private var store: ProviderKeyStore { mcp.providerKeys }

    /// Порядок: сначала те, что дешевле и достаточно уверенно отвечают
    /// по-русски. Тот же вывод, что в `docs/RESEARCH-AND-PLAN.md`, §3.
    private var providers: [LLMProvider] {
        [.yandexGPT, .deepSeek, .qwen, .zhipu, .moonshot, .openAI, .anthropic, .google]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(providers, id: \.self) { provider in
                ProviderKeyRow(
                    provider: provider,
                    hasKey: configured.contains(provider),
                    isExpanded: expanded == provider,
                    toggle: { expanded = expanded == provider ? nil : provider },
                    onChange: reload)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        // Готов — значит есть всё, что нужно для запроса, а не только ключ.
        configured = Set(LLMProvider.allCases.filter(store.isReady))
    }
}

private struct ProviderKeyRow: View {
    @EnvironmentObject private var mcp: MCPConnectionManager
    let provider: LLMProvider
    let hasKey: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let onChange: () -> Void

    @State private var key = ""
    @State private var secondary = ""
    /// Связка ключей отказала при последней попытке сохранить.
    @State private var saveFailed = false

    private var store: ProviderKeyStore { mcp.providerKeys }

    /// Где взять ключ. «Нужен ключ» без адреса — тот же тупик, что был у
    /// коннекторов к трекерам.
    /// Подсказка живёт у провайдера, рядом с адресом запроса: консоль и
    /// адрес — две половины одного факта, и порознь они уже разъезжались.
    private var hint: String { provider.keyConsoleHint }

    /// Сохранять половину настройки нельзя: провайдер будет выглядеть готовым
    /// и падать на первом же запросе.
    private var canSave: Bool {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard provider.needsSecondary else { return true }
        return !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Label(provider.label,
                      systemImage: hasKey ? "checkmark.seal.fill" : "key")
                    .labelStyle(ConnectedRowLabelStyle())
                    .lineLimit(1)
                Spacer()
                if hasKey {
                    Button("Убрать") {
                        store.remove(provider)
                        key = ""
                        secondary = ""
                        onChange()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).remove")
                }
                Button(isExpanded ? "Свернуть" : (hasKey ? "Заменить" : "Добавить ключ")) {
                    toggle()
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).add")
            }

            if isExpanded {
                if saveFailed {
                    Text("Не удалось записать ключ в Связку ключей. Разблокируйте её "
                         + "(«Связка ключей» → «Вход») и нажмите «Сохранить» ещё раз. "
                         + "Набранное осталось в поле.")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).saveFailed")
                }
                Text(hint)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)

                SecureField("", text: $key, prompt: Text("ключ"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceSunken,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .accessibilityLabel("Ключ \(provider.label)")
                    .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).field")

                if provider.needsSecondary {
                    // У Яндекса ключа мало: без каталога запрос уходит с
                    // моделью, которой сервис не знает.
                    TextField("", text: $secondary,
                              prompt: Text(provider.secondaryPrompt ?? ""))
                        .textFieldStyle(.plain)
                        .font(Typo.callout)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceSunken,
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .accessibilityLabel("\(provider.secondaryPrompt ?? "") — \(provider.label)")
                        .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).secondary")
                }

                HStack {
                    Button("Сохранить") {
                        // Связка ключей умеет отказать: заблокирована, или
                        // строка осталась от прежней подписи бинарника. Раньше
                        // ответ отбрасывали — поле очищалось, раздел
                        // закрывался, провайдер выглядел настроенным, и каждый
                        // запрос падал с «нет ключа». Человек вставлял ключ
                        // снова и снова, потому что интерфейс говорил, что всё
                        // сохранено.
                        let savedKey = store.setKey(key, for: provider)
                        let savedSecondary = store.setSecondary(secondary, for: provider)
                        guard savedKey && savedSecondary else {
                            saveFailed = true
                            return          // поле не чистим: набранное не теряем
                        }
                        saveFailed = false
                        // Сам ключ обратно в поле не поднимаем: показывать
                        // секрет незачем, хватает отметки «есть».
                        key = ""
                        onChange()
                        toggle()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!canSave)
                    .accessibilityIdentifier("settings.ai.key.\(provider.rawValue).save")
                    Spacer()
                }
            }
        }
        .onAppear { secondary = store.secondary(for: provider) ?? "" }
    }
}
