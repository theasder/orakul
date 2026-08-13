import SwiftUI

/// One tip, anchored to the control it describes.
///
/// The queue is what keeps this from becoming a tour: `CoachTipQueue.next`
/// returns an optional, so there is no way to render two, and nothing appears at
/// all while a call is being recorded. A tip retires when its feature is used —
/// "Понятно" is the fallback for someone who wants it gone now.
struct CoachTipView: View {
    @EnvironmentObject var state: AppState
    /// Which control is asking. Only the tip pointing here renders, so the
    /// bubble sits under the thing it is talking about.
    let anchor: String

    /// Bumped when this view retires a tip, purely to make SwiftUI re-evaluate
    /// the body. The retired SET is deliberately not cached in @State: a copy
    /// taken at init goes stale the moment another surface — the chip's own
    /// `retiringCoachTip`, or a second CoachTipView — retires something, and the
    /// tip would then sit on screen until the next launch.
    @State private var retirements = 0

    private var tip: CoachTip? {
        _ = retirements
        let candidate = CoachTipQueue.next(.init(
            isRecording: state.isRecording,
            // A feature the user is visibly already operating counts as retired,
            // even though no onChange fired for it this launch.
            retired: Config.coachTipsRetired.union(CoachTip.usedTipIDs(
                recordingTypeChosen: !state.recordingContextSelection.isAutomatic)),
            hasGoal: !state.callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            // A finished call with a transcript is something to log. The old
            // trigger keyed off advice-kind suggestions, which are not decisions
            // and put the tip in front of people with nothing to pin.
            hasSomethingToLog: !state.transcript.isEmpty,
            // The dry-spell card teaches the same thing as the recordingType
            // tip, with buttons. Reading the same AppStorage key the card reads
            // rather than mirroring the flag, so the two cannot drift.
            showsNoCallCard: OnboardingPrompts.showsNoCallCard(
                dismissed: UserDefaults.standard.bool(forKey: "onboarding.noCallCardDismissed"),
                isRecording: state.isRecording,
                hasSavedSessions: !state.savedSessions.isEmpty,
                lastStep: Config.onboardingStep)))
        guard let candidate, candidate.anchor == anchor else { return nil }
        return candidate
    }

    var body: some View {
        if let tip {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(tip.title)
                    .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(tip.body)
                    .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button("Понятно") { retire(tip) }
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .accessibilityLabel("Скрыть подсказку: \(tip.title)")
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentTint,
                        in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(Theme.accentSoft, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(tip.title). \(tip.body)")
        }
    }

    private func retire(_ tip: CoachTip) {
        guard let next = CoachTipRetirement.retiring(
            tip, used: true, in: Config.coachTipsRetired) else { return }
        Config.coachTipsRetired = next
        retirements += 1
    }
}

extension View {
    /// Retires a tip because its feature was USED. Using beats reading, so
    /// someone who found the control on their own never sees the tip about it.
    func retiringCoachTip(_ tip: CoachTip, when used: Bool) -> some View {
        onChange(of: used) { isUsed in
            guard let next = CoachTipRetirement.retiring(
                tip, used: isUsed, in: Config.coachTipsRetired) else { return }
            Config.coachTipsRetired = next
        }
    }
}
