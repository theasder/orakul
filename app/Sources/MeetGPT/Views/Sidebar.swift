import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, Space.l)
                .padding(.top, kContentTopInset)
                .padding(.bottom, Space.l)

            HStack(spacing: Space.s) {
                RecordPill()
                PauseResumeButton()
            }
                .padding(.horizontal, Space.m)

            // Source tags + level meter carry information only during capture;
            // when idle they were static "System / You" clutter.
            if state.isRecording {
                captureMeta
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.m)
                    .padding(.bottom, Space.l)
            } else {
                Spacer().frame(height: Space.l)
            }

            Hairline().padding(.horizontal, Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    NewCallButton()
                    // Both remove themselves once answered, so a settled
                    // workspace looks exactly as it did before.
                    SetupCard()
                    NoCallTodayCard()
                    FocusSection()
                    BrainstormSection()
                    ContextSection()
                    HistorySection()
                    LedgerSection()
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)
            }
            .scrollContentBackground(.hidden)

            Hairline().padding(.horizontal, Space.l)

            SidebarFooter()
                .padding(Space.l)
        }
        // Fill the window's height so the ScrollView above absorbs whatever
        // the fixed pieces don't need. Without this the stack keeps its
        // intrinsic (content) height in a short window and the footer slides
        // off the bottom edge instead of pinning.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var brand: some View {
        HStack(spacing: Space.s) {
            AppMark()
            Text("Cruxwing")
                .font(Typo.title)
                .foregroundStyle(Theme.ink)
            Spacer()
        }
    }

    /// Two captured sources with live dots — "system" and "you".
    private var captureMeta: some View {
        let recording = state.status == .recording
        return CaptureMeta(recording: recording, audioMeter: state.audioMeter)
    }

    private struct CaptureMeta: View {
        let recording: Bool
        @ObservedObject var audioMeter: AudioMeterState

        var body: some View {
            // Only while capturing. Idle, these two tags said nothing: the dots
            // greyed out but "System" and "You" stayed on screen under a Stop
            // button, describing tracks that were not running. During a call they
            // earn their space — they are the confirmation that BOTH sides are
            // being picked up, which is the failure people actually hit.
            HStack(spacing: Space.l) {
                if recording {
                    sourceTag(color: Theme.speakerThem, label: "System", live: true)
                    sourceTag(color: Theme.speakerYou, label: "You", live: true)
                    Spacer()
                    LevelMeter(level: audioMeter.level, active: true)
                }
            }
        }

        private func sourceTag(color: Color, label: String, live: Bool) -> some View {
            HStack(spacing: Space.xs) {
                StatusDot(color: live ? color : Theme.inkTertiary, live: false, size: 6)
                Text(label).font(Typo.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}

// MARK: - Brand mark

struct AppMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.accent, Theme.accentHover],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - New call

/// The way back out of History, at the TOP of the sidebar — above the Co-pilot
/// block, so it is reachable without scrolling back down to History.
///
/// Shown ONLY while a saved call is open (`shouldOfferNewCall`). Opening one
/// from History is otherwise a one-way door: the only other route back to a
/// blank workspace is starting a recording nobody asked for. On the live call
/// that door leads nowhere, and a permanent button there would be a
/// workspace-clearing action parked next to the work it clears.
///
/// The History header keeps its own compact icon for the same action; this is
/// the reachable one, since History sits below Co-pilot and Context.
struct NewCallButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.shouldOfferNewCall {
            Button { state.startNewCall() } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New call")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(QuietButtonStyle(prominent: true))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Leave this saved call — it stays in History, and the workspace goes blank")
            .accessibilityLabel("New call")
            .accessibilityHint("Closes the meeting opened from History and clears the workspace")
            .transition(.opacity)
        }
    }
}

// MARK: - Footer (settings + status)

/// Saved meetings (M3 session persistence): newest first, click to restore
/// the full workspace — transcript, AI output, goal, digest. Rows disable
/// while recording (restore would clobber the live session); hidden when empty.
private struct HistorySection: View {
    @EnvironmentObject var state: AppState
    @State private var confirmClear = false
    @State private var showFirefliesPicker = false
    private static let maxRows = 15

    var body: some View {
        // Also shown when history is EMPTY but Fireflies is connected. The
        // section used to render only with saved calls, which hid the import
        // from exactly the person most likely to want it: someone with no
        // recordings here yet and a year of meetings in Fireflies.
        if !state.savedSessions.isEmpty || state.canImportFromFireflies {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    SectionLabel("History")
                    Spacer()
                    // Opening a call from History used to be a one-way door: the
                    // only way back to a blank workspace was starting a
                    // recording you did not want. The outgoing call is saved
                    // first, so nothing is lost by leaving it.
                    Button { state.startNewCall() } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.canStartNewCall ? Theme.accentText : Theme.inkTertiary)
                    .help("Start a new empty call — the current one is saved to History first")
                    .disabled(!state.canStartNewCall)
                    .accessibilityLabel("New call")
                    // Next to New call: both answer "give me a different
                    // meeting to work on", one from this Mac and one from
                    // Fireflies.
                    if state.canImportFromFireflies {
                        Button {
                            showFirefliesPicker = true
                            state.loadFirefliesMeetings()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentText)
                        .help("Import a past call from Fireflies — its transcript opens here, "
                              + "ready for Blind Spots and questions")
                        .accessibilityLabel("Import from Fireflies")
                        .accessibilityHint("Choose a past Fireflies meeting to open as a saved call")
                    }
                    Button { confirmClear = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkTertiary)
                    .help("Remove all saved meetings")
                    .disabled(state.isRecording)
                    .accessibilityLabel("Clear all history")
                }
                if state.savedSessions.isEmpty {
                    Text("No saved calls yet. Import one from Fireflies to look for blind spots in it.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.savedSessions.prefix(Self.maxRows)) { session in
                    HistoryRow(session: session,
                               disabled: state.isRecording,
                               onOpen: { state.restoreSession(session) },
                               onDelete: { state.deleteSession(id: session.id) })
                }
            }
            .sheet(isPresented: $showFirefliesPicker) {
                FirefliesImportPicker(isPresented: $showFirefliesPicker)
                    .environmentObject(state)
            }
            .confirmationDialog("Remove all history?", isPresented: $confirmClear) {
                Button("Remove all \(state.savedSessions.count) meeting\(state.savedSessions.count == 1 ? "" : "s")",
                       role: .destructive) { state.clearAllHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every saved meeting on this Mac. It can't be undone.")
            }
        }
    }
}

private struct HistoryRow: View {
    let session: SavedSession
    let disabled: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let when = formatter.localizedString(for: session.startedAt, relativeTo: Date())
        return "\(when) · \(session.entries.count) segment\(session.entries.count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(Typo.callout)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: Space.xs)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.35)
            .help("Delete this saved meeting")
            .accessibilityLabel("Delete \(session.displayTitle)")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(hovering ? Theme.surface : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { onOpen() } }
        .onHover { hovering = $0 }
        .opacity(disabled ? 0.5 : 1)
        .help(disabled ? "Stop recording to open a saved meeting" : "Open this meeting")
        .animation(Motion.quick, value: hovering)
    }
}

/// Recent Decision Ledger entries (M3e — until now the flagship 📌 button
/// wrote to a ledger the app could never show). Read-only list; auto-loads
/// quietly when a backend is configured, refresh button is explicit.
private struct LedgerSection: View {
    @EnvironmentObject var state: AppState

    private static let datePrefix = 10   // "YYYY-MM-DD"

    var body: some View {
        if state.ledgerConfigured {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    SectionLabel("Decision Ledger")
                    Spacer()
                    if state.ledgerLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Button {
                            Task { await state.refreshLedger() }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle(size: 18))
                        .help("Refresh logged decisions")
                    }
                }
                if state.ledgerDecisions.isEmpty {
                    Text("Decisions you log with 📌 appear here.")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                } else {
                    ForEach(state.ledgerDecisions.prefix(10)) { decision in
                        HStack(alignment: .top, spacing: Space.s) {
                            Circle()
                                .fill(decision.status == "decided" ? Theme.accent : Theme.inkTertiary)
                                .frame(width: 7, height: 7)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(decision.title)
                                    .font(Typo.callout)
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                Text("\(String((decision.decidedAt ?? decision.createdAt).prefix(Self.datePrefix))) · \(decision.status)")
                                    .font(Typo.caption)
                                    .foregroundStyle(Theme.inkTertiary)
                            }
                        }
                        .help(decision.statement ?? decision.title)
                    }
                }
            }
            .task { await state.refreshLedger(quiet: true) }
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var state: AppState
    @State private var showSignIn = false
    private let accountAvailable: Bool?

    /// `nil` follows the product configuration. Tests can pass an explicit
    /// value so account-state coverage does not depend on the local `.env`.
    init(accountAvailable: Bool? = nil) {
        self.accountAvailable = accountAvailable
    }

    var body: some View {
        HStack(spacing: Space.s) {
            // Idle needs no chip ("Ready" was redundant with the pill), and
            // .recording needs none either — the red record pill above already
            // says it (operator request: drop the bottom-left Recording label).
            if state.status != .idle, state.status != .recording { statusChip }
            Spacer()
            accountButton
            settingsButton
        }
        .sheet(isPresented: $showSignIn) {
            SignInSheet().environmentObject(state)
        }
    }

    /// Account entry point: signed-out shows a sign-in action, signed-in a menu
    /// with the account email, plan, and sign-out. Hidden entirely in builds
    /// without a backend (nothing to sign in to).
    @ViewBuilder
    private var accountButton: some View {
        if accountAvailable ?? state.wheesprAvailable {
            if state.wheesprConnected {
                Menu {
                    Text(state.wheesprEmail ?? "Signed in").font(Typo.caption)
                    Text("Plan: \(state.currentTier.label)").font(Typo.caption)
                    Divider()
                    Button("Sign out") { state.signOutWheespr() }
                } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Account: \(state.wheesprEmail ?? "signed in")")
                .help(state.wheesprEmail ?? "Account")
            } else {
                Button {
                    showSignIn = true
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Sign in")
                .help("Sign in to your account")
            }
        }
    }

    // Open the SwiftUI `Settings` scene. `SettingsLink` is the only reliable way
    // on macOS 14+; the old `NSApp.sendAction(showSettingsWindow:)` selector
    // silently no-ops there (that was the "clicking the gear does nothing" bug).
    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Settings")
            .help("Settings (⌘,)")
        }
    }

    private var statusChip: some View {
        HStack(spacing: Space.xs) {
            StatusDot(color: statusColor, live: state.status == .recording, size: 7)
            Text(statusLabel)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var statusColor: Color {
        switch state.status {
        case .idle: return Theme.inkTertiary
        case .starting, .stopping: return Theme.amber
        case .recording: return Theme.recordRed
        // Amber, like the other in-between states: paused is neither live nor
        // finished, and showing it red would read as still capturing.
        case .paused: return Theme.amber
        case .error: return Theme.danger
        }
    }

    private var statusLabel: String {
        switch state.status {
        case .idle: return "Ready"
        case .starting: return "Starting…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Stopping…"
        case .error: return "Needs attention"
        }
    }
}
