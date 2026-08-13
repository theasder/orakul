import Foundation
import Testing
@testable import MeetGPT

/// orakul обращается к провайдеру напрямую, а не через наш сервер.
///
/// Это не настройка вкуса, а условие работоспособности. `LLM_GATEWAY=backend`
/// означает три вещи разом:
///
///  1. запросы уходят на `api.orakul.ai`, которого не существует;
///  2. ключ, введённый пользователем, не читается вообще — берётся серверный
///     путь;
///  3. `LLMModel.isConfigured` возвращает true для всех провайдеров, потому что
///     «ключи живут на сервере», и все модели выглядят готовыми.
///
/// Вместе это даёт приложение, которое выглядит настроенным и не отвечает ни на
/// один вопрос. Так и было в собранном установщике, пока это не поймали.
@Suite("Прямой доступ к провайдеру")
struct DirectGatewayTests {

    @Test("сборка не ходит через несуществующий сервер")
    func gatewayIsDirect() {
        #expect(!Config.llmViaBackend,
                "включён серверный шлюз: ключ пользователя не будет прочитан")
        // Флага мало: маршрут выбирается в LLMGatewayFactory, и порядок веток
        // там можно поменять, не трогая флаг. Проверяется сам выбор.
        #expect(LLMGatewayFactory.selection == .direct,
                "запрос пойдёт мимо провайдера: \(LLMGatewayFactory.selection)")
    }

    @Test("ключ пользователя решает, доступен ли провайдер")
    func providerReadinessFollowsTheKey() {
        // Главное следствие: пока шлюз включён, эта проверка бессмысленна —
        // isConfigured отвечает true всем и каждому.
        #expect(!Config.llmViaBackend, "предусловие: прямой режим")

        // Провайдер без ключа не должен считаться настроенным. Иначе человек
        // выбирает модель, жмёт кнопку и получает ошибку вместо ответа.
        let withoutKey = LLMProvider.allCases.filter { !$0.hasDirectKey }
        // Без этой строки проверка тихо вырождается: подмена ключей из
        // соседнего набора (`withSeededProviderKeys`) видна всему процессу,
        // и тогда список пуст, цикл не выполняется ни разу, а тест зелёный.
        #expect(!withoutKey.isEmpty,
                "все провайдеры с ключами — цикл ниже ничего не проверит")
        for provider in withoutKey {
            #expect(!provider.isConfigured,
                    "\(provider.label) без ключа считается настроенным")
        }
    }

    @Test("установщик собирается в прямом режиме, а не только эта машина")
    func distBuildIsDirectToo() {
        // Первая версия этого теста читала `.env` — и проходила, пока
        // собранный установщик ходил через шлюз. `build.sh` в режиме DIST
        // перезаписывает значение независимо от `.env`, так что проверять
        // нужно именно его: это тот файл, который решает, что попадёт в DMG.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let script = try? String(contentsOf: root.appendingPathComponent("build.sh"),
                                       encoding: .utf8) else {
            Issue.record("не прочитался build.sh — проверка была бы фиктивной")
            return
        }
        #expect(script.contains(#"[ "$1" = "LLM_GATEWAY" ] && { printf 'direct'; return; }"#),
                "DIST-сборка снова форсит шлюз: ключ пользователя не будет прочитан")
        #expect(!script.contains(#"[ "$1" = "LLM_GATEWAY" ] && { printf 'backend'; return; }"#))

        // И `.env` — для сборки с этой машины.
        guard let env = try? String(contentsOf: root.appendingPathComponent(".env"),
                                    encoding: .utf8) else { return }
        let line = env.split(separator: "\n")
            .first { $0.hasPrefix("LLM_GATEWAY=") }
            .map(String.init)
        #expect(line == "LLM_GATEWAY=direct", "в .env: \(line ?? "строки нет")")
    }

    @Test("установщик не обещает расшифровку на нашем сервере")
    func distTranscriptionIsOnDevice() {
        // Тот же случай: 'server' означает managed Whisper на сервере, которого
        // нет. Значение по умолчанию должно быть тем, что действительно
        // работает без сети.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let script = try? String(contentsOf: root.appendingPathComponent("build.sh"),
                                       encoding: .utf8) else {
            Issue.record("не прочитался build.sh")
            return
        }
        #expect(script.contains(#"[ "$1" = "TRANSCRIPTION_ENGINE" ] && { printf 'local'; return; }"#),
                "установщик собирается с движком, которого нет")
    }

    @Test("в установщик не попадает адрес сервера")
    func distBakesNoBackendURL() {
        // Раньше здесь стояло обратное: «адрес остаётся записанным, но не
        // используется». Для рабочей копии это было верно, а для DMG — нет.
        // Сборка брала адрес из `.env` (`http://localhost:8787`, машина
        // сборщика), а при пустом значении подставляла `https://api.cruxwing.ai`
        // — сервер другого продукта, который существует и отвечает. Маршрут
        // выключен, но адрес в бинарнике остаётся ошибкой, которую на машине
        // сборщика не видно.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let script = try? String(contentsOf: root.appendingPathComponent("build.sh"),
                                       encoding: .utf8) else {
            Issue.record("не прочитался build.sh — проверка была бы фиктивной")
            return
        }
        #expect(script.contains(#"[ "$1" = "BACKEND_URL" ] && { printf ''; return; }"#),
                "DIST-сборка снова бакает адрес сервера")

        // Комментарии пропускаются: старый адрес там приведён нарочно, чтобы
        // было видно, что именно убрали. Ищется живой код.
        let code = script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        #expect(!code.contains("api.cruxwing.ai"),
                "в orakul вернулся адрес чужого сервера")

        // И останов на случай, если подстановка вернётся другим путём.
        #expect(script.contains("В DIST-сборку попал адрес сервера"),
                "проверка на непустой адрес пропала — ошибка пройдёт молча")
    }

    @MainActor
    @Test("пустого поля в сборке мало — важно, что возвращает Config")
    func emptyBuildValueMeansNoBackendAtRuntime() {
        // Проверки одного build.sh не хватило, и это уже второй такой случай в
        // этом файле. Тогда тест смотрел в `.env`, пока сборка форсила своё;
        // здесь тест смотрел в build.sh, пока Config подставлял продуктовый
        // адрес по умолчанию. Оба раза проверяемое место было не тем, которое
        // решает. Решает то, что приложение получает на руки.
        #expect(!Config.backendBaseURL.contains("cruxwing"),
                "orakul обращается к серверу другого продукта: \(Config.backendBaseURL)")

        guard Config.backendBaseURL.isEmpty else { return }  // сборка с сервером — не наш случай
        let state = AppState()
        #expect(!state.wheesprAvailable, "предлагается вход в несуществующий аккаунт")
        #expect(!state.ledgerConfigured, "показывается счёт без сервера")
    }

    @Test("маршрут через сервер выключен независимо от адреса")
    func gatewayRouteStaysOff() {
        #expect(Secrets.llmGateway.lowercased() != "backend")
    }
}
