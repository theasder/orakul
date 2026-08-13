import SwiftUI

/// Act 3, in the sidebar. What is left to set up — and nothing that blocks
/// recording.
///
/// Sign-in and connected apps live here rather than in the first-run sheet
/// because both are far easier to say yes to after seeing what the co-pilot
/// produces. Each row disappears when it is satisfied, and the card removes
/// itself when they all are.
struct SetupCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.openSettings) private var openSettings
    @AppStorage("onboarding.setupCardDismissed") private var dismissed = false
    // Ключ намеренно новый, а не переименованный старый: кто отложил вход, тот
    // не откладывал «вставить ключ». Это разные просьбы, и вторая — та самая,
    // без которой не будет ответов модели.
    @AppStorage("onboarding.providerKeyRowDismissed") private var keyDismissed = false

    private var captureVerified: Bool { state.micGranted && state.screenRecordingGranted }
    /// Строка держалась на признаке входа, хотя текст в ней уже был про ключ.
    /// Пока адрес сервера подставлялся сам, признак был ложным и строка
    /// показывалась. Как только адрес перестал подставляться,
    /// `wheesprAvailable` стал false, «вошёл» — true, и единственная строка про
    /// ключ исчезла из установщика целиком.
    private var hasProviderKey: Bool { !ProviderKeyStore.current.configured.isEmpty }
    private var appsConnected: Bool { !mcp.authorizedServerIDs.isEmpty }

    private var showsProviderKeyRow: Bool {
        OnboardingPrompts.showsProviderKeyRow(hasKey: hasProviderKey, dismissed: keyDismissed)
    }

    private var remaining: Int {
        OnboardingPrompts.setupRemaining(captureVerified: captureVerified,
                                         // A row the user put off is not
                                         // outstanding work; counting it leaves
                                         // the card saying "1 left" with nothing
                                         // under it to do.
                                         keyReady: hasProviderKey || keyDismissed,
                                         appsConnected: appsConnected)
    }

    var body: some View {
        if !dismissed, remaining > 0 {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    SectionLabel("Настройка · осталось \(remaining)")
                    Spacer(minLength: 0)
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Скрыть настройку")
                    .accessibilityLabel("Скрыть настройку")
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    // "Verified" would be an overclaim: this row knows the two
                    // permissions are granted, which is exactly the thing the
                    // capture check exists to prove is not the same as working.
                    SetupRow(done: captureVerified, title: "Разрешения на захват выданы")
                    if showsProviderKeyRow {
                        // Раньше здесь предлагался вход ради «моделей без своих
                        // ключей» — обещание сервера, которого у orakul нет.
                        // Человек, дошедший до этой строки, не мог по ней ничего
                        // сделать: она открывала SignInSheet. Настоящий шаг один
                        // — вставить свой ключ, а вводят его в настройках.
                        SetupRow(done: false,
                                 title: "Вставить ключ провайдера — иначе не будет ответов",
                                 action: { openSettings() },
                                 // Шаг необязательный: запись, расшифровка и
                                 // поиск по звонкам работают и без ключа.
                                 onDismiss: { keyDismissed = true })
                    }
                    if !appsConnected {
                        SetupRow(done: false, title: "Подключить Яндекс Трекер, Kaiten, Notion…")
                    }
                    Text("Запись работает и без того, и без другого.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Space.xxs)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    var action: (() -> Void)?
    /// Present on steps the user is allowed to skip for good.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(done ? Theme.speakerYou : Theme.inkTertiary)
            if let action {
                Button(title, action: action)
                    .buttonStyle(QuietButtonStyle(prominent: true))
            } else {
                Text(title).font(Typo.caption)
                    .foregroundStyle(done ? Theme.inkTertiary : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 16))
                .help("Не сейчас — ключ можно вставить в настройках когда угодно")
                .accessibilityLabel("Скрыть: \(title)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(done ? "сделано" : "не сделано")")
    }
}

/// Act 4. The gap between installing and the next real meeting is where installs
/// die, and the recording-type work makes the answer honest: there is something
/// worth recording tonight.
///
/// Shown only while nothing has ever been recorded, never during a recording,
/// and dismissible for good.
struct NoCallTodayCard: View {
    @EnvironmentObject var state: AppState
    @AppStorage("onboarding.noCallCardDismissed") private var dismissed = false

    private var eligible: Bool {
        OnboardingPrompts.showsNoCallCard(
            dismissed: dismissed,
            isRecording: state.isRecording,
            hasSavedSessions: !state.savedSessions.isEmpty,
            lastStep: Config.onboardingStep)
    }

    var body: some View {
        if eligible {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    // Было «До понедельника звонков нет?» — 233 pt в верхнем
                    // регистре при 212 доступных. Заголовок раздвигал боковую
                    // панель, и у КАЖДОЙ строки в ней пропадала первая буква.
                    // SectionLabel теперь такого не позволит, но обрезанный
                    // заголовок — тоже плохо, поэтому строка короче.
                    SectionLabel("До понедельника пусто?")
                    Spacer(minLength: 0)
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Скрыть")
                    .accessibilityLabel("Скрыть подсказку")
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Направьте orakul на то, что вы и так собирались послушать.")
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SuggestedSource(
                        icon: "graduationcap",
                        title: "Доклад или лекция",
                        detail: "Понятия, доводы и открытые вопросы — вместе с планом, что изучить.")
                    SuggestedSource(
                        icon: "mic",
                        title: "Подкаст",
                        detail: "Ведущие и гости разделены, доводы собраны, выдуманных задач нет.")
                    Text("Выберите тип на плашке записи или оставьте автоопределение.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }
}

private struct SuggestedSource: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
