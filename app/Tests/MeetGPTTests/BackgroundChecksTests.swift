import Testing
import Foundation
@testable import MeetGPT

/// The two live background-check toggles (Fact-check / Rhetoric watch during
/// calls). Both default OFF — background LLM work is opt-in for cost — and
/// round-trip through UserDefaults. Serialized: they touch shared defaults.
@Suite("Background-check toggles", .serialized)
struct BackgroundCheckToggleTests {
    private func withFactCheckDefault(_ body: () -> Void) {
        let key = "copilot.factcheck"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    private func withRhetoricDefault(_ body: () -> Void) {
        let key = "copilot.rhetoric"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    private func withFacilitationDefault(_ body: () -> Void) {
        let key = "copilot.facilitation"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    @Test("fact-check-during-calls defaults off")
    func factCheckDefaultsOff() {
        withFactCheckDefault {
            #expect(Config.factCheckDuringCallsEnabled == false)
        }
    }

    @Test("rhetoric-during-calls defaults off")
    func rhetoricDefaultsOff() {
        withRhetoricDefault {
            #expect(Config.rhetoricDuringCallsEnabled == false)
        }
    }

    @Test("fact-check toggle round-trips through UserDefaults")
    func factCheckRoundTrips() {
        withFactCheckDefault {
            Config.factCheckDuringCallsEnabled = true
            #expect(Config.factCheckDuringCallsEnabled == true)
            Config.factCheckDuringCallsEnabled = false
            #expect(Config.factCheckDuringCallsEnabled == false)
        }
    }

    @Test("rhetoric toggle round-trips through UserDefaults")
    func rhetoricRoundTrips() {
        withRhetoricDefault {
            Config.rhetoricDuringCallsEnabled = true
            #expect(Config.rhetoricDuringCallsEnabled == true)
            Config.rhetoricDuringCallsEnabled = false
            #expect(Config.rhetoricDuringCallsEnabled == false)
        }
    }

    @Test("facilitation-during-calls defaults off")
    func facilitationDefaultsOff() {
        withFacilitationDefault {
            #expect(Config.facilitationDuringCallsEnabled == false)
        }
    }

    @Test("facilitation toggle round-trips through UserDefaults")
    func facilitationRoundTrips() {
        withFacilitationDefault {
            Config.facilitationDuringCallsEnabled = true
            #expect(Config.facilitationDuringCallsEnabled == true)
            Config.facilitationDuringCallsEnabled = false
            #expect(Config.facilitationDuringCallsEnabled == false)
        }
    }
}

/// The background Rhetoric watch's reply parser: turns a model completion into
/// a compact note, or nil when the watch found nothing worth flagging.
@Suite("RhetoricWatch.parse")
struct RhetoricWatchParseTests {
    @Test("bare NONE sentinel yields no note")
    func noneYieldsNil() {
        #expect(RhetoricWatch.parse("NONE") == nil)
    }

    @Test("NONE with trailing prose still yields no note")
    func noneWithProseYieldsNil() {
        #expect(RhetoricWatch.parse("NONE — nothing to flag here.") == nil)
    }

    @Test("empty / whitespace reply yields no note")
    func emptyYieldsNil() {
        #expect(RhetoricWatch.parse("") == nil)
        #expect(RhetoricWatch.parse("   \n  ") == nil)
    }

    @Test("a real flag is returned, stripped of wrapping quotes and punctuation")
    func realFlagReturned() {
        let note = RhetoricWatch.parse("\"The revenue claim contradicts the earlier churn figure.\"")
        #expect(note == "The revenue claim contradicts the earlier churn figure")
    }

    @Test("an over-long flag is truncated to keep the panel compact")
    func longFlagTruncated() {
        let long = String(repeating: "a", count: 400)
        let note = RhetoricWatch.parse(long)
        #expect(note?.count == 240)
    }

    @Test("a lowercase 'none' is a real (non-sentinel) note")
    func lowercaseNoneIsNotSentinel() {
        // The sentinel check is uppercased, so the exact word matches, but a
        // sentence merely containing "none" mid-flag should survive.
        let note = RhetoricWatch.parse("No one owns the rollout decision.")
        #expect(note == "No one owns the rollout decision")
    }
}

/// The background Facilitation watch's parser and prompt composition.
@Suite("FacilitationWatch")
struct FacilitationWatchTests {
    @Test("on-track meetings yield no steering note")
    func onTrackYieldsNil() {
        #expect(FacilitationWatch.parse("NONE") == nil)
        #expect(FacilitationWatch.parse("NONE — the discussion is on the goal.") == nil)
        #expect(FacilitationWatch.parse("   ") == nil)
    }

    @Test("a drift flag is returned, stripped of wrapping quotes/punctuation")
    func driftFlagReturned() {
        let note = FacilitationWatch.parse("\"You've drifted onto pricing — steer back to scope.\"")
        #expect(note == "You've drifted onto pricing — steer back to scope")
    }

    @Test("an over-long flag is truncated to keep the panel compact")
    func longFlagTruncated() {
        let note = FacilitationWatch.parse(String(repeating: "b", count: 400))
        #expect(note?.count == 240)
    }

    @Test("the user prompt carries the goal when one is set")
    func userPromptCarriesGoal() {
        let prompt = FacilitationWatch.userPrompt(goal: "Decide launch date",
                                                  transcript: "…discussion…")
        #expect(prompt.contains("Meeting goal: Decide launch date"))
        #expect(prompt.contains("…discussion…"))
    }

    @Test("the user prompt uses a neutral cue when no goal is set")
    func userPromptFallsBackWithoutGoal() {
        let prompt = FacilitationWatch.userPrompt(goal: "   ", transcript: "…discussion…")
        #expect(prompt.contains("(no explicit goal set)"))
    }
}
