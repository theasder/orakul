import Foundation

/// Every product-analytics event the app can emit.
///
/// The acceptance criterion for this feature is "no meeting content, goal text
/// or connector data in any payload". Before this type, that was a promise kept
/// by discipline: the tracker took `[String: Any]`, so any call site could pass
/// `["q": goalText]` and nothing would stop it. The server rejects PII-shaped
/// KEY NAMES — `email`, `phone`, `token` — which does nothing about a key called
/// `v` carrying a sentence.
///
/// So the guarantee moved into the type. **No case here accepts free text.**
/// Payloads are Swift enums, bounded integers and booleans; the only string that
/// reaches the wire is a prompt identifier, and that goes through
/// `promptToken(for:)` which collapses user-defined prompts to the constant
/// `custom`. Leaking transcript content is not a mistake a reviewer has to
/// catch — there is no parameter to pass it to.
///
/// `AnalyticsValue.isWellFormed` re-checks the shape at the boundary, so a case
/// added carelessly later still cannot emit prose: the token charset excludes
/// whitespace and caps at 40 characters, and meeting speech is neither.
enum AnalyticsEvent: Equatable {

    // MARK: - Surfaces reached

    /// Which parts of the product people actually get to.
    case surfaceOpened(Surface)

    // MARK: - Prompts run

    /// Which prompt was run. Built-ins by name; anything user-defined arrives
    /// as `custom`, because a custom prompt's id is a per-user identifier and
    /// its title is text the user wrote.
    case promptRun(promptID: String, style: AnswerStyle)

    // MARK: - Where sessions are abandoned

    /// A recording that ended. `hadTranscript` and `usedAI` are what separate a
    /// real session from an abandoned one, and the bucket says how far it got.
    case sessionEnded(duration: DurationBucket, hadTranscript: Bool, usedAI: Bool)

    /// Recording started and stopped without producing a usable transcript.
    case recordingAbandoned(after: DurationBucket)

    /// A feature was used to completion.
    case featureUsed(Feature)

    /// A feature failed in a way the user saw.
    case featureFailed(Feature)

    // MARK: - Commerce (the stages that already existed)

    case appOpen
    case firstRecording
    case firstAIAction
    case paywallView
    case checkoutStart(plan: String)
    case subscribeSuccess(tier: String, via: PurchaseRoute)

    /// An add-on grant. Reports as `subscribe_success` because that is what it
    /// has always reported as — a distinct stage would be more accurate, but it
    /// would silently redefine what the existing funnel counts, and a metric
    /// whose meaning changes without notice is worse than one that is coarse.
    case addOnGranted(addOn: String, quantity: Int, unit: String)

    case promoRedeem

    // MARK: - Closed vocabularies

    /// Named for what a reader of the analytics needs to distinguish, not for
    /// the view types — view names churn, this list should not.
    enum Surface: String, CaseIterable {
        case transcript, brainstorm, context, aiStudio = "ai_studio"
        case quickPrompts = "quick_prompts", factCheck = "fact_check"
        case reflection, blindSpot = "blind_spot"
        case mcpApps = "mcp_apps", teamSources = "team_sources"
        case settings, paywall, onboarding, menuBar = "menu_bar"
    }

    enum Feature: String, CaseIterable {
        case glossary, retranscribeLocal = "retranscribe_local"
        case diarize, exportTranscript = "export_transcript"
        case firefliesImport = "fireflies_import", calendarJoin = "calendar_join"
        case taskWriteback = "task_writeback", followUp = "follow_up"
        case pauseResume = "pause_resume", contextFiles = "context_files"
    }

    enum PurchaseRoute: String { case iap, web, promo }

    /// Durations are bucketed rather than exact. A precise second count is a
    /// far better fingerprint than a range, and no analytics question this
    /// feature exists to answer needs more resolution than these bands.
    enum DurationBucket: String, CaseIterable {
        case under1m = "0-1m", under5m = "1-5m", under15m = "5-15m"
        case under30m = "15-30m", under60m = "30-60m", over60m = "60m+"

        init(seconds: TimeInterval) {
            switch seconds {
            case ..<60: self = .under1m
            case ..<300: self = .under5m
            case ..<900: self = .under15m
            case ..<1800: self = .under30m
            case ..<3600: self = .under60m
            default: self = .over60m
            }
        }
    }

    // MARK: - Wire form

    /// The stage name. Must exist in the server's `FUNNEL_STAGES` allow-list or
    /// the event is rejected with a 400 and silently lost — pinned by a test
    /// that reads the server's list.
    var name: String {
        switch self {
        case .surfaceOpened: return "surface_opened"
        case .promptRun: return "prompt_run"
        case .sessionEnded: return "session_ended"
        case .recordingAbandoned: return "recording_abandoned"
        case .featureUsed: return "feature_used"
        case .featureFailed: return "feature_failed"
        case .appOpen: return "app_open"
        case .firstRecording: return "first_recording"
        case .firstAIAction: return "first_ai_action"
        case .paywallView: return "paywall_view"
        case .checkoutStart: return "checkout_start"
        case .subscribeSuccess, .addOnGranted: return "subscribe_success"
        case .promoRedeem: return "promo_redeem"
        }
    }

    var properties: [String: AnalyticsValue] {
        switch self {
        case let .surfaceOpened(surface):
            return ["surface": .token(surface.rawValue)]
        case let .promptRun(promptID, style):
            return ["prompt": .token(Self.promptToken(for: promptID)),
                    "style": .token(style.rawValue)]
        case let .sessionEnded(duration, hadTranscript, usedAI):
            return ["duration": .token(duration.rawValue),
                    "had_transcript": .flag(hadTranscript),
                    "used_ai": .flag(usedAI)]
        case let .recordingAbandoned(after):
            return ["duration": .token(after.rawValue)]
        case let .featureUsed(feature), let .featureFailed(feature):
            return ["feature": .token(feature.rawValue)]
        case let .checkoutStart(plan):
            return ["plan": .token(plan)]
        case let .subscribeSuccess(tier, via):
            return ["tier": .token(tier), "via": .token(via.rawValue)]
        case let .addOnGranted(addOn, quantity, unit):
            return ["addon": .token(addOn), "quantity": .count(quantity),
                    "unit": .token(unit), "via": .token(PurchaseRoute.iap.rawValue)]
        case .appOpen, .firstRecording, .firstAIAction, .paywallView, .promoRedeem:
            return [:]
        }
    }

    /// A prompt identifier safe to send.
    ///
    /// Built-in ids are a fixed vocabulary defined in `QuickPrompts.all`.
    /// Anything else is a prompt the user created: its id is a per-user UUID
    /// and its title is text they wrote, so both collapse to one constant. The
    /// analytics question is "which prompts get run", and "a custom one" is a
    /// complete answer to that without carrying anything of the user's.
    static func promptToken(for promptID: String) -> String {
        QuickPrompts.all.contains { $0.id == promptID } ? promptID : "custom"
    }

    /// The wire payload, with anything malformed dropped rather than sent.
    var wireProperties: [String: Any] {
        properties.compactMapValues { $0.isWellFormed ? $0.wireValue : nil }
    }
}

/// A value that can appear in an analytics payload.
///
/// Deliberately not `Any`. The token charset — alphanumerics, `_`, `.`, `-`,
/// capped at 40 — is the structural line between a dimension and a sentence:
/// prose contains spaces and runs long, so it cannot pass, whatever key it is
/// filed under.
enum AnalyticsValue: Equatable {
    case flag(Bool)
    case count(Int)
    case token(String)

    static let maxTokenLength = 40
    /// Counts are dimensions, not measurements; an unbounded one is a
    /// fingerprint. Anything larger is clamped.
    static let maxCount = 10_000

    var isWellFormed: Bool {
        switch self {
        case .flag: return true
        case let .count(value): return value >= 0
        case let .token(token):
            guard !token.isEmpty, token.count <= Self.maxTokenLength else { return false }
            return token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber
                                                     || $0 == "_" || $0 == "." || $0 == "-") }
        }
    }

    var wireValue: Any {
        switch self {
        case let .flag(value): return value
        case let .count(value): return min(value, Self.maxCount)
        case let .token(token): return token
        }
    }
}
