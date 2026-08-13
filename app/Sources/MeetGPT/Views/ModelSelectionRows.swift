import SwiftUI

/// Two-tier AI model selection: Provider → Version, both defaulting to Auto.
///
/// - Provider "Auto" = full orchestration across every configured provider
///   (per-request routing; Premium's hardest requests may use the Council).
/// - A concrete provider + version "Auto" = the best stable version of that
///   provider for each request (manual override still one click away).
/// - Only CONFIGURED providers appear — no dead options, no key prompts. With
///   the managed backend (LLM_GATEWAY=backend) all providers are served.
struct ModelSelectionRows: View {
    @EnvironmentObject var state: AppState
    @State private var provider = Config.selectedProvider
    @State private var version = Config.selectedVersion

    private var tier: Tier { state.currentTier }
    private var providers: [LLMProvider] { LLMCatalog.configuredProviders(for: tier) }
    private var pinned: LLMProvider? { LLMProvider(rawValue: provider) }

    /// Transparency: tell the user where their meeting content goes for the
    /// current selection — which providers a council fans out to, and that the
    /// premium Auto path can convene the mixed US+international council.
    private var councilNote: String? {
        if let level = OrchestrationLevel.from(selection: provider) {
            return "Совет моделей · \(level.label): \(level.memberModelIDs.count) моделей отвечают параллельно — \(level.blurb) — потом ответы сводятся в один. Длинный запрос стоит дороже у провайдера."
        }
        switch provider {
        case LLMCatalog.councilUS:
            return "Совет моделей · США: параллельно спрашиваются настроенные американские провайдеры (OpenAI, Anthropic, Google), ответы сводятся в один. Данные остаются у американских компаний."
        case LLMCatalog.councilCN:
            return "Совет моделей · Китай: параллельно спрашиваются настроенные китайские провайдеры (DeepSeek, Qwen, Zhipu, Moonshot). Содержимое звонка уходит к ним."
        default:
            if provider == LLMCatalog.autoID, tier == .premium {
                return "На самых сложных запросах «Авто» может собрать совет из моделей США и Китая. Выберите «Совет моделей · США», чтобы данные уходили только американским провайдерам."
            }
            return nil
        }
    }

    var body: some View {
        row(label: "Provider", icon: "building.2") {
            Picker("", selection: $provider) {
                Text("Автоматически · все поставщики (рекомендуем)").tag(LLMCatalog.autoID)

                // Price-tiered orchestration councils — multi-model panels the
                // backend runs, gated by the caller's tariff (strongest first).
                if Config.llmViaBackend {
                    let levels = OrchestrationLevel.available(for: tier)
                    if !levels.isEmpty {
                        Divider()
                        ForEach(levels.reversed()) { level in
                            Text("Совет моделей · \(level.label) — \(level.blurb)")
                                .tag(level.selectionID)
                        }
                    }
                }
                // Single-jurisdiction councils (direct-key builds only).
                if LLMCatalog.councilAvailable(.us, for: tier) {
                    Text("Совет · США 🇺🇸 (GPT + Claude + Gemini)").tag(LLMCatalog.councilUS)
                }
                if LLMCatalog.councilAvailable(.china, for: tier) {
                    Text("Совет · Китай 🇨🇳 (DeepSeek + Qwen и другие)").tag(LLMCatalog.councilCN)
                }

                if !providers.isEmpty { Divider() }
                ForEach(providers, id: \.rawValue) { provider in
                    Text(provider.label).tag(provider.rawValue)
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: 280)
            .onChange(of: provider) { newValue in
                Config.selectedProvider = newValue
                version = LLMCatalog.autoID          // provider change resets version
                Config.selectedVersion = version
            }
            .accessibilityLabel("Поставщик модели")
            .accessibilityIdentifier("settings.ai.provider")
        }
        .onAppear {
            provider = Config.selectedProvider
            version = Config.selectedVersion
        }

        if let pinned {
            row(label: "Version", icon: "number") {
                Picker("", selection: $version) {
                    Text("Автоматически · самая стабильная").tag(LLMCatalog.autoID)
                    Divider()
                    ForEach(LLMCatalog.versions(of: pinned, for: tier)) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .onChange(of: version) { Config.selectedVersion = $0 }
                .accessibilityLabel("Версия модели")
                .accessibilityIdentifier("settings.ai.model-version")
            }
        }

        if providers.isEmpty {
            Text("Пока не вставлен ни один ключ. Добавьте его выше — «Ключи провайдеров» — и модели этого провайдера появятся здесь.")
                .font(Typo.caption)
                .foregroundStyle(Theme.accentText)
        }

        if let councilNote {
            Text(councilNote)
                .font(Typo.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(label: String, icon: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.m) {
            Label(label, systemImage: icon)
                .labelStyle(ModelRowLabelStyle())
            Spacer()
            content()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

private struct ModelRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            configuration.title
                .font(Typo.callout.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
