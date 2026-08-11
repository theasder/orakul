import SwiftUI

/// Act 3, in the sidebar. What is left to set up — and nothing that blocks
/// recording.
///
/// Sign-in and connected apps live here rather than in the first-run sheet
/// because both are far easier to say yes to after seeing what the co-pilot
/// produces. Each row disappears when it is satisfied, and the card removes
/// itself when they all are.
struct SetupCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @State private var showSignIn = false
    @AppStorage("onboarding.setupCardDismissed") private var dismissed = false
    @AppStorage("onboarding.signInRowDismissed") private var signInDismissed = false

    private var captureVerified: Bool { state.micGranted && state.screenRecordingGranted }
    private var signedIn: Bool { state.wheesprConnected || !state.wheesprAvailable }
    private var appsConnected: Bool { !mcp.authorizedServerIDs.isEmpty }

    private var showsSignInRow: Bool {
        OnboardingPrompts.showsSignInRow(signedIn: signedIn, dismissed: signInDismissed)
    }

    private var remaining: Int {
        OnboardingPrompts.setupRemaining(captureVerified: captureVerified,
                                         // A row the user put off is not
                                         // outstanding work; counting it leaves
                                         // the card saying "1 left" with nothing
                                         // under it to do.
                                         signedIn: signedIn || signInDismissed,
                                         appsConnected: appsConnected)
    }

    var body: some View {
        if !dismissed, remaining > 0 {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    SectionLabel("Setup · \(remaining) left")
                    Spacer(minLength: 0)
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Hide setup")
                    .accessibilityLabel("Hide setup")
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    // "Verified" would be an overclaim: this row knows the two
                    // permissions are granted, which is exactly the thing the
                    // capture check exists to prove is not the same as working.
                    SetupRow(done: captureVerified, title: "Capture permissions granted")
                    if showsSignInRow {
                        SetupRow(done: false,
                                 title: "Sign in — managed AI & sync",
                                 action: { showSignIn = true },
                                 // Signing in is optional and always available
                                 // from the sidebar footer, so this row can be
                                 // put off without losing the rest of the card.
                                 onDismiss: { signInDismissed = true })
                    }
                    if !appsConnected {
                        SetupRow(done: false, title: "Connect Notion, Linear, Asana…")
                    }
                    Text("Recording works without either.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .padding(.top, Space.xxs)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .sheet(isPresented: $showSignIn) {
                SignInSheet().environmentObject(state)
            }
        }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    var action: (() -> Void)?
    /// Present on steps the user is allowed to skip for good.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(done ? Theme.speakerYou : Theme.inkTertiary)
            if let action {
                Button(title, action: action)
                    .buttonStyle(QuietButtonStyle(prominent: true))
            } else {
                Text(title).font(Typo.caption)
                    .foregroundStyle(done ? Theme.inkTertiary : Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 16))
                .help("Not now — you can sign in later from the sidebar")
                .accessibilityLabel("Dismiss: \(title)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(done ? "done" : "not done")")
    }
}

/// Act 4. The gap between installing and the next real meeting is where installs
/// die, and the recording-type work makes the answer honest: there is something
/// worth recording tonight.
///
/// Shown only while nothing has ever been recorded, never during a recording,
/// and dismissible for good.
struct NoCallTodayCard: View {
    @EnvironmentObject var state: AppState
    @AppStorage("onboarding.noCallCardDismissed") private var dismissed = false

    private var eligible: Bool {
        OnboardingPrompts.showsNoCallCard(
            dismissed: dismissed,
            isRecording: state.isRecording,
            hasSavedSessions: !state.savedSessions.isEmpty,
            lastStep: Config.onboardingStep)
    }

    var body: some View {
        if eligible {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    SectionLabel("No call until Monday?")
                    Spacer(minLength: 0)
                    Button { dismissed = true } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("Hide")
                    .accessibilityLabel("Hide suggestion")
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Point Cruxwing at something you were going to listen to anyway.")
                        .font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SuggestedSource(
                        icon: "graduationcap",
                        title: "A talk or lecture",
                        detail: "Concepts, evidence and open questions — with a learning plan.")
                    SuggestedSource(
                        icon: "mic",
                        title: "A podcast",
                        detail: "Hosts and guests separated, arguments summarised, no invented action items.")
                    Text("Pick the type on the recording chip, or leave it on Auto-detect.")
                        .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }
}

private struct SuggestedSource: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12)).foregroundStyle(Theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
