import Testing
import Foundation
@testable import MeetGPT

/// The call theme drives a per-domain skill pack layered onto every AI action.
/// It is inferred cheaply (keyword scoring over goal + transcript) unless the
/// user pins one. Pin the scoring, the resolve precedence, and the metadata.
@Suite("Call theme")
struct CallThemeTests {

    // MARK: - infer: keyword scoring picks the right theme

    @Test("clearly-sales text infers .sales")
    func infersSales() {
        // pricing, discount, prospect, quota — four sales-only signals.
        let goal = "Land the pricing conversation with a fresh prospect."
        let transcript = "We offered a discount to hit our quota this quarter."
        #expect(CallTheme.infer(goal: goal, transcript: transcript) == .sales)
    }

    @Test("clearly-hiring text infers .hiring")
    func infersHiring() {
        // candidate, interview, competency, screening — four hiring-only signals.
        let goal = "Run the interview and screening for this candidate."
        let transcript = "Probe each competency with a behavioral follow-up."
        #expect(CallTheme.infer(goal: goal, transcript: transcript) == .hiring)
    }

    @Test("clearly-engineering text infers .engineering")
    func infersEngineering() {
        // architecture, database, latency, refactor — four engineering-only signals.
        let goal = "Review the service architecture before we refactor."
        let transcript = "The database latency spiked under load last night."
        #expect(CallTheme.infer(goal: goal, transcript: transcript) == .engineering)
    }

    @Test("Russian product and engineering discussions keep their domain framing")
    func infersRussianThemes() {
        #expect(CallTheme.infer(
            goal: "Обсудить архитектуру API и миграцию базы данных",
            transcript: "Нужно исправить задержку и спланировать деплой."
        ) == .engineering)
        #expect(CallTheme.infer(
            goal: "Согласовать дорожную карту продукта",
            transcript: "Обсудим новую функцию, требования пользователей и запуск."
        ) == .product)
    }

    @Test("empty input falls back to .general")
    func emptyIsGeneral() {
        #expect(CallTheme.infer(goal: "", transcript: "") == .general)
        #expect(CallTheme.infer(goal: "   ", transcript: "  ") == .general)
    }

    @Test("neutral text with no signals falls back to .general")
    func neutralIsGeneral() {
        let goal = "Let's have a friendly chat about our weekend."
        #expect(CallTheme.infer(goal: goal, transcript: "Nice to catch up.") == .general)
    }

    @Test("a single stray signal stays .general (confidence floor of two)")
    func singleSignalIsGeneral() {
        // Only "pricing" matches — one signal is below the floor.
        #expect(CallTheme.infer(goal: "Talk about pricing.", transcript: "") == .general)
    }

    // MARK: - resolve: override wins, else infer

    @Test("resolve returns the override when non-nil")
    func resolveHonorsOverride() {
        // Sales-flavored text, but a legal override must win.
        let resolved = CallTheme.resolve(override: .legal,
                                         goal: "Discuss pricing and the discount for this prospect quota.",
                                         transcript: "")
        #expect(resolved == .legal)
    }

    @Test("resolve infers when override is nil")
    func resolveInfersWithoutOverride() {
        let resolved = CallTheme.resolve(override: nil,
                                         goal: "Review the architecture and database latency before we refactor.",
                                         transcript: "")
        #expect(resolved == .engineering)
    }

    @Test("resolve with nil override and empty input is .general")
    func resolveEmptyIsGeneral() {
        #expect(CallTheme.resolve(override: nil, goal: "", transcript: "") == .general)
    }

    // MARK: - guidance

    @Test("guidance is non-nil for every concrete theme, nil only for .general")
    func guidanceForConcreteThemes() {
        for theme in CallTheme.allCases where theme != .general {
            #expect(theme.guidance != nil, "\(theme.rawValue) should carry a skill pack")
            #expect(theme.guidance?.isEmpty == false, "\(theme.rawValue) has an empty skill pack")
        }
        #expect(CallTheme.general.guidance == nil)
    }

    // MARK: - metadata stability

    @Test("allCases is stable: 11 themes, each with a label and a symbol")
    func metadataIsStable() {
        #expect(CallTheme.allCases.count == 11)
        for theme in CallTheme.allCases {
            #expect(!theme.label.isEmpty, "\(theme.rawValue) has an empty label")
            #expect(!theme.symbol.isEmpty, "\(theme.rawValue) has an empty symbol")
            #expect(theme.id == theme.rawValue)
        }
    }
}
