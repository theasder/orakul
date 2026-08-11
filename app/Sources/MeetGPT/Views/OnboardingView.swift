import SwiftUI

/// First run, in two acts: prove the Mac can hear the room, then show the
/// product loop on a written call so the user does not have to wait for their
/// next meeting to find out what this is.
///
/// The step is persisted as the last one COMPLETED (`Config.onboardingStep`), so
/// quitting halfway resumes where it stopped rather than restarting or skipping.
/// Sign-in is deliberately absent: it lives in the sidebar's setup card, after
/// the user has seen what the co-pilot actually produces.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Where to start — the resume point by default.
    @State private var step: OnboardingStep

    /// `startingAt` comes from `ContentView`, which has already re-checked the
    /// real permission state. A caller that passes nil does not know the answer,
    /// and the old fallback computed one from pretend-granted permissions — so
    /// a user with a revoked permission could be dropped straight into the
    /// sample. Beginning at the capture check is the only conservative answer.
    init(startingAt step: OnboardingStep? = nil) {
        _step = State(initialValue: step ?? .capture)
    }

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.onboarding)
    }

    @ViewBuilder private var trackedBody: some View {
        // Scrolls rather than clips. Without this, a short window
        // over-constrains the fixed-size VStack: SwiftUI centre-clips it (the
        // banner and column headers disappear under the top edge) and the
        // children keep drawing at full size, so the footer lands ON the
        // transcript rows and rows bleed through the box border — which reads
        // as a struck-through speaker name. One container, all three symptoms.
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                switch step {
                case .capture:
                    CaptureCheckStep { advance(from: .capture) }
                case .sample:
                    SampleRunStep { advance(from: .sample) }
                }

                StepDots(current: step)
            }
            .padding(Space.xl)
        }
        .frame(width: step == .capture ? 480 : 720)
        .frame(minHeight: 320, maxHeight: 760)
        .background(Theme.canvas)
    }

    private func advance(from finished: OnboardingStep) {
        let recorded = Config.onboardingStep
        // Only ever moves forward: re-running the capture check after a
        // permission was revoked must not throw away a completed sample.
        Config.onboardingStep = OnboardingStep.furthestCompleted(
            recorded: recorded, finished: finished)
        guard let next = OnboardingStep.nextToPresent(
            finished: finished, recorded: recorded) else {
            dismiss()
            return
        }
        step = next
    }
}

/// Two acts, so the reader knows whether they are nearly done. A sequence
/// marker because the flow genuinely is a sequence.
private struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Theme.accent : Theme.hairlineStrong)
                    .frame(width: step == current ? 18 : 6, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current == .capture ? "Step 1 of 2" : "Step 2 of 2")
    }
}
