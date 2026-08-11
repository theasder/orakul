import Foundation

/// Where a new user is in the first-run flow.
///
/// A single completed-yes/no boolean cannot express "granted the permissions,
/// quit before the sample", so an interrupted flow either restarted from the top
/// or skipped the part that never ran. The last COMPLETED step is stored
/// instead — an interrupted step is not a finished one.
enum OnboardingStep: String, Codable, CaseIterable, Comparable {
    /// Permissions plus the capture check.
    case capture
    /// The bundled sample call.
    case sample

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        guard let l = allCases.firstIndex(of: lhs),
              let r = allCases.firstIndex(of: rhs) else { return false }
        return l < r
    }

    var next: OnboardingStep? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let following = Self.allCases.index(after: index)
        return following < Self.allCases.endIndex ? Self.allCases[following] : nil
    }

    /// Progress only ever moves forward. Revoking a permission reopens the
    /// capture check, and finishing it a second time must not erase a sample the
    /// user already sat through.
    static func furthestCompleted(recorded: OnboardingStep?,
                                  finished: OnboardingStep) -> OnboardingStep {
        guard let recorded else { return finished }
        return Swift.max(recorded, finished)
    }

    /// What to show after finishing a step, or nil to close the flow.
    ///
    /// Keyed off the furthest step ever completed rather than the one just
    /// finished: someone re-running the capture check because macOS dropped a
    /// permission has already seen the sample, and replaying it would make a
    /// permissions repair feel like a factory reset.
    static func nextToPresent(finished: OnboardingStep,
                              recorded: OnboardingStep?) -> OnboardingStep? {
        furthestCompleted(recorded: recorded, finished: finished).next
    }
}

/// Which onboarding tip to show, if any.
///
/// One at a time, in a fixed order, each retired by USING the feature rather
/// than by reading about it — a tip that survives its own demonstration is
/// nagging.
enum CoachTip: String, CaseIterable {
    case recordingType
    case goalQuality
    case pinDecision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordingType: "Not a meeting?"
        case .goalQuality:   "Give the call a goal"
        case .pinDecision:   "That's a decision"
        }
    }

    var body: String {
        switch self {
        case .recordingType:
            "Cruxwing reads what's on screen and adapts — a lecture gets a learning plan, not action items. Override the type here any time."
        case .goalQuality:
            "One line: what has to be true when this call ends? The co-pilot measures every blind spot against it."
        case .pinDecision:
            "Press 📌 and the confirmed decision lands in the ledger with its rationale and owner. The transcript is not the record."
        }
    }

    /// The control this tip points at, so a view can anchor it rather than
    /// float it somewhere generic.
    var anchor: String {
        switch self {
        case .recordingType: "recording.context.menu"
        case .goalQuality:   "call.goal.field"
        case .pinDecision:   "prompt.logdecision"
        }
    }

    /// Tips whose feature the app can already SEE the user operating.
    ///
    /// Retirement is otherwise driven by an `onChange`, which by definition
    /// cannot fire for state that was already set when the view appeared — so
    /// someone who pinned a recording type in an earlier session would be taught
    /// about the control they are visibly using.
    static func usedTipIDs(recordingTypeChosen: Bool) -> Set<String> {
        recordingTypeChosen ? [CoachTip.recordingType.id] : []
    }
}

enum CoachTipQueue {
    struct Context {
        let isRecording: Bool
        let retired: Set<String>
        let hasGoal: Bool
        /// A finished call with something in the transcript. Named for what the
        /// app can actually observe — there is no "decision candidate" state to
        /// key off, and pretending otherwise put the tip on the wrong trigger.
        let hasSomethingToLog: Bool
        /// Whether the "До понедельника звонков нет?" card is on screen right now.
        ///
        /// It already teaches what the recordingType tip teaches — a lecture
        /// gets a learning plan, and the type is yours to override — and it
        /// teaches it with buttons. Both rendered at once in the same sidebar,
        /// two cards apart, which reads as the app repeating itself.
        let showsNoCallCard: Bool

        init(isRecording: Bool, retired: Set<String>,
             hasGoal: Bool, hasSomethingToLog: Bool,
             showsNoCallCard: Bool = false) {
            self.isRecording = isRecording
            self.retired = retired
            self.hasGoal = hasGoal
            self.hasSomethingToLog = hasSomethingToLog
            self.showsNoCallCard = showsNoCallCard
        }
    }

    /// At most one tip, ever. Returning an optional rather than a list is the
    /// enforcement — there is no way for a caller to render two.
    static func next(_ context: Context) -> CoachTip? {
        // Nothing new appears during a live call. The user is in a meeting.
        guard !context.isRecording else { return nil }
        return CoachTip.allCases.first { tip in
            guard !context.retired.contains(tip.id) else { return false }
            switch tip {
            case .recordingType:
                // Suppressed, not retired: dismissing the card brings it back,
                // because the lesson still has not been delivered anywhere else.
                return !context.showsNoCallCard
            case .goalQuality:
                // Pointless once a goal exists — the user already knows.
                return !context.hasGoal
            case .pinDecision:
                // Only worth saying when there is something to pin.
                return context.hasSomethingToLog
            }
        }
    }
}

/// Deciding whether a tip is finished with.
///
/// Separated from the SwiftUI modifier so the rule can be tested on its own:
/// the modifier's job is to notice the change, and this decides what that
/// change means.
enum CoachTipRetirement {
    /// The new retired set, or nil when there is nothing to write.
    ///
    /// Returning nil rather than an unchanged set matters: the modifier fires on
    /// state changes that have nothing to do with this tip, and each write would
    /// otherwise hit UserDefaults for no reason.
    static func retiring(_ tip: CoachTip,
                         used: Bool,
                         in retired: Set<String>) -> Set<String>? {
        guard used, !retired.contains(tip.id) else { return nil }
        return retired.union([tip.id])
    }
}

/// When the sidebar's two onboarding prompts are worth showing.
///
/// Extracted from the views so the conditions can be tested: both cards are
/// easy to get subtly wrong in the direction of nagging someone who is busy.
enum OnboardingPrompts {
    static func setupRemaining(captureVerified: Bool,
                               signedIn: Bool,
                               appsConnected: Bool) -> Int {
        [captureVerified, signedIn, appsConnected].filter { !$0 }.count
    }

    /// Signing in is optional — recording works without it — so the row carries
    /// its own dismiss. Hiding the whole card to be rid of one line would take
    /// the connected-apps step with it.
    static func showsSignInRow(signedIn: Bool, dismissed: Bool) -> Bool {
        !signedIn && !dismissed
    }

    /// The empty evening between installing and the next real meeting — and
    /// nothing else. Not during a call, not once there is history, and not while
    /// the onboarding sheet is still up in front of it.
    static func showsNoCallCard(dismissed: Bool,
                                isRecording: Bool,
                                hasSavedSessions: Bool,
                                lastStep: OnboardingStep?) -> Bool {
        !dismissed && !isRecording && !hasSavedSessions && lastStep == .sample
    }
}

extension OnboardingGate {
    /// The step to present, or nil when the flow is finished and both
    /// permissions still hold. Missing permissions always drag the user back to
    /// `.capture`, preserving the behaviour a rename or re-sign depends on.
    static func step(lastCompleted: OnboardingStep?,
                     microphoneGranted: Bool,
                     screenRecordingGranted: Bool) -> OnboardingStep? {
        guard microphoneGranted, screenRecordingGranted else { return .capture }
        guard let lastCompleted else { return .capture }
        return lastCompleted.next
    }
}
