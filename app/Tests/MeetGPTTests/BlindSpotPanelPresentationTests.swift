import Testing
@testable import MeetGPT

@Suite("Blind Spot panel presentation")
struct BlindSpotPanelPresentationTests {
    private func presentation(
        enabled: Bool = true,
        snoozed: Bool = false,
        isRecording: Bool = true,
        goalSet: Bool = true,
        hasSuggestions: Bool = false,
        secondsRemaining: Int = 600,
        failureMessage: String? = nil,
        quotaMessage: String? = nil
    ) -> BlindSpotPanelPresentation {
        .resolve(
            enabled: enabled,
            snoozed: snoozed,
            isRecording: isRecording,
            goalSet: goalSet,
            hasSuggestions: hasSuggestions,
            secondsRemaining: secondsRemaining,
            failureMessage: failureMessage,
            quotaMessage: quotaMessage
        )
    }

    @Test("Settings off with no cards is never presented as live or listening")
    func offWithoutCards() {
        let panel = presentation(
            enabled: false,
            failureMessage: "Blind Spot couldn't reach an AI provider. Retrying automatically."
        )

        #expect(panel.isVisible)
        #expect(panel.heading == "Подсказки выключены")
        #expect(panel.statusMessage == "Включите поиск слепых зон в настройках, чтобы продолжить.")
        #expect(panel.statusKind == .informational)
        #expect(!panel.showsCards)
        #expect(!panel.canPause)
        #expect(!panel.canResume)
        #expect(!(panel.statusMessage ?? "").contains("Retrying"))
        #expect(!(panel.statusMessage ?? "").contains("Listening"))
    }

    @Test("Settings off keeps surfaced cards visible under an off heading")
    func offWithPreservedCards() {
        let panel = presentation(enabled: false, hasSuggestions: true)

        #expect(panel.isVisible)
        #expect(panel.showsCards)
        #expect(panel.heading == "Подсказки выключены")
        #expect(panel.statusMessage == "Включите поиск слепых зон в настройках, чтобы продолжить.")
    }

    @Test("per-call pause keeps cards and offers resume")
    func pausedWithCards() {
        let panel = presentation(snoozed: true, hasSuggestions: true)

        #expect(panel.heading == "Подсказки приостановлены")
        #expect(panel.statusMessage == "Приостановлены на этот звонок.")
        #expect(panel.showsCards)
        #expect(!panel.canPause)
        #expect(panel.canResume)
    }

    @Test("an active provider failure replaces listening with bounded retry status")
    func activeFailure() {
        let failure = "Blind Spot couldn't reach an AI provider. Retrying automatically."
        let panel = presentation(failureMessage: failure)

        #expect(panel.heading == "Подсказки по ходу")
        #expect(panel.statusMessage == failure)
        #expect(panel.statusKind == .providerFailure)
        #expect(panel.canPause)
        #expect(!(panel.statusMessage ?? "").contains("Listening"))
    }

    @Test("quota latch overrides stale retry status and pauses the feed")
    func quotaOverridesFailure() {
        let quota = "You've used this month's co-pilot credits."
        let panel = presentation(
            failureMessage: "Blind Spot couldn't reach an AI provider. Retrying automatically.",
            quotaMessage: quota
        )

        #expect(panel.heading == "Подсказки приостановлены")
        #expect(panel.statusMessage == quota)
        #expect(panel.statusKind == .quota)
        #expect(!panel.canPause)
        #expect(!panel.canResume)
        #expect(!(panel.statusMessage ?? "").contains("Retrying"))
        #expect(!(panel.statusMessage ?? "").contains("Listening"))
    }

    @Test("quota remains visible when Settings is also off")
    func quotaWhileOff() {
        let quota = "Co-pilot allowance is exhausted for this period."
        let panel = presentation(
            enabled: false,
            hasSuggestions: true,
            failureMessage: "Retrying automatically.",
            quotaMessage: quota
        )

        #expect(panel.heading == "Подсказки выключены")
        #expect(panel.statusMessage == quota)
        #expect(panel.statusKind == .quota)
        #expect(panel.showsCards)
    }
}
