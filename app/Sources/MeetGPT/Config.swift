import Foundation

/// Which engine powers the live transcript.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Codable {
    case local
    case server
    case deepgram
    case whisper

    var id: String { rawValue }

    /// Engines shown in Settings. `.server` (Cruxwing large-v3) is offered
    /// whenever a backend is configured in this build — availability (sign-in)
    /// is explained by the row itself rather than hiding the option.
    /// Rows Settings offers. Both "Accurate" engines are withheld for now:
    ///
    ///  - `.server` (large-v3 on Cruxwing) was withheld because the backend had
    ///    no box behind it. That premise expired: `api.cruxwing.ai` resolves and
    ///    answers (`/health` → ok). The row stays withheld pending a check that
    ///    the deployed box actually serves transcription at usable latency —
    ///    reachable is not the same as ready.
    ///  - `.whisper` is bring-your-own-OpenAI-key, which contradicts the app
    ///    going keyless, and rendered as a second row also titled "Accurate".
    ///
    /// Neither engine is deleted — `engineAvailable` still governs them and a
    /// saved preference keeps working — so restoring a row is deleting a line
    /// from `withheld` once the box is deployed.
    static let withheld: Set<TranscriptionEngine> = [.server, .whisper]

    static var selectableCases: [TranscriptionEngine] {
        allCases.filter { !withheld.contains($0) }
    }

    var label: String {
        switch self {
        case .local:    return "На устройстве · Whisper"
        case .server:   return "На сервере · large-v3"
        case .deepgram: return "Deepgram · вживую, с говорящими"
        case .whisper:  return "Whisper · кусками через OpenAI"
        }
    }

    // Advantage-first presentation (Settings): users pick a trade-off, not a
    // vendor name.
    var advantageTitle: String {
        switch self {
        case .local:    return "Приватно — считается на этом компьютере"
        case .server:   return "Точно — large-v3 на сервере"
        case .deepgram: return "Мгновенно — пословно и с именами говорящих"
        case .whisper:  return "Точно — по вашему ключу"
        }
    }
    // The frame (D35): every option answers the four things businesses ask —
    // privacy, accuracy, speed, price — and all engines transcribe live, so
    // the copy contrasts latency without implying only one option is "live".
    var advantageCaption: String {
        switch self {
        // Про кредиты здесь больше нет ни слова: их не существует. Раньше в
        // каждой строке стояла цена в кредитах — «Free — no credits», «≈4 min
        // per credit», — и это был единственный оставшийся на экране счёт за
        // то, за что orakul денег не берёт.
        case .local:    return "Звук не уходит с компьютера, работает без сети. Точность приличная, по силам вашего процессора. Титры отстают на пару секунд. Бесплатно."
        case .server:   return "Лучшая точность — large-v3 и модели под язык на сервере; звук стирается после расшифровки. Титры отстают на пару секунд, нужен вход."
        case .deepgram: return "Самый быстрый транскрипт, сразу видно кто говорит; звук идёт в облако Deepgram. Платите Deepgram по своему ключу."
        case .whisper:  return "По вашему ключу OpenAI: расход идёт по вашему договору. Титры отстают на пару секунд."
        }
    }
    var advantageSymbol: String {
        switch self {
        case .local:    return "lock.laptopcomputer"
        case .server:   return "server.rack"
        case .deepgram: return "bolt"
        case .whisper:  return "scope"
        }
    }
}

/// Process-local credential snapshot. Security.framework access is intentionally
/// excluded: Config getters are used from MainActor workflows and must remain a
/// bounded in-memory operation while recording or laying out the app.
final class CredentialMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var google: GoogleTokens?
    private var wheespr: WheesprSession?
    private var googleRevision: UInt64 = 0
    private var wheesprRevision: UInt64 = 0

    func googleTokens() -> GoogleTokens? {
        lock.lock(); defer { lock.unlock() }
        return google
    }

    func wheesprSession() -> WheesprSession? {
        lock.lock(); defer { lock.unlock() }
        return wheespr
    }

    func setGoogleTokens(_ value: GoogleTokens?) {
        lock.lock(); google = value; googleRevision &+= 1; lock.unlock()
    }

    func setWheesprSession(_ value: WheesprSession?) {
        lock.lock(); wheespr = value; wheesprRevision &+= 1; lock.unlock()
    }

    func revisions() -> (google: UInt64, wheespr: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (googleRevision, wheesprRevision)
    }

    func installGoogleTokens(_ value: GoogleTokens?, ifRevisionIs expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard googleRevision == expected else { return false }
        google = value
        return true
    }

    func installWheesprSession(_ value: WheesprSession?, ifRevisionIs expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard wheesprRevision == expected else { return false }
        wheespr = value
        return true
    }
}

/// Process-local gate used only by the nonce-confined live-test surface.
///
/// A developer can persist a plan preview in Settings. Live tests must exercise
/// the server account they actually redeemed, but deleting that preference is
/// unsafe: a crash would lose it and intermediate Settings restores would
/// re-apply it. This locked flag masks the preview for the lifetime of the test
/// process without ever mutating UserDefaults.
final class DevTierPreviewRuntimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = false

    func isSuppressed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressed
    }

    func setSuppressed(_ value: Bool) {
        lock.lock(); suppressed = value; lock.unlock()
    }
}

enum Config {
    private static let credentialCache = CredentialMemoryCache()
    private static let devTierPreviewRuntimeGate = DevTierPreviewRuntimeGate()
    private static let credentialPersistenceQueue = DispatchQueue(
        label: "ai.wheespr.meetgpt.credential-persistence",
        qos: .utility)
    // MARK: Ключи провайдеров
    //
    // Два источника, порядок важен: сначала ключ, введённый в настройках
    // (`ProviderKeyStore`, Связка ключей), потом зашитый при сборке из
    // `mac/.env`.
    //
    // У Cruxwing пользовательский ввод убрали, когда появился серверный шлюз:
    // ключи уехали на сервер. orakul этот код унаследовал, но сервера у него
    // нет, а в готовые установщики ключи не зашиваются намеренно — без ввода
    // в настройках ИИ-ответы там не работают вовсе.
    static var openAIAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .openAI, baked: Secrets.openAIAPIKey)
    }
    static var anthropicAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .anthropic, baked: Secrets.anthropicAPIKey)
    }
    static var googleAIAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .google, baked: Secrets.googleAIAPIKey)
    }
    /// У Яндекса зашитого ключа нет вовсе: провайдер появился уже после того,
    /// как ключи перестали попадать в сборку. Значит, только из настроек.
    static var yandexGPTAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .yandexGPT, baked: "")
    }
    static var deepgramAPIKey: String { Secrets.deepgramAPIKey }
    static var assemblyAIAPIKey: String { Secrets.assemblyAIAPIKey }
    static var deepSeekAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .deepSeek, baked: Secrets.deepSeekAPIKey)
    }
    static var dashScopeAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .qwen, baked: Secrets.dashScopeAPIKey)
    }
    static var zhipuAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .zhipu, baked: Secrets.zhipuAPIKey)
    }
    static var moonshotAPIKey: String {
        ProviderKeyStore.current.resolvedKey(for: .moonshot, baked: Secrets.moonshotAPIKey)
    }
    static var hubSpotClientID: String { Secrets.hubSpotClientID }
    static var hubSpotClientSecret: String { Secrets.hubSpotClientSecret }
    static var affinityClientID: String { Secrets.affinityClientID }
    static var affinityClientSecret: String { Secrets.affinityClientSecret }
    static var zoomClientID: String { Secrets.zoomClientID }
    static var zoomClientSecret: String { Secrets.zoomClientSecret }
    /// Deliberately NOT `googleClientID`. Gmail's read scopes are Restricted,
    /// and verification tiers apply per consent screen — sharing a client would
    /// drag sign-in and the Calendar/Docs/Sheets grant into the Restricted tier
    /// with it. Separate Cloud project, separate client, separate blast radius.
    /// Sign-in uses its own Google client when one is configured.
    ///
    /// Not a nicety — it is what unblocks public sign-up. One Cloud project has
    /// ONE consent screen, and this project's screen also requests Calendar,
    /// Docs, Sheets and Drive. Those are sensitive scopes, so the screen cannot
    /// be published externally without Google's verification review, which
    /// leaves it in Testing — and a Testing screen admits only the handful of
    /// accounts listed on it. That is why sign-in worked for exactly one email.
    ///
    /// A separate project whose screen asks only for `openid email profile`
    /// needs no verification and publishes immediately. The backend already
    /// accepts a LIST in GOOGLE_NATIVE_CLIENT_IDS, so both clients can be valid
    /// at once and connectors keep working while the sensitive screen waits for
    /// review. Falls back to the connector client when unset, so nothing
    /// changes for an installation that has not split them.
    static var googleSignInClientID: String {
        let dedicated = Secrets.googleSignInClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return dedicated.isEmpty ? googleClientID : dedicated
    }
    static var googleSignInClientSecret: String {
        let dedicated = Secrets.googleSignInClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return dedicated.isEmpty ? googleClientSecret : dedicated
    }

    static var gmailClientID: String { Secrets.gmailClientID }
    static var gmailClientSecret: String { Secrets.gmailClientSecret }
    /// Separate from googleClientID for the same reason Gmail is: the consent
    /// screen carries the verification tier, so an analytics grant must not be
    /// able to drag sign-in along with it.
    static var googleAnalyticsClientID: String { Secrets.googleAnalyticsClientID }
    static var googleAnalyticsClientSecret: String { Secrets.googleAnalyticsClientSecret }

    // MARK: Team token connectors (no-MCP fallback: Slack bot, Confluence)
    // — see Integrations/TeamConnectors.swift.
    static var slackBotToken: String { Secrets.slackBotToken }
    static var slackChannelIDs: [String] { splitList(Secrets.slackChannelIDs) }
    static var confluenceSite: String { Secrets.confluenceSite }
    static var confluenceEmail: String { Secrets.confluenceEmail }
    static var confluenceToken: String { Secrets.confluenceToken }

    private static func splitList(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Channel watcher (keyword rules over the designated channels).
    static var teamWatchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "teamwatch.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "teamwatch.enabled") }
    }
    static var teamWatchKeywords: [String] {
        get {
            (UserDefaults.standard.string(forKey: "teamwatch.keywords") ?? "")
                .lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: "teamwatch.keywords") }
    }
    static var teamWatchKeywordsRaw: String {
        get { UserDefaults.standard.string(forKey: "teamwatch.keywords") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "teamwatch.keywords") }
    }
    /// Auto-acknowledge into the channel on a match (TEAM_WATCH_AUTO_ACK=on).
    static var teamWatchAutoAck: Bool {
        ["on", "1", "true", "yes"].contains(Secrets.teamWatchAutoAck.lowercased())
    }
    // Notion and Fireflies connect through the keyless MCP path
    // (Settings → Connected apps) — no tokens in Config anymore.

    /// Brainstormer / managed-gateway backend base URL (empty = LLM-only
    /// fallback in the app). Validated to a real http(s) base, so a
    /// misconfigured .env (e.g. a leftover inline comment, or a URL missing its
    /// scheme) can never become a bogus request URL ("unsupported URL") — it
    /// just falls back to direct providers with a clear "add a key" error.
    static var backendBaseURL: String {
        resolveBackendBaseURL(Secrets.backendBaseURL)
    }

    /// Разбор вынесен отдельно, чтобы его можно было проверить целиком.
    ///
    /// Пока разбор сидел в вычисляемом свойстве, тест мог посмотреть только на
    /// то значение, с которым собрана эта машина. Собирается она с
    /// `http://localhost:8787`, а ломалось на пустом — на том, с которым
    /// уходит установщик. Ветка, ради которой тест писали, не выполнялась ни
    /// разу.
    static func resolveBackendBaseURL(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        // Explicit opt-out for a local dev build with baked keys and no backend
        // deployed: BACKEND_URL=off/none/direct → no backend, so AI features call
        // providers directly and nothing dials the (possibly-undeployed) prod host.
        if ["off", "none", "direct", "local"].contains(raw.lowercased()) { return "" }
        // Пусто — значит сервера нет, и это конечный ответ.
        //
        // В cruxwing здесь стояла подстановка `https://api.cruxwing.ai`, чтобы
        // вход и тарифы работали в любой сборке. В orakul она давала прямо
        // противоположное задуманному: DIST-сборка не бакает адрес, пустое
        // значение проваливалось в эту подстановку, и установщик orakul
        // предлагал вход и счёт на сервере другого продукта. Проверка в
        // build.sh это пропускала — она смотрела на своё значение, а не на
        // то, что в итоге возвращает Config.
        return ""
    }

    /// Serve chat through the backend's managed, tier-enforcing LLM gateway
    /// (LLM_GATEWAY=backend) instead of direct provider clients. Needs BACKEND_URL.
    static var llmViaBackend: Bool {
        Secrets.llmGateway.lowercased() == "backend"
            && !backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Council mode: answers come from a multi-model US+CN panel with a
    /// chairman synthesis (LLM_GATEWAY=ensemble).
    static var llmViaEnsemble: Bool { Secrets.llmGateway.lowercased() == "ensemble" }

    /// Panel spec "provider/model,…". Default set by the ensemble research.
    static var ensemblePanel: String {
        let v = Secrets.ensemblePanel.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultEnsemblePanel : v
    }
    static var ensembleChairman: String { Secrets.ensembleChairman }
    /// Default council: US frontier + Chinese reasoning models (ids verified
    /// against live provider docs 2026-07; see README · Council mode).
    static let defaultEnsemblePanel =
        "openAI/gpt-5.6-sol,anthropic/claude-opus-5,deepSeek/deepseek-v4-pro,qwen/qwen3.7-max,zhipu/glm-5.2"


    /// One-time recording consent (App Review 2.5.14 posture): the user
    /// affirms responsibility for participant consent before the first capture.
    static var recordingConsentAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: "consent.recording") }
        set { UserDefaults.standard.set(newValue, forKey: "consent.recording") }
    }

    /// Where the onboarding keys live. `.standard` in the app; a test binds a
    /// private suite around itself.
    ///
    /// Task-local rather than a settable static on purpose: suites run in
    /// parallel, so a static that one test swaps and restores is read by every
    /// other test in between. A task-local binding reaches only the test that
    /// established it and the work it spawns.
    @TaskLocal static var onboardingSuiteName: String?

    static var onboardingDefaults: UserDefaults {
        guard let name = onboardingSuiteName,
              let suite = UserDefaults(suiteName: name) else { return .standard }
        return suite
    }

    /// One-time first-run pre-flight (permissions + on-device model warm-up).
    /// Shown until the user completes it once.
    static var onboardingCompleted: Bool {
        get { onboardingDefaults.bool(forKey: "onboarding.completed") }
        set { onboardingDefaults.set(newValue, forKey: "onboarding.completed") }
    }

    /// The last onboarding step the user actually FINISHED. A boolean could not
    /// tell "granted the permissions, quit before the sample" from "never
    /// started", so an interrupted flow used to restart or skip.
    ///
    /// Falls back to the legacy `onboarding.completed` flag when no step is
    /// stored: someone who finished the old pre-flight has done the capture
    /// step, and an app update must not drag them through it again.
    static var onboardingStep: OnboardingStep? {
        get {
            if let raw = onboardingDefaults.string(forKey: "onboarding.step"),
               let step = OnboardingStep(rawValue: raw) {
                return step
            }
            return onboardingCompleted ? .capture : nil
        }
        set {
            onboardingDefaults.set(newValue?.rawValue, forKey: "onboarding.step")
            // Keep the old flag in step in BOTH directions. Writing it only on
            // the non-nil branch made the legacy flag a second source of truth:
            // clearing the step left it set, the getter fell back to it, and the
            // user read back as .capture — so nothing could put an install back
            // to a genuine first run.
            onboardingCompleted = newValue != nil
        }
    }

    /// Coach tips the user is finished with. A tip is retired by USING the
    /// feature it describes, not by reading about it.
    static var coachTipsRetired: Set<String> {
        get { Set(onboardingDefaults.stringArray(forKey: "onboarding.coachTipsRetired") ?? []) }
        set { onboardingDefaults.set(Array(newValue).sorted(), forKey: "onboarding.coachTipsRetired") }
    }

    /// Feature flag for native Apple / Google **account** login on Mac.
    /// Default off until App Store Connect Sign in with Apple + backend keys
    /// are verified. Enable via UserDefaults `auth.socialAccountLogin` or
    /// process env `SOCIAL_ACCOUNT_LOGIN=1` (tests / staged rollout).
    static var socialAccountLoginEnabled: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["SOCIAL_ACCOUNT_LOGIN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !env.isEmpty {
                return ["1", "true", "on", "yes"].contains(env)
            }
            if UserDefaults.standard.object(forKey: "auth.socialAccountLogin") != nil {
                return UserDefaults.standard.bool(forKey: "auth.socialAccountLogin")
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: "auth.socialAccountLogin") }
    }

    /// Per-team custom vocabulary (free text: one term per line or comma
    /// separated). Threaded into every transcription engine to bias toward the
    /// right spelling of specialized terms. Applies on the next recording.
    static var transcriptionGlossary: String {
        get { UserDefaults.standard.string(forKey: "transcription.glossary") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.glossary") }
    }
    static var glossaryTerms: [String] { Glossary.terms(from: transcriptionGlossary) }

    /// Opt into Apple's voice-processing unit — echo cancellation, noise
    /// suppression, and automatic gain. Default OFF because macOS necessarily
    /// lowers other audio while VoiceProcessingIO is active; `.min` only reduces
    /// that ducking and cannot disable it. Raw capture preserves playback volume.
    static var micNoiseSuppressionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mic.noiseSuppression") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "mic.noiseSuppression") }
    }

    /// The user's job position (RoleSkillMatrix position id, e.g.
    /// "product-manager"). Selects the role skill layer applied to every AI
    /// action; nil = no role layer.
    static var userRoleID: String? {
        get { UserDefaults.standard.string(forKey: "skills.userRole") }
        set { UserDefaults.standard.set(newValue, forKey: "skills.userRole") }
    }

    /// Free-text role description, used when `userRoleID` is
    /// `RoleSkillMatrix.customRoleID` — for users whose job isn't in the
    /// bundled position list (or who want more nuance than a title).
    static var userCustomRole: String {
        get { UserDefaults.standard.string(forKey: "skills.userCustomRole") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skills.userCustomRole") }
    }

    /// One non-destructive switch for every connected-app source. Older builds
    /// persisted work-app and team-source preferences separately; migrate a
    /// split state conservatively to off so no source remains invisibly active.
    static var connectedAppsGroundingEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            let key = "grounding.connectedApps"
            if let saved = defaults.object(forKey: key) as? Bool { return saved }
            let legacyApps = defaults.object(forKey: "grounding.apps") as? Bool ?? true
            let legacyTeam = defaults.object(forKey: "grounding.team") as? Bool ?? true
            let migrated = legacyApps && legacyTeam
            defaults.set(migrated, forKey: key)
            return migrated
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue, forKey: "grounding.connectedApps")
            // Keep legacy readers coherent during the transition.
            defaults.set(newValue, forKey: "grounding.apps")
            defaults.set(newValue, forKey: "grounding.team")
        }
    }

    /// Compatibility aliases for code compiled against the former two-toggle
    /// model. Both now read and write the single connected-app preference.
    static var groundAppsEnabled: Bool {
        get { connectedAppsGroundingEnabled }
        set { connectedAppsGroundingEnabled = newValue }
    }
    static var groundTeamEnabled: Bool {
        get { connectedAppsGroundingEnabled }
        set { connectedAppsGroundingEnabled = newValue }
    }
    /// Connected apps the user has MUTED — reachable, authorised, and
    /// deliberately not consulted.
    ///
    /// Opt-OUT rather than opt-in: connecting an app is already the act of
    /// saying yes to it, so a newly connected app is used immediately and a
    /// muted one stays muted until the user says otherwise. An opt-in set would
    /// silently ignore an app the user had just finished authorising.
    ///
    /// Ids are namespaced the same way the app strip renders them —
    /// `google`, `mcp:<serverID>`, `team:<service>` — so one set covers all
    /// three kinds and nothing has to translate between them.
    ///
    /// Persisted, not per-session: a toggle that silently resets between calls
    /// is worse than one that stays where it was put.
    static var mutedConnectedApps: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: "apps.muted") as? [String] ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "apps.muted") }
    }

    /// Namespaced ids, so callers never hand-build the string.
    static func mutedAppID(mcpServer id: String) -> String { "mcp:\(id)" }
    static func mutedAppID(team raw: String) -> String { "team:\(raw)" }
    static let googleAppID = "google"

    static var groundLedgerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "grounding.ledger") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "grounding.ledger") }
    }

    /// Whether the async brainstormer runs during a call.
    static var brainstormEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "brainstorm.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "brainstorm.enabled") }
    }

    /// Clarifying questions: when a typed request admits two readings that would
    /// produce different answers, ask before spending the answer. Never fires
    /// while recording — mid-call the user cannot answer a card.
    ///
    /// On by default: the countable tier costs nothing and the model tier runs
    /// on the background model with a tiny output budget. Off is for anyone who
    /// would rather be answered immediately and correct afterwards.
    static var clarifyingQuestionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "copilot.clarify") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "copilot.clarify") }
    }

    /// Background Fact Check: while recording, periodically verify the
    /// transcript's claims against your attached context and surface them live.
    /// Off by default — it only helps with context attached and it spends a
    /// metered call each cycle. The Fact Check button works regardless.
    static var factCheckDuringCallsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "copilot.factcheck") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "copilot.factcheck") }
    }

    /// Background Rhetoric watch: while recording, flag the single most important
    /// self-contradiction / unsupported claim / logical gap. Off by default;
    /// runs on the fast model tier. The Rhetoric button works regardless.
    static var rhetoricDuringCallsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "copilot.rhetoric") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "copilot.rhetoric") }
    }

    /// Background Facilitation watch: while recording, flag the single most
    /// important way the meeting is going off track (drift from the goal, a
    /// circular loop, an unresolved decision, a time sink) as one steering note.
    /// Off by default; runs on the fast model tier.
    static var facilitationDuringCallsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "copilot.facilitation") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "copilot.facilitation") }
    }

    /// Whether the async agenda + framing checker runs during a call.
    static var agendaCheckerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "agendacheck.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "agendacheck.enabled") }
    }

    /// OpenAI Whisper API model for chunked transcription.
    static let transcriptionModel = "whisper-1"

    // MARK: Tariff — tier + selected model

    /// TRUE only in dev builds — build.sh bakes `devMode = "0"` for
    /// MEETGPT_DIST=1 builds (hard-coded in the dist branch, never read from
    /// .env), so shipped binaries cannot enable developer tools.
    static var isDevBuild: Bool { Secrets.devMode == "1" }

    /// Dev-only plan preview (Settings ▸ Account & Privacy ▸ Developer):
    /// experience any tier exactly as a user on it would — model catalog,
    /// co-pilot allowances, grounded cycles — without paying. Ignored outside
    /// dev builds; `nil` = real entitlement.
    static var devTierOverride: Tier? {
        get {
            guard isDevBuild, !devTierPreviewRuntimeGate.isSuppressed() else { return nil }
            return Tier(rawValue: UserDefaults.standard.string(forKey: "dev.tierOverride") ?? "")
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: "dev.tierOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "dev.tierOverride")
            }
        }
    }

    /// Temporarily expose the real purchased entitlement to the secured live
    /// suite. This is deliberately process-local and dev-only; it neither
    /// removes nor rewrites the developer's saved preview.
    static func setLiveTestRealEntitlementMode(_ active: Bool) {
        guard isDevBuild else { return }
        devTierPreviewRuntimeGate.setSuppressed(active)
    }

    /// Baseline plan floor from `DEFAULT_TIER` (mac/.env) — operator/dev default
    /// or a paid entitlement later. Default free.
    static var baselineTier: Tier {
        Tier(rawValue: Secrets.defaultTier.lowercased()) ?? .free
    }

    /// Tier purchased through the paywall (Stripe) — a hard floor.
    static var purchasedTier: Tier? {
        get { Tier(rawValue: UserDefaults.standard.string(forKey: "billing.purchasedTier") ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "billing.purchasedTier") }
    }

    static var billingPeriodAnchor: Date? {
        get { UserDefaults.standard.object(forKey: "billing.periodAnchor") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "billing.periodAnchor") }
    }

    /// План. У orakul он один и всегда самый полный: тарифов нет.
    ///
    /// Механика тарифов досталась от Cruxwing и осталась в коде — на ней висят
    /// выбор модели, число источников для подсказки, лимиты. Вырезать её
    /// целиком значило бы переписать полсотни файлов; вместо этого она
    /// отвечает «всё доступно» в одной точке, через которую проходят все
    /// остальные.
    ///
    /// Разблокировать тут нечего: платить orakul не за что, всё считается на
    /// компьютере пользователя. Оставить `.free` значило бы отдать российскому
    /// разработчику две модели из тринадцати и платный экран за остальные —
    /// ровно то, чего в этом продукте быть не должно.
    ///
    /// Превью для разработчика остаётся: оно нужно, чтобы посмотреть чужой
    /// экран, и в собранном приложении недоступно.
    static var currentTier: Tier {
        if let preview = devTierOverride { return preview }
        return .ultra
    }

    /// The paywall was answered (subscribed or explicit "continue with Free").
    static var paywallChoiceMade: Bool {
        get { UserDefaults.standard.bool(forKey: "billing.paywallChoiceMade") }
        set { UserDefaults.standard.set(newValue, forKey: "billing.paywallChoiceMade") }
    }

    /// Платный экран в orakul не показывается никогда.
    ///
    /// Не «отложен до появления тарифов» — их не будет. Экран, который просит
    /// денег за то, что и так бесплатно, стоит доверия ровно столько же,
    /// сколько кнопка «Подключить», ведущая в никуда.
    ///
    /// Сам экран из кода не выпилен: он тянет за собой покупки, состояния
    /// аккаунта и половину настроек. Он просто недостижим, и это закреплено
    /// тестом.
    static var shouldShowPaywall: Bool { false }

    static func markPostTrialPromptShown() {
        UserDefaults.standard.set(true, forKey: "billing.postTrialPromptShown")
    }

    /// Two-tier selection: PROVIDER ("auto" or an LLMProvider rawValue) and
    /// VERSION ("auto" or a concrete model id). Defaults: Auto/Auto.
    static var selectedProvider: String {
        get { UserDefaults.standard.string(forKey: "llm.selectedProvider") ?? LLMCatalog.autoID }
        set { UserDefaults.standard.set(newValue, forKey: "llm.selectedProvider") }
    }
    static var selectedVersion: String {
        get { UserDefaults.standard.string(forKey: "llm.selectedVersion") ?? LLMCatalog.autoID }
        set { UserDefaults.standard.set(newValue, forKey: "llm.selectedVersion") }
    }

    /// Legacy single-id view of the selection, still consumed by the
    /// orchestrator: "auto" (orchestrate everything), "auto:<provider>"
    /// (orchestrate within a provider), or a concrete model id.
    static var selectedModelID: String {
        get {
            let provider = selectedProvider
            if provider.hasPrefix("orchestrate:") { return provider }  // price-tiered council level
            if provider.hasPrefix("council:") { return provider }      // US / China jurisdiction council
            if provider == LLMCatalog.autoID { return LLMCatalog.autoID }
            let version = selectedVersion
            if version == LLMCatalog.autoID { return "auto:\(provider)" }
            return version
        }
        set {
            // Back-compat setter (old picker path): map onto the two-tier keys.
            if newValue == LLMCatalog.autoID {
                selectedProvider = LLMCatalog.autoID
                selectedVersion = LLMCatalog.autoID
            } else if newValue.hasPrefix("auto:"),
                      let provider = LLMProvider(
                        rawValue: String(newValue.dropFirst("auto:".count))) {
                selectedProvider = provider.rawValue
                selectedVersion = LLMCatalog.autoID
            } else if newValue == LLMCatalog.councilUS
                        || newValue == LLMCatalog.councilCN {
                selectedProvider = newValue
                selectedVersion = LLMCatalog.autoID
            } else if OrchestrationLevel.from(selection: newValue) != nil {
                selectedProvider = newValue
                selectedVersion = LLMCatalog.autoID
            } else if let model = LLMCatalog.model(id: newValue) {
                selectedProvider = model.provider.rawValue
                selectedVersion = model.id
            }
        }
    }

    /// The resolved model to use, guaranteed available for the current tier.
    /// Auto selections resolve to a vision-capable sentinel; AutoOrchestrator
    /// swaps in the routed model (or the Council) per request.
    static var selectedModel: LLMModel {
        let id = selectedModelID
        if id == LLMCatalog.autoID || id.hasPrefix("auto:") || id.hasPrefix("council:") || id.hasPrefix("orchestrate:") { return LLMCatalog.auto }
        let tier = currentTier
        if let m = LLMCatalog.model(id: id), m.isAvailable(for: tier), m.provider.isConfigured { return m }
        return LLMCatalog.defaultModel(for: tier)
    }

    /// Model plus the exact picker selection for one immutable request. Auto's
    /// transport model is a sentinel (`id == "auto"`), so the provider pin or
    /// council level must travel separately or an in-flight Settings change can
    /// silently reroute the request.
    static var selectedRequestModel: LLMModel {
        let selection = selectedModelID
        let resolved = selectedModel
        let provider: LLMProvider
        if selection.hasPrefix("auto:"),
           let pinned = LLMProvider(rawValue: String(selection.dropFirst("auto:".count))) {
            provider = pinned
        } else {
            provider = resolved.provider
        }
        return LLMModel(
            id: resolved.id, label: resolved.label, provider: provider,
            minTier: resolved.minTier, supportsVision: resolved.supportsVision,
            requestSelectionID: selection)
    }

    // MARK: Prompts

    static var customPrompts: [QuickPrompt] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "prompts.custom") else { return [] }
            return (try? JSONDecoder().decode([QuickPrompt].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "prompts.custom")
            }
        }
    }

    // MARK: Google OAuth (Calendar)

    /// Google OAuth Desktop-app credentials — build-time, from `Secrets`.
    static var googleClientID: String { Secrets.googleClientID }
    static var googleClientSecret: String { Secrets.googleClientSecret }

    /// Email of the last account that signed in successfully — a breadcrumb in
    /// UserDefaults, deliberately NOT in the Keychain.
    ///
    /// The session itself lives in the Keychain, so when that row disappears —
    /// expired, revoked, or dropped because a signing-identity change made it
    /// unreadable — the app has no way to know it was ever signed in, and comes
    /// up looking like a fresh install. Connected apps are stored separately and
    /// survive, so the workspace still shows Google/Notion/Asana attached and
    /// nothing announces the account is gone; the only visible symptom was the
    /// credits rail going quiet, which reads as a billing problem.
    ///
    /// Holding the email outside the Keychain makes "we had an account and now
    /// we do not" detectable. It is an address the user typed, not a credential.
    /// Cleared on deliberate sign-out, so choosing to sign out never nags.
    static var lastSignedInEmail: String? {
        get { UserDefaults.standard.string(forKey: "account.lastSignedInEmail") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "account.lastSignedInEmail")
            } else {
                UserDefaults.standard.removeObject(forKey: "account.lastSignedInEmail")
            }
        }
    }

    /// The scope version granted at the last successful Google connect. When it
    /// is behind `GoogleAuth.scopeVersion`, Docs/Sheets access needs a reconnect.
    static var googleScopeVersion: Int {
        get { UserDefaults.standard.integer(forKey: "google.scopeVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "google.scopeVersion") }
    }

    /// Which Google services the user allows MeetGPT to request (granular
    /// authorization — disabled services are excluded from the OAuth grant).
    static var googleEnabledServices: Set<String> {
        get {
            guard let raw = UserDefaults.standard.array(forKey: "google.enabledServices") as? [String] else {
                return Set(GoogleService.requestable.map(\.rawValue))   // default: all grantable
            }
            return Set(raw)
        }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "google.enabledServices") }
    }

    /// The services covered by the CURRENT grant (recorded at connect time).
    static var googleGrantedServices: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: "google.grantedServices") as? [String] ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "google.grantedServices") }
    }

    /// Persisted Google OAuth tokens (access + refresh + expiry). Stored in the
    /// Keychain — like the Wheespr session — because the refresh token grants
    /// durable Calendar/Docs/Sheets access and must never sit in a world-readable
    /// UserDefaults plist.
    static var googleTokens: GoogleTokens? {
        get { credentialCache.googleTokens() }
        set {
            credentialCache.setGoogleTokens(newValue)
            UserDefaults.standard.removeObject(forKey: "google.tokens")  // never keep a plaintext copy
            credentialPersistenceQueue.async {
                persistGoogleTokens(newValue, to: SystemKeychain.shared)
            }
        }
    }

    /// Seed the process cache from the post-window background read without
    /// writing the same value back to Keychain.
    static var credentialCacheRevisions: (google: UInt64, wheespr: UInt64) {
        credentialCache.revisions()
    }

    @discardableResult
    static func installLoadedGoogleTokens(_ value: GoogleTokens?,
                                          ifRevisionIs expected: UInt64) -> Bool {
        credentialCache.installGoogleTokens(value, ifRevisionIs: expected)
    }

    /// Injectable read seam used by the post-window startup loader. Production
    /// callers use the system Keychain; tests use an in-memory store so they can
    /// prove no Security XPC happens while SwiftUI instantiates the scene.
    static func loadGoogleTokens(from store: KeychainStore = SystemKeychain.shared) -> GoogleTokens? {
        if let data = store.get("google.tokens") {
            return try? JSONDecoder().decode(GoogleTokens.self, from: data)
        }
        // One-time migration: lift tokens left in UserDefaults by an older
        // build into the Keychain, then scrub the plaintext copy so the
        // refresh token stops living in the plist.
        if let legacy = UserDefaults.standard.data(forKey: "google.tokens") {
            store.set(legacy, for: "google.tokens")
            UserDefaults.standard.removeObject(forKey: "google.tokens")
            return try? JSONDecoder().decode(GoogleTokens.self, from: legacy)
        }
        return nil
    }

    private static func persistGoogleTokens(_ value: GoogleTokens?, to store: KeychainStore) {
        if let value, let data = try? JSONEncoder().encode(value) {
            store.set(data, for: "google.tokens")
        } else {
            store.delete("google.tokens")
        }
    }

    // MARK: Saved context sets (pin context for repeating calls)

    static var contextSets: [ContextSet] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "context.sets") else { return [] }
            return (try? JSONDecoder().decode([ContextSet].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "context.sets")
            }
        }
    }

    // MARK: Wheespr account (email OTP session — stored in the Keychain, not
    // UserDefaults, because it grants backend account access).

    static var wheesprSession: WheesprSession? {
        get { credentialCache.wheesprSession() }
        set {
            credentialCache.setWheesprSession(newValue)
            // Account identity is part of the provenance of connected-app
            // evidence. Post for every replacement (including token refresh):
            // over-invalidating a short-lived cache is safe; retaining another
            // account's snippets is not.
            WheesprSessionNotifications.postAccountContextChanged()
            credentialPersistenceQueue.async {
                persistWheesprSession(newValue, to: SystemKeychain.shared)
            }
        }
    }

    @discardableResult
    static func installLoadedWheesprSession(_ value: WheesprSession?,
                                            ifRevisionIs expected: UInt64) -> Bool {
        let installed = credentialCache.installWheesprSession(value, ifRevisionIs: expected)
        if installed { WheesprSessionNotifications.postAccountContextChanged() }
        return installed
    }

    static func loadWheesprSession(from store: KeychainStore = SystemKeychain.shared) -> WheesprSession? {
        guard let data = store.get("wheespr.session") else { return nil }
        return try? JSONDecoder().decode(WheesprSession.self, from: data)
    }

    private static func persistWheesprSession(_ value: WheesprSession?, to store: KeychainStore) {
        if let value, let data = try? JSONEncoder().encode(value) {
            store.set(data, for: "wheespr.session")
        } else {
            store.delete("wheespr.session")
        }
    }

    /// A stable per-install id used to mint a device-scoped account when a promo
    /// code is redeemed without signing in (see PaywallAPI.deviceRedeem). Generated
    /// once and persisted; a plain UUID satisfies the backend's device-id format.
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: "device.id"),
           existing.count >= 8 { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "device.id")
        return id
    }

    /// Opt out of first-party, anonymous funnel telemetry (FunnelTracker). Default
    /// off = telemetry on; anonymous + no PII, but the user can disable it entirely.
    static var funnelOptOut: Bool {
        get { UserDefaults.standard.bool(forKey: "funnel.optOut") }
        set { UserDefaults.standard.set(newValue, forKey: "funnel.optOut") }
    }

    // MARK: Transcription tuning (build-time, from mac/.env — not in the UI)

    /// Default to the on-device engine (WhisperKit) when unset/unrecognized —
    /// audio never leaves the Mac unless the operator explicitly opts into a
    /// cloud engine (`server`/`whisper`/`deepgram`) in mac/.env.
    /// The active engine: the user's Settings choice when it's available in
    /// this build, else the build default (env), else on-device. Applied on the
    /// next recording.
    static var transcriptionEngineValue: TranscriptionEngine {
        get {
            if let saved = UserDefaults.standard.string(forKey: "transcription.engine"),
               let engine = TranscriptionEngine(rawValue: saved),
               engineAvailable(engine) { return engine }
            let env = TranscriptionEngine(rawValue: Secrets.transcriptionEngine.lowercased()) ?? .local
            return engineAvailable(env) ? env : .local
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "transcription.engine") }
    }

    /// Whether an engine can actually run in this build (cloud engines need
    /// their key baked or a managed path; on-device always works).
    /// `.server` (Cruxwing Whisper large-v3) is live: it needs a backend AND a
    /// signed-in session — the gateway meters per user, and an anonymous
    /// first-run must keep transcribing on-device instead of erroring.
    static var serverWhisperEnabled: Bool { true }

    static func engineAvailable(_ engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .local:    return true
        case .server:   return serverWhisperEnabled
            && !backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && wheesprSession != nil
        // Deepgram: a baked/BYO key (operator's own Deepgram bill) or, keyless,
        // the backend's short-lived token grant — signed-in only, billed from
        // the shared compute-credit pool at the deepgram chunk rate.
        case .deepgram: return !deepgramAPIKey.isEmpty
            || (!backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && wheesprSession != nil)
        case .whisper:  return !openAIAPIKey.isEmpty
        }
    }

    /// Seconds each transcription window repeats from the one before it.
    ///
    /// Zero restores the old hard-cut behaviour. Clamped to half the window by
    /// AudioChunkBuffer, since an overlap at parity never advances.
    static var transcriptionChunkOverlapSeconds: Double {
        let v = Double(Secrets.transcriptionChunkOverlapSeconds) ?? -1
        return v >= 0 ? min(v, 5) : 1.5
    }

    /// How far a decode window may move backward to end on a pause.
    /// Zero restores an exact clock boundary.
    static var transcriptionBoundarySlackSeconds: Double {
        let v = Double(Secrets.transcriptionBoundarySlackSeconds) ?? -1
        return v >= 0 ? min(v, 3) : 0
    }

    /// Live capture window, in seconds.
    ///
    /// 6 is a LATENCY budget, not an accuracy result: a caption has to appear
    /// while people are still talking. Measured 2026-08-09 on five accented
    /// recordings through the real pipeline, a longer window trades insertions
    /// for delay — insertions fall monotonically 160 → 98 → 96 → 68 across
    /// 6/8/10/12s, because most live insertions are duplicated fragments where
    /// two windows meet. WER improves too (0.2484 → 0.2221 at 12s) but not
    /// monotonically, so the ranking between 8, 10 and 12 is inside the noise of
    /// a five-recording sample.
    ///
    /// Left at 6 deliberately. The whole-file re-transcription pass already
    /// scores 0.1731 — better than any live window — so accuracy is recovered
    /// after the call, and the live path's job is timeliness. An operator who
    /// wants the trade can set it in mac/.env; the clamp allows 2–15.
    static var transcriptionChunkSeconds: Double {
        let v = Double(Secrets.transcriptionChunkSeconds) ?? 0
        return v > 0 ? min(max(v, 2), 15) : 6.0
    }

    /// WhisperKit model for the local engine (e.g. tiny/base/small/large-v3).
    /// The on-device model variant. User choice (Settings) wins; then a
    /// non-default baked value (self-host escape hatch); otherwise a
    /// hardware-aware default (Apple Silicon steps up from the blanket "base").
    /// Applies on the next app launch — the transcriber captures it at init.
    static let localModelHardwareDefaultMigrationKey =
        "transcription.localModelHardwareDefaultV2"

    static var localWhisperModel: String {
        get {
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: "transcription.localModel"),
               // Older installs saved the ambiguous "large-v3". Map it to the
               // explicit build rather than treating it as unknown, which would
               // silently drop the user back to the hardware default.
               case let saved = LocalWhisperModel.migrated(stored),
               LocalWhisperModel.isKnown(saved) {
                // One-time correction for machines the OLD default over-provisioned.
                // large-v3 used to be handed to any Pro-class chip with ≥16 GB,
                // which cooked M1/M2 Pro laptops under two-stream load. A value
                // that was WRITTEN BY THAT DEFAULT (not chosen in Settings) is
                // rewritten once to what this Mac can actually sustain.
                if saved == LocalWhisperModel.largeVariant,
                   localModelSelectionProvenance != .user,
                   localModelSelectionProvenance != .adaptive,
                   LocalWhisperModel.recommendedDefault(
                       isAppleSilicon: Hardware.isAppleSilicon)
                       != LocalWhisperModel.largeVariant {
                    let corrected = LocalWhisperModel.recommendedDefault(
                        isAppleSilicon: Hardware.isAppleSilicon)
                    defaults.set(corrected, forKey: "transcription.localModel")
                    defaults.set(true, forKey: localModelHardwareDefaultMigrationKey)
                    return corrected
                }
                let recommended = LocalWhisperModel.recommendedDefault(
                    isAppleSilicon: Hardware.isAppleSilicon)
                if let corrected = LocalWhisperModel.legacyAutomaticDefaultReplacement(
                    saved: saved,
                    provenance: localModelSelectionProvenance,
                    migrationCompleted: defaults.bool(
                        forKey: localModelHardwareDefaultMigrationKey),
                    recommended: recommended
                ) {
                    defaults.set(corrected, forKey: "transcription.localModel")
                    defaults.set(true, forKey: localModelHardwareDefaultMigrationKey)
                    return corrected
                }
                if localModelSelectionProvenance != .legacyUnknown {
                    defaults.set(true, forKey: localModelHardwareDefaultMigrationKey)
                }
                return saved
            }
            let baked = Secrets.localWhisperModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baked.isEmpty, baked != "base" { return baked }
            defaults.set(true, forKey: localModelHardwareDefaultMigrationKey)
            localModelSelectionProvenance = .automatic
            return LocalWhisperModel.recommendedDefault(isAppleSilicon: Hardware.isAppleSilicon)
        }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.localModel") }
    }

    /// Set when the model is picked in Settings, so an explicit choice is never
    /// silently rewritten by a default correction. An automatic downgrade (the
    /// thermal/overload watchdog) deliberately does NOT set this.
    static var localModelChosenByUser: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.localModelUserChosen") }
        set {
            UserDefaults.standard.set(newValue, forKey: "transcription.localModelUserChosen")
            if newValue { localModelSelectionProvenance = .user }
        }
    }

    /// Why the saved model was selected. A runtime safety downgrade must not
    /// be mistaken for an obsolete automatic default during migration.
    static var localModelSelectionProvenance: LocalWhisperModelProvenance {
        get {
            if let raw = UserDefaults.standard.string(
                forKey: "transcription.localModelProvenance"),
               let value = LocalWhisperModelProvenance(rawValue: raw) {
                return value
            }
            return localModelChosenByUser ? .user : .legacyUnknown
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue, forKey: "transcription.localModelProvenance")
        }
    }

    /// Persisted only after Core ML's Neural Engine execution stream fails.
    /// Subsequent launches keep Whisper on CPU/GPU instead of retrying the same
    /// poisoned ANE path every six-second chunk.
    static var localWhisperCompatibilityMode: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.localCompatibilityMode") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.localCompatibilityMode") }
    }

    /// Suppress transcript lines that repeat speech already captured — speaker
    /// bleed into the microphone, and Whisper re-emitting its own chunk tail.
    /// Escape hatch for a room where two people genuinely echo each other.
    static var transcriptDeduplicationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "transcription.deduplicate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.deduplicate") }
    }

    /// Adapt only within the private/local engine automatically. Moving audio
    /// to a cloud engine always remains an explicit user choice.
    static var adaptiveLocalWhisperEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "transcription.localAdaptive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.localAdaptive") }
    }

    /// Optional private post-call refinement. Dark by default until the
    /// conservative replacement gate has passed more whole-call corpus checks.
    static var transcriptionPostStopFinalPassEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.postStopFinalPass") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.postStopFinalPass") }
    }

    /// Beta, post-call, and entirely on-device. Enabling this is also explicit
    /// consent to retain the remote mono track in memory until the next call or
    /// app quit. It never enables a cloud route.
    static var localDiarizationEnabled: Bool {
        get { LocalDiarization.isEnabled }
        set { LocalDiarization.isEnabled = newValue }
    }

    /// Automatic-count mode over-segments badly. Require a small, explicit
    /// count of remote voices (the local user is already known as `Вы`).
    static var localDiarizationRemoteSpeakerCount: Int {
        get {
            let key = "transcription.localDiarizationRemoteSpeakers"
            guard UserDefaults.standard.object(forKey: key) != nil else { return 1 }
            return LocalDiarization.normalizedRemoteSpeakerCount(
                UserDefaults.standard.integer(forKey: key))
        }
        set {
            UserDefaults.standard.set(
                LocalDiarization.normalizedRemoteSpeakerCount(newValue),
                forKey: "transcription.localDiarizationRemoteSpeakers")
        }
    }

    /// AssemblyAI is post-call diarization, not a live fallback. Default off:
    /// retaining the system track for a possible upload requires opt-in.
    static var assemblyAIDiarizationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.assemblyDiarization") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.assemblyDiarization") }
    }

    /// After a call ends (and when importing Fireflies), merge Whisper captions
    /// with the Fireflies MCP transcript via the LLM. Default on — opt out in
    /// Settings → Transcription. No-ops when Fireflies is not connected.
    static var firefliesTranscriptEnhanceEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "transcription.firefliesEnhance") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "transcription.firefliesEnhance")
        }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.firefliesEnhance") }
    }

    /// Voice-activity detection for chunked engines (default on; set
    /// TRANSCRIPTION_VAD=off to always transcribe every chunk).
    static var vadEnabled: Bool {
        !["off", "0", "false", "no"].contains(Secrets.transcriptionVAD.lowercased())
    }

    /// Live-transcription language. The user's choice in Settings overrides the
    /// baked default. `multi` asks every transcription backend to detect and
    /// adapt instead of pinning the recording to one language.
    /// Experimental: serve LIVE captions from Parakeet TDT v3 when the
    /// selected language is one it covers. The post-call re-transcription
    /// stays on Whisper regardless — measured on real Russian calls:
    /// Parakeet wins prose fidelity and runs 5-8x faster, Whisper wins
    /// embedded English tech vocabulary, so each keeps its half.
    static var parakeetLiveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "transcription.parakeetLive") }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.parakeetLive") }
    }

    static var transcriptionLanguage: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "transcription.language"),
               !saved.isEmpty { return saved }
            let env = Secrets.transcriptionLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            return env.isEmpty ? "multi" : env
        }
        set { UserDefaults.standard.set(newValue, forKey: "transcription.language") }
    }

    /// Languages shared by Auto across the live transcription engines. Keeping
    /// one set avoids a meeting working locally and silently changing behavior
    /// after the user switches to Deepgram.
    static let transcriptionLanguageOptions: [(code: String, label: String)] = [
        ("multi", "Auto"),
        ("en", "English"),
        ("ru", "Russian"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("hi", "Hindi"),
        ("ja", "Japanese")
    ]

    static let automaticTranscriptionLanguageCodes: Set<String> = Set(
        transcriptionLanguageOptions.lazy
            .filter { $0.code != "multi" }
            .map { $0.code }
    )

    // MARK: Appearance (light / dark / auto)

    /// App theme. Persisted; default auto (follow the system, which switches at
    /// sunrise/sunset when macOS Appearance is Auto).
    static var appAppearance: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance.mode") }
    }

    /// Reading text size for the transcript and the assistant answer, as a
    /// multiplier. Persisted; default 1.0.
    ///
    /// Clamped on read as well as on write: a preference file can be edited by
    /// hand or carried over from a build with different bounds, and an
    /// unclamped multiplier there makes the app unreadable with no obvious way
    /// back.
    /// Silent text banners when a new blind spot lands during a live call
    /// (PROJECT_STATUS item 17). On by default: the value of a blind spot is
    /// seeing it, and the user is usually looking at the call, not the app.
    static var blindSpotTextNotificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify.blindSpotText") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify.blindSpotText") }
    }

    static var readingTextScale: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "appearance.readingScale") as? Double
            return ReadingTextScale.clamp(stored ?? ReadingTextScale.standard)
        }
        set {
            UserDefaults.standard.set(ReadingTextScale.clamp(newValue),
                                      forKey: "appearance.readingScale")
        }
    }

    /// Outbound secret redaction. ON by default — a privacy control that ships
    /// off protects nobody, and the acceptance criteria say so explicitly.
    static var outboundRedactionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "privacy.outboundRedaction") == nil { return true }
            return UserDefaults.standard.bool(forKey: "privacy.outboundRedaction")
        }
        set { UserDefaults.standard.set(newValue, forKey: "privacy.outboundRedaction") }
    }

    /// Extra terms the user wants removed — project code names, client names.
    /// Stored as free text and parsed with the glossary's own splitter, so the
    /// two lists behave identically and nobody has to learn a second format.
    static var redactionTermsRaw: String {
        get { UserDefaults.standard.string(forKey: "privacy.redactionTerms") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "privacy.redactionTerms") }
    }

    static var redactionTerms: [String] { Glossary.terms(from: redactionTermsRaw) }

    // MARK: Call detection

    /// Notify when a meeting app becomes active, prompting to start recording.
    static var callDetectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "calldetect.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "calldetect.enabled") }
    }

    /// Suppress the prompt while a media app (music/video) is the audio source.
    static var ignoreMediaApps: Bool {
        get { UserDefaults.standard.object(forKey: "calldetect.ignoreMedia") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "calldetect.ignoreMedia") }
    }

    // MARK: Meeting reminders (scheduled from Google Calendar)

    /// Whether MeetGPT schedules a local notification before upcoming calendar
    /// meetings. Requires a connected Google Calendar.
    static var meetingRemindersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "reminders.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "reminders.enabled") }
    }

    /// Lead time in minutes before a meeting's start to fire the reminder.
    /// Clamped to a sane range so a bad stored value can't break scheduling.
    static var meetingReminderMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: "reminders.minutes") as? Int ?? 5
            return min(max(v, 1), 60)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 60), forKey: "reminders.minutes") }
    }
}
