import Foundation
import Testing
@testable import MeetGPT

/// Приложение не предлагает того, чего в этой сборке нет.
///
/// За один день это вылезло четыре раза, и каждый раз по-своему:
///
/// 1. Адрес сервера не зашивался в установщик, а `Config` подставлял вместо
///    пустого значения адрес Cruxwing — чужой, живой и отвечающий. Вход и счёт
///    выглядели рабочими.
/// 2. Строка «вставить ключ провайдера» держалась на признаке входа. Когда
///    подстановку убрали, признак стал означать «вошёл», и единственная нужная
///    строка исчезла заодно с ненужными.
/// 3. Кнопка «Проверить в вебе» звала поиск, который живёт на сервере: без него
///    она молча делала обычную проверку и отвечала «источников: 0».
/// 4. Раздел «Аккаунт» в настройках не был закрыт ничем и обещал «модели без
///    своих ключей» и синхронизацию журнала — и то и другое требует сервера.
///
/// Общее у всех четырёх — не сервер, а то, что проверка стояла не на том месте:
/// на файле сборки, на признаке-соседе, на коде возврата. Здесь проверяется то,
/// что видит человек.
@Suite("Обещания без сервера")
struct NoBackendPromisesTests {

    private var hasBackend: Bool {
        !Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetGPT/Views")
    }

    /// Все `.swift` под Views, вместе с подпапками.
    private func viewSources() -> [(name: String, text: String)] {
        let root = viewsDirectory
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var found: [(name: String, text: String)] = []
        for case let entry as String in walker where entry.hasSuffix(".swift") {
            let url = root.appendingPathComponent(entry)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                found.append((name: entry, text: text))
            }
        }
        return found
    }

    @MainActor
    @Test("вход нигде не предлагается, когда входить некуда")
    func noSignInOfferedWithoutABackend() {
        guard !hasBackend else { return }  // сборка с сервером — не наш случай
        let state = AppState(credentialStore: InMemoryKeychain())

        // Оба признака, на которые смотрят экраны со входом.
        #expect(!state.wheesprAvailable, "предлагается вход в несуществующий аккаунт")
        #expect(!state.ledgerConfigured, "показывается счёт без сервера")
    }

    @MainActor
    @Test("в настройках нет раздела «Аккаунт», когда входить некуда")
    func settingsHidesTheAccountSection() throws {
        // Проверяется отрисовка, а не исходник. Первая версия искала
        // «backendBaseURL» по файлу целиком — и проходила даже с убранной
        // защитой: это слово встречается в SettingsView ещё раз, в адресе
        // MCP (строка 686). Проверка была зелёной и не значила ничего — ровно
        // та же ошибка, что и во всех четырёх случаях выше.
        guard !hasBackend else { return }  // сборка с сервером — не наш случай

        let state = AppState(credentialStore: InMemoryKeychain())
        state.selectedSettingsTab = .accountPrivacy
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        let rendered = try SettingsView()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()

        #expect(throws: (any Error).self, "раздел «Аккаунт» показан, а входить некуда") {
            try rendered.find(text: "Вход нужен, чтобы пользоваться моделями без своих ключей и синхронизировать журнал решений.")
        }
        #expect(throws: (any Error).self, "предлагается удалить несуществующий аккаунт") {
            try rendered.find(viewWithAccessibilityIdentifier: "settings.account.delete")
        }
    }

    @Test("кнопка веб-проверки закрыта тем же признаком")
    func webFactCheckIsGuarded() throws {
        // Поиск уходит на сервер (`FactCheckService.check`), и без него кнопка
        // отвечает пустотой вместо отказа. Пустой ответ читается как «ничего не
        // нашли», а не как «искать было нечем».
        let sheet = viewSources().first { $0.name.hasSuffix("FactCheckSheet.swift") }
        let text = try #require(sheet?.text, "FactCheckSheet.swift не прочитался")
        #expect(text.contains("backendBaseURL"),
                "«Проверить в вебе» снова показывается без сервера")
    }

    @MainActor
    @Test("рельса с кредитами не показывается ни в каком виде")
    func creditRailNeverRenders() throws {
        // Механика кредитов осталась от Cruxwing и закрыта признаком
        // `Config.llmViaBackend`, который в orakul всегда false. Удалять её —
        // это ~250 строк внутри живой полосы бюджета, и цена ошибки там выше,
        // чем польза. Поэтому проверяется не отсутствие кода, а отсутствие
        // кредитов на экране: строка «Войдите, чтобы получить кредиты», баланс
        // и подписи для VoiceOver.
        #expect(!Config.llmViaBackend, "маршрут через сервер включился — кредиты оживут")

        let state = AppState(llm: MockLLMGateway(response: ""))
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        state.mcp = manager
        let rendered = try PromptBudgetBar()
            .environmentObject(state)
            .environmentObject(manager)
            .inspect()

        for phrase in ["Войдите, чтобы получить кредиты и синхронизацию.",
                       "Загружаю баланс кредитов…"] {
            #expect(throws: (any Error).self, "на экране кредиты: \(phrase)") {
                try rendered.find(text: phrase)
            }
        }
    }

    @Test("платных уровней нет ни в одном виде")
    func nothingChargesMoney() {
        // Отдельно от NoTariffsTests: там проверяется флаг, здесь — что за ним
        // не просочился текст про списание денег.
        #expect(!Config.shouldShowPaywall)
        for (name, text) in viewSources() {
            #expect(!text.contains("search credits"),
                    "\(name): осталось обещание списывать кредиты")
        }
    }
}

/// SECURITY.md обещает: наружу уходит ровно две вещи — запрос к модели и
/// запрос к подключённому сервису. Ни телеметрии, ни счётчиков.
///
/// При запуске приложение вызывает `PaywallAPI.claimDeviceTrial()`, и тот
/// собирается отправить POST с идентификатором устройства. Держится обещание
/// на одном: адреса сервера в сборке нет, поэтому отправлять некуда. Стоит
/// кому-нибудь вписать адрес по умолчанию — обещание станет ложью тихо, без
/// единой падающей проверки. Здесь та самая связка и закреплена.
@Suite("Обещание SECURITY.md про запуск")
struct LaunchSendsNothingTests {
    @Test("адреса сервера в сборке нет — отправлять идентификатор устройства некуда")
    func noAddressMeansNoLaunchRequest() async {
        #expect(Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "появился адрес сервера: запуск начнёт слать идентификатор устройства")

        // Проверка выше и есть обещание: адреса нет — идти некуда. Ниже —
        // следствие, и оно верно при любой ветке: с сессией `claimDeviceTrial`
        // выходит на первой же строке, без сессии упирается в пустой адрес.
        //
        // Раньше здесь стояло `#expect(Config.wheesprSession == nil)` как
        // предусловие. Сессия — общее состояние: её выставляют другие наборы,
        // порядок в параллельном прогоне не фиксирован, и проверка падала
        // примерно раз в пять прогонов, ничего не сообщая о продукте. Тест,
        // падающий от соседа, обесценивает весь прогон: он приучает
        // пересматривать красный как «наверное, опять оно».
        let claimed = await PaywallAPI.claimDeviceTrial()
        #expect(!claimed, "устройство заявлено — значит, запрос куда-то ушёл")
    }

    /// Отдельно от флага: `claimDeviceTrial` не спрятан за `llmViaBackend`,
    /// в отличие от `refreshEntitlement`. Разница неочевидна, и проверка
    /// существует, чтобы её не потеряли при чтении.
    @Test("вызов при запуске не закрыт флагом серверного режима")
    func launchCallIsNotGatedByTheBackendFlag() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MeetGPT/Views/Paywall/PaywallAPI.swift"),
            encoding: .utf8)
        let body = try #require(source.range(of: "static func claimDeviceTrial")
            .map { String(source[$0.lowerBound...].prefix(400)) })
        #expect(!body.contains("llmViaBackend"),
                "ветка закрылась флагом — тогда обещание держит флаг, и проверка выше лишняя")
    }
}
