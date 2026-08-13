import Foundation
import Testing
@testable import MeetGPT

/// Ключ берут там же, куда потом уходит запрос.
///
/// У трёх китайских провайдеров две площадки: китайская и международная. Это
/// РАЗНЫЕ сервисы с независимыми аккаунтами, и ключ одной на другой не
/// работает — приходит 401. Подтверждено документацией вендоров:
///
/// - Moonshot: `platform.moonshot.cn` против `platform.moonshot.ai`, аккаунты
///   независимы, при несовпадении — `invalid_authentication_error`;
/// - Zhipu: `open.bigmodel.cn` против `z.ai` — отдельные системы аккаунтов;
/// - Alibaba DashScope: Пекин против Сингапура, «у каждого региона свой
///   домен, свой API-ключ и свой список моделей», кросс-региональный ключ
///   даёт 401.
///
/// orakul звал международные адреса, а подсказка отправляла на китайскую
/// консоль: ключ гарантированно не работал, и три провайдера из брифа
/// («низкозатратные китайские модели») выглядели сломанными. Вдобавок на
/// китайских площадках регистрация обычно требует местного телефона — совет
/// был ещё и невыполним.
@Suite("Консоль ключа и адрес запроса — одна площадка")
struct ProviderConsoleMatchTests {

    /// Провайдер → (что должно быть в подсказке, чего быть не должно, хост запроса).
    private static let pairs: [(LLMProvider, String, String, String)] = [
        (.qwen, "modelstudio.console.aliyun.com", "dashscope.console.aliyun.com",
         "dashscope-intl.aliyuncs.com"),
        (.zhipu, "z.ai", "open.bigmodel.cn", "api.z.ai"),
        (.moonshot, "platform.moonshot.ai", "platform.moonshot.cn", "api.moonshot.ai"),
    ]

    @Test("подсказка ведёт на ту же площадку, куда уходит запрос")
    func hintMatchesEndpoint() {
        for (provider, wanted, chinaOnly, _) in Self.pairs {
            let hint = provider.keyConsoleHint
            #expect(hint.contains(wanted),
                    "\(provider): подсказка не ведёт на международную консоль — «\(hint)»")
            #expect(!hint.contains(chinaOnly),
                    "\(provider): подсказка ведёт на китайскую консоль, а запрос идёт на международный адрес — такой ключ вернёт 401")
        }
    }

    @Test("адреса запросов остаются международными")
    func endpointsStayInternational() {
        // Обратная сторона: если запросы однажды переведут на китайские
        // адреса, подсказки станут неверными в другую сторону. Пусть это
        // всплывёт здесь, а не в виде 401 у человека на звонке.
        for (provider, _, _, host) in Self.pairs {
            let endpoint = provider.openAIDialect?.endpoint.host ?? "—"
            #expect(endpoint == host,
                    "\(provider) уходит на \(endpoint), а подсказка рассчитана на \(host)")
        }
    }
}
