import Foundation
import Testing
@testable import MeetGPT

/// What the app is allowed to report about how it is used.
///
/// The acceptance criterion is "no meeting content, goal text or connector data
/// in any payload". These tests exist because that promise used to rest on
/// discipline — the tracker took `[String: Any]` — and a promise a reviewer has
/// to enforce on every future call site is a promise that eventually breaks.
///
/// Two of these tests matter more than the rest. `everyEventCarriesOnlyDimensions`
/// enumerates every event the app can emit and asserts none of it could be prose.
/// `stageNamesMatchTheServer` pins the taxonomy against the endpoint's allow-list,
/// because a stage the server does not know is answered with a 400 that the
/// client deliberately ignores: the event simply never arrives, and no test that
/// only looks at the client would notice.
// Serialized: the opt-out tests below write a shared UserDefaults key, and run
// in parallel they restore each other's state mid-assertion.
@Suite("Analytics events", .serialized)
struct AnalyticsEventTests {

    /// Every event, with representative payloads. New cases belong here — this
    /// is the sample the structural tests below run over.
    static let allEvents: [AnalyticsEvent] = [
        .surfaceOpened(.transcript), .surfaceOpened(.blindSpot),
        .promptRun(promptID: "agenda", style: .defaultStyle),
        .promptRun(promptID: "custom-DEADBEEF-0000", style: .defaultStyle),
        .sessionEnded(duration: .under15m, hadTranscript: true, usedAI: true),
        .sessionEnded(duration: .under1m, hadTranscript: false, usedAI: false),
        .recordingAbandoned(after: .under1m),
        .featureUsed(.glossary), .featureFailed(.diarize),
        .appOpen, .firstRecording, .firstAIAction, .paywallView, .promoRedeem,
        .checkoutStart(plan: "cruxwing.pro.monthly"),
        .subscribeSuccess(tier: "pro", via: .iap),
        .addOnGranted(addOn: "minutes.500", quantity: 500, unit: "minutes"),
    ]

    // MARK: - The guarantee

    @Test("every event carries dimensions, never prose")
    func everyEventCarriesOnlyDimensions() {
        // The whole point of the type. If this fails, some case has grown a
        // parameter that can carry what people said on a call.
        for event in Self.allEvents {
            for (key, value) in event.properties {
                #expect(value.isWellFormed,
                        "\(event.name).\(key) is not a dimension: \(value)")
            }
        }
    }

    @Test("prose is rejected whatever key it is filed under", arguments: [
        "We should ship the Falcon migration before Q3",
        "discuss pricing with Maria",
        "a-very-long-identifier-that-runs-past-the-forty-character-limit",
    ])
    func proseIsNotAToken(text: String) {
        // The key-name filter on the server catches `email`; it does nothing
        // about a key called `v`. This is the rule that does the work.
        #expect(!AnalyticsValue.token(text).isWellFormed)
    }

    @Test("short single words are still valid dimensions")
    func ordinaryTokensSurvive() {
        // The opposite failure: a rule so strict that legitimate dimensions
        // stop being reportable, and the feature collects nothing.
        for token in ["pro", "ai_studio", "cruxwing.pro.monthly", "0-1m", "custom"] {
            #expect(AnalyticsValue.token(token).isWellFormed, "rejected \(token)")
        }
    }

    @Test("an empty token is not valid")
    func emptyTokenRejected() {
        #expect(!AnalyticsValue.token("").isWellFormed)
    }

    @Test("malformed values are dropped rather than sent")
    func malformedValuesDropped() {
        // Belt and braces for a case added carelessly later: the wire payload
        // filters, so the failure is a missing dimension, not a leak.
        let leaky: [String: AnalyticsValue] = ["ok": .token("pro"),
                                               "bad": .token("a sentence here")]
        let wire = leaky.compactMapValues { $0.isWellFormed ? $0.wireValue : nil }
        #expect(wire.keys.sorted() == ["ok"])
    }

    // MARK: - Prompt identifiers

    @Test("a built-in prompt reports by name")
    func builtInPromptReportsName() {
        // "Which prompts are run" is the question; for built-ins the id answers
        // it exactly, and the vocabulary is fixed in code.
        #expect(AnalyticsEvent.promptToken(for: "agenda") == "agenda")
        #expect(AnalyticsEvent.promptToken(for: "brainstorm") == "brainstorm")
    }

    @Test("a user-defined prompt collapses to a constant")
    func customPromptCollapses() {
        // The trap this closes: a custom prompt's id is a per-user UUID and its
        // title is text the user wrote. Reporting either would put a per-user
        // identifier — or the user's own words — into analytics, and "a custom
        // one" answers the question without carrying anything of theirs.
        #expect(AnalyticsEvent.promptToken(for: "custom-\(UUID().uuidString)") == "custom")
    }

    @Test("two different custom prompts are indistinguishable")
    func customPromptsAreNotFingerprints() {
        let first = AnalyticsEvent.promptToken(for: "custom-\(UUID().uuidString)")
        let second = AnalyticsEvent.promptToken(for: "custom-\(UUID().uuidString)")
        #expect(first == second)
    }

    @Test("every built-in prompt id is a valid dimension")
    func builtInIDsAreDimensions() {
        // If someone adds a built-in prompt with a spaced id, its events would
        // be silently dropped at the boundary rather than reported.
        for prompt in QuickPrompts.all where !prompt.isCustom {
            #expect(AnalyticsValue.token(prompt.id).isWellFormed,
                    "prompt id is not reportable: \(prompt.id)")
        }
    }

    // MARK: - Duration buckets

    @Test("durations bucket rather than report exact seconds", arguments: [
        (30.0, "0-1m"), (61.0, "1-5m"), (600.0, "5-15m"),
        (1000.0, "15-30m"), (2000.0, "30-60m"), (7200.0, "60m+"),
    ])
    func durationBuckets(seconds: TimeInterval, expected: String) {
        // An exact second count is a far better fingerprint than a range, and
        // no question this feature answers needs the resolution.
        #expect(AnalyticsEvent.DurationBucket(seconds: seconds).rawValue == expected)
    }

    @Test("a zero-length recording still buckets")
    func zeroDuration() {
        #expect(AnalyticsEvent.DurationBucket(seconds: 0) == .under1m)
    }

    @Test("counts are clamped so they cannot become fingerprints")
    func countsClamped() {
        #expect(AnalyticsValue.count(999_999).wireValue as? Int == AnalyticsValue.maxCount)
        #expect(!AnalyticsValue.count(-1).isWellFormed)
    }

    // MARK: - Taxonomy

    @Test("stage names are the ones the server accepts")
    func stageNamesMatchTheServer() {
        // Mirrors FUNNEL_STAGES in cruxwing-api/functions/funnel.js. A stage
        // missing there is answered with a 400 that FunnelTracker ignores by
        // design, so the event vanishes with nothing logged anywhere. The
        // cross-repo check below keeps this literal honest.
        let serverStages: Set<String> = [
            "landing_view", "cta_click", "download_start", "app_open",
            "onboarding_complete", "first_recording", "first_ai_action",
            "paywall_view", "checkout_start", "subscribe_success", "promo_redeem",
            "surface_opened", "prompt_run", "session_ended", "recording_abandoned",
            "feature_used", "feature_failed",
        ]
        for event in Self.allEvents {
            #expect(serverStages.contains(event.name),
                    "\(event.name) would be rejected by the endpoint")
        }

        // And check that literal against the shared contract, which is emitted
        // from the server's own FUNNEL_STAGES and replicated into this repo.
        // Reading the contract rather than the sibling checkout means the pin
        // holds in a standalone clone instead of quietly skipping there.
        #expect(Set(SharedContract.funnelStages) == serverStages,
                "contract/contract.json has drifted — re-run cruxwing-api/scripts/emit-contract.js")
    }

    @Test("add-on grants deliberately share the subscription stage")
    func addOnSharesSubscribeStage() {
        // Not an oversight. An add-on is not a subscription start, so a distinct
        // stage would be more accurate — but it would silently redefine what the
        // existing funnel counts, and a metric whose meaning changes without
        // notice is worse than one that is coarse. Written down so the next
        // reader sees a decision rather than a bug.
        #expect(AnalyticsEvent.addOnGranted(addOn: "minutes.500", quantity: 500, unit: "minutes").name
                == AnalyticsEvent.subscribeSuccess(tier: "pro", via: .iap).name)
        #expect(AnalyticsEvent.addOnGranted(addOn: "minutes.500", quantity: 500, unit: "minutes")
                .properties["addon"] != nil,
                "the addon prop is what tells the two apart downstream")
    }

    @Test("stage names are dimension-shaped too")
    func stageNamesAreWellFormed() {
        for event in Self.allEvents {
            #expect(AnalyticsValue.token(event.name).isWellFormed, "bad stage: \(event.name)")
        }
    }

    // MARK: - Opt-out

    @Test("the opt-out governs every event without exception")
    func optOutGovernsEverything() {
        // Stated as an acceptance criterion. It holds structurally — track() and
        // trackOnce() are the only emitters and both check the flag first — and
        // the observable proof is that no once-per-device event records itself
        // while opted out, for every such event, not just the one below.
        let onceEvents: [AnalyticsEvent] = [.firstRecording, .firstAIAction]
        let keys = onceEvents.map { "funnel.fired.\($0.name)" }
        let previous = Config.funnelOptOut
        defer {
            Config.funnelOptOut = previous
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }

        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        Config.funnelOptOut = true
        onceEvents.forEach { FunnelTracker.trackOnce($0) }

        for key in keys {
            #expect(!UserDefaults.standard.bool(forKey: key),
                    "\(key) fired despite the opt-out")
        }
    }

    @Test("opting out does not consume a once-per-device event")
    func optOutDoesNotBurnActivation() {
        // Ordering that matters: if the fired-flag were set before the opt-out
        // check, a user who opts in later would never report activation, and
        // the funnel would show a permanent hole with no cause.
        let previous = Config.funnelOptOut
        defer {
            Config.funnelOptOut = previous
            UserDefaults.standard.removeObject(forKey: "funnel.fired.first_recording")
        }
        UserDefaults.standard.removeObject(forKey: "funnel.fired.first_recording")
        Config.funnelOptOut = true
        FunnelTracker.trackOnce(.firstRecording)
        #expect(!UserDefaults.standard.bool(forKey: "funnel.fired.first_recording"))
    }
}
