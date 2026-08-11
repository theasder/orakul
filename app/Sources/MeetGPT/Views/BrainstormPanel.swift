import SwiftUI

/// The Blind Spot panel has several independent pieces of state: saved cards
/// can outlive the live watcher, while Settings, a per-call snooze, quota, and
/// provider failures determine whether another scan can run. Keeping that
/// precedence in one value prevents an inactive watcher from looking live.
struct BlindSpotPanelPresentation: Equatable {
    enum StatusKind: Equatable {
        case informational
        case providerFailure
        case quota
    }

    let isVisible: Bool
    let heading: String
    let statusMessage: String?
    let statusKind: StatusKind?
    let showsCards: Bool
    let canPause: Bool
    let canResume: Bool

    static func resolve(
        enabled: Bool,
        snoozed: Bool,
        isRecording: Bool,
        goalSet: Bool,
        hasSuggestions: Bool,
        secondsRemaining: Int,
        failureMessage: String?,
        quotaMessage: String?
    ) -> Self {
        let quota = quotaMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = failureMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuota = !(quota ?? "").isEmpty
        let isPaused = enabled && (snoozed || hasQuota)

        let heading: String
        if !enabled {
            heading = "Suggestions off"
        } else if isPaused {
            heading = "Suggestions paused"
        } else {
            heading = isRecording ? "Live suggestions" : "Blind spots"
        }

        let status: (String?, StatusKind?)
        if hasQuota {
            // A server quota rejection is latched for the call. Never leave the
            // stale provider-failure copy promising an automatic retry.
            status = (quota, .quota)
        } else if !enabled {
            status = ("Turn on Blind Spot in Settings to resume.", .informational)
        } else if snoozed {
            status = ("Paused for this call.", .informational)
        } else if let failure, !failure.isEmpty {
            status = (failure, .providerFailure)
        } else if !hasSuggestions, secondsRemaining <= 0 {
            status = ("Out of co-pilot hours this month", .informational)
        } else if !hasSuggestions, isRecording, goalSet {
            status = ("Listening for suggestions…", .informational)
        } else {
            status = (nil, nil)
        }

        return Self(
            isVisible: hasSuggestions || (isRecording && goalSet),
            heading: heading,
            statusMessage: status.0,
            statusKind: status.1,
            showsCards: hasSuggestions,
            canPause: enabled && !snoozed && !hasQuota && isRecording,
            canResume: enabled && snoozed && !hasQuota
        )
    }
}

/// Sidebar "Ко-пилот" section: the call goal (the only thing the brainstormer
/// needs) plus the proactive blind-spot suggestions it surfaces during a call.
struct BrainstormSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @State private var researching = false
    @State private var hoveringSuggestions = false

    private var explicitGoalSet: Bool {
        !state.callGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveGoalSet: Bool { !state.effectiveCallGoal.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("Ко-пилот")

            GoalField(text: $state.callGoal)

            // The goal is now WRITTEN INTO the field when it is empty, inferred
            // from the meeting name, the attached context and connected-app
            // material, and the opening transcript. This line just marks it as
            // a proposal so it never looks like something the user typed.
            if state.goalWasProposed {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("Предложено по этому звонку — измените или")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                    Button("очистить") { state.clearProposedGoal() }
                        .buttonStyle(QuietButtonStyle(prominent: true))
                        .help("Clear the proposed goal and let Cruxwing suggest another")
                    Spacer(minLength: 0)
                }
            }

            // Wraps instead of squeezing: "Fundraising / investor" and a long
            // role are both longer than half a sidebar, and a truncated chip
            // hides exactly the setting it is there to report.
            ChipFlow(spacing: Space.xs, lineSpacing: Space.xs) {
                RecordingContextChip()
                ThemeChip()
                RoleChip()
                SocraticChip()
                FullContextChip()
            }

            // One tip, under the control it is about, and only for a user who
            // has not used that control yet. It retires the moment the type is
            // set by hand — using beats reading.
            CoachTipView(anchor: "recording.context.menu")
                .retiringCoachTip(.recordingType,
                                  when: !state.recordingContextSelection.isAutomatic)

            // Capture startup owns the audio routes for a moment; surface the
            // queued live handoff until those routes are ready.
            if let pending = state.pendingEngineChange {
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.amber)
                    Text("Switching this call to \(pending.advantageTitle)")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            // What the calendar loaded. A quiet line, because it is a fact about
            // the setup rather than a finding about the call — it used to be
            // injected into the blind-spot list as a fake advice card, where it
            // outranked real blind spots and made no sense on a finished meeting.
            if !state.calendarSyncNote.isEmpty {
                HStack(spacing: Space.xs) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.inkTertiary)
                    Text(state.calendarSyncNote)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            // Background facilitation watch: a prominent steering note the moment
            // the meeting drifts off-goal, loops, or leaves a decision hanging.
            if !state.facilitationNote.isEmpty {
                FacilitationNoteCard(note: state.facilitationNote) { state.facilitationNote = "" }
            }

            if effectiveGoalSet, !mcp.researchableServers.isEmpty {
                HStack(spacing: Space.xs) {
                    Button {
                        Task { await research() }
                    } label: {
                        Label(researching ? "Researching…" : "Research",
                              systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .disabled(researching)
                    .help("Search your connected apps for material related to the goal")
                    if researching {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Text("\(mcp.researchableServers.count) apps · \(max(0, TariffAllowance.forTier(state.currentTier).groundedCycles - UsageTracker.groundedCyclesThisMonth)) research left")
                            .font(Typo.caption)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                }
                .padding(.leading, -Space.m) // align the quiet button's text
            }

            // Live suggestions: output-first — no standing switch to think
            // about. Saved cards remain visible while the watcher is off or
            // paused, but its heading/status must describe the watcher that can
            // actually run. The permanent switch remains in Settings.
            let blindSpotPanel = BlindSpotPanelPresentation.resolve(
                enabled: state.blindSpotsEnabled,
                snoozed: state.suggestionsSnoozedThisCall,
                isRecording: state.isRecording,
                goalSet: effectiveGoalSet,
                hasSuggestions: !state.suggestions.isEmpty,
                secondsRemaining: state.copilotSecondsRemaining,
                failureMessage: state.blindSpotFailureMessage,
                quotaMessage: state.copilotQuotaMessage
            )
            if blindSpotPanel.isVisible {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text(blindSpotPanel.heading)
                            .font(Typo.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkTertiary)
                        Spacer(minLength: 0)
                        if blindSpotPanel.canResume {
                            Button("Продолжить") { state.resumeSuggestionsThisCall() }
                                .buttonStyle(QuietButtonStyle(prominent: true))
                        } else if hoveringSuggestions, blindSpotPanel.canPause {
                            Button { state.snoozeSuggestionsForCall() } label: {
                                Image(systemName: "pause.circle")
                            }
                            .buttonStyle(IconButtonStyle(size: 16))
                            .help("Pause suggestions for this call — they return automatically next call")
                        }
                    }
                    if let status = blindSpotPanel.statusMessage,
                       let kind = blindSpotPanel.statusKind {
                        Label(status, systemImage: statusSymbol(for: kind))
                            .font(Typo.caption)
                            .foregroundStyle(kind == .informational ? Theme.inkTertiary : Theme.amber)
                            .accessibilityIdentifier(
                                kind == .quota
                                    ? "copilot.blind-spot-quota-status"
                                    : "copilot.blind-spot-provider-status"
                            )
                    }
                    if blindSpotPanel.showsCards {
                        VStack(spacing: Space.xs) {
                            ForEach(state.suggestions) { s in
                                SuggestionCard(suggestion: s,
                                               onAsk: { state.askSuggestion(s) },
                                               onDismiss: { state.dismissSuggestion(id: s.id) })
                            }
                        }
                    }
                }
                .onHover { hoveringSuggestions = $0 }
            } else if !effectiveGoalSet {
                Text("Set a goal and the co-pilot will surface questions and risks while you record.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }

            // Background rhetoric watch: one short, dismissable note when the
            // watchdog flags a contradiction or unsupported claim.
            if !state.rhetoricNote.isEmpty {
                RhetoricNoteCard(note: state.rhetoricNote) { state.rhetoricNote = "" }
            }

            // Background fact-check: quiet "N to review" affordance that opens
            // the full sheet — only when the live checker is on and found claims.
            if Config.factCheckDuringCallsEnabled, !state.factClaims.isEmpty, !state.showFactCheck {
                Button { state.showFactCheck = true } label: {
                    Label("\(state.factClaims.count) fact\(state.factClaims.count == 1 ? "" : "s") to review",
                          systemImage: "checkmark.seal")
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .help("The background fact-check flagged claims worth a look — open the review")
            }
        }
    }

    private func statusSymbol(for kind: BlindSpotPanelPresentation.StatusKind) -> String {
        switch kind {
        case .informational: "pause.circle"
        case .providerFailure: "arrow.trianglehead.2.clockwise.rotate.90"
        case .quota: "exclamationmark.circle"
        }
    }

    /// Fan out to every connected app's search tool with the goal as the query;
    /// findings land as removable "Research · <App>" context chips, feeding
    /// prompt-button answers and fact-checking through shared context.
    @MainActor
    private func research() async {
        let goal = state.effectiveCallGoal
        guard !goal.isEmpty, !researching else { return }
        guard UsageTracker.consumeGroundedCycle(for: state.currentTier) else {
            state.lastError = "You've used this month's grounded research runs — upgrade or add more to continue."
            return
        }
        researching = true
        defer { researching = false }

        let snippets = await mcp.groundingSnippets(
            goal: goal, maxSources: CopilotCadence.maxGroundingSources)
        // Re-running research replaces the previous round, not stacks on it.
        state.contextFiles.removeAll { $0.name.hasPrefix("Research · ") }
        for snippet in snippets {
            state.contextFiles.append(ImportedContextFile(
                name: "Research · \(snippet.serverName)", text: snippet.text))
        }
        if snippets.isEmpty {
            state.lastError = "Research found nothing for this goal in your connected apps."
        } else {
            state.lastError = nil
        }
    }
}

/// The capture is not necessarily a call. The automatic guess is visible but
/// never authoritative: one compact menu lets the user pin a tutorial, video,
/// lecture, interview, podcast, presentation, meeting, or their own label
/// without interrupting an active recording.
private struct RecordingContextChip: View {
    @EnvironmentObject var state: AppState
    @State private var showingCustomType = false
    @State private var customDraft = ""

    private var awaitingDetection: Bool {
        state.recordingContextSelection.isAutomatic && !state.hasDetectedRecordingContext
    }

    var body: some View {
        let selection = state.recordingContextSelection
        let detected = state.detectedRecordingContext
        Menu {
            Button {
                state.selectRecordingContext(.automatic)
            } label: {
                Label(
                    "Auto-detect · \(detected.label)",
                    systemImage: selection.isAutomatic ? "checkmark" : "wand.and.stars")
            }
            Divider()
            ForEach(RecordingContextKind.allCases) { kind in
                Button {
                    guard let mode = RecordingContextSelection.Mode(rawValue: kind.rawValue)
                    else { return }
                    state.selectRecordingContext(mode)
                } label: {
                    Label(
                        kind.label,
                        systemImage: selection.mode.rawValue == kind.rawValue
                            ? "checkmark" : kind.symbol)
                }
            }
            Divider()
            Button {
                customDraft = selection.mode == .custom
                    ? (selection.customLabel ?? "") : ""
                showingCustomType = true
            } label: {
                Label("Другое…", systemImage: selection.mode == .custom ? "checkmark" : "tag")
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: awaitingDetection
                      ? "wand.and.stars"
                      : selection.resolvedSymbol(detected: detected))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                // Until the detector has looked, the resolved label is only its
                // fallback. Say "Определять автоматически" rather than name a type the app
                // has no evidence for — this chip is read in the moment someone
                // decides whether to override it.
                Text(awaitingDetection
                     ? "Определять автоматически"
                     : selection.isAutomatic
                     ? "Auto · \(state.effectiveRecordingContextLabel)"
                     : state.effectiveRecordingContextLabel)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("recording.context.menu")
        .accessibilityLabel("Тип записи")
        .accessibilityValue(state.effectiveRecordingContextLabel)
        .help("What this recording represents — override auto-detect without stopping capture")
        .alert("Тип записи", isPresented: $showingCustomType) {
            TextField("For example: architecture review video", text: $customDraft)
                .accessibilityIdentifier("recording.context.custom-field")
            Button("Тип использования") {
                state.selectRecordingContext(.custom, customLabel: customDraft)
            }
            .disabled(RecordingContextSelection.sanitizeCustomLabel(customDraft) == nil)
            .accessibilityIdentifier("recording.context.custom-save")
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Эта пометка влияет на итоги и ответы только для этой записи.")
        }
    }
}

/// Shows the skill pack applied to this call (auto-detected from the goal +
/// transcript, or pinned by the user). Tapping opens a picker to override or
/// return to auto-detect. Every AI action in the call is primed with this
/// theme's expertise on top of the base instructions and the button's skill.
/// The price of sending everything, shown BEFORE the send.
///
/// The acceptance criterion was that cost is visible in credits before the
/// request, not discovered after. So this is a chip in the composer row rather
/// than a line in a receipt, and it names both the price and what gets sent —
/// the decision is "is this worth N credits", and neither number alone answers
/// it.
///
/// Hidden entirely when the current model cannot do it. An always-visible
/// control that is usually disabled teaches people to stop looking at the row.
struct FullContextChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.fullContextAvailable {
            Button { state.fullContextRequested.toggle() } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: state.fullContextRequested
                          ? "doc.text.fill" : "doc.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.fullContextRequested
                                         ? Theme.accent : Theme.inkTertiary)
                    Text(label)
                        .font(Typo.caption)
                        .foregroundStyle(state.fullContextRequested
                                         ? Theme.inkSecondary : Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .background(state.fullContextRequested
                            ? Theme.accent.opacity(0.10) : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(
                    state.fullContextRequested
                        ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityIdentifier("composer.fullContext")
        }
    }

    /// Names the price when armed. When not armed it says what is being LEFT
    /// OUT, because that is the fact that makes turning it on a considered
    /// choice rather than a guess.
    private var label: String {
        let quote = state.fullContextQuote
        if state.fullContextRequested {
            return "\(quote.credits) credits · full context"
        }
        return state.fullContextQuote.truncated ? "Transcript is being clipped" : "Full context"
    }

    private var helpText: String {
        let quote = state.fullContextQuote
        if state.fullContextRequested {
            return quote.summary + ". Applies to the next send only."
        }
        return "Send the whole transcript and everything attached on the next request. "
            + "Costs more credits; applies once."
    }
}

/// Shown only while Socratic mode is on.
///
/// The acceptance criterion was that the mode is obviously modal and never a
/// silent behaviour change. A toggle inside a menu does not achieve that — you
/// cannot see it without opening the menu, which nobody does before every ask.
/// This sits in the chip row and reports what the NEXT ask will do, so the
/// posture is visible before sending rather than discovered in the reply.
///
/// It disappears entirely when the mode is off, because a permanent chip saying
/// "not socratic" is noise that teaches people to stop reading the row.
struct SocraticChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.socraticModeEnabled {
            HStack(spacing: Space.xs) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(label)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(Theme.accent.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
            .help(helpText)
            .accessibilityIdentifier("composer.socraticChip")
        }
    }

    /// Names what happens next, not what the setting is called. "Socratic" alone
    /// does not tell someone whether THIS ask gets an answer.
    private var label: String {
        if state.socraticBrokenOut { return "Socratic · answering plainly" }
        guard state.socraticWillWithhold else { return "Socratic · bound spent" }
        let remaining = state.socraticRemainingExchanges
        return remaining == 1 ? "Socratic · 1 question left"
                              : "Socratic · \(remaining) questions left"
    }

    private var helpText: String {
        state.status == .recording
            ? "Answers with questions. Limited to \(SocraticMode.maxExchangesRecording) "
              + "during a live call — press ⌘⇧A for a direct answer."
            : "Answers with questions. Press ⌘⇧A for a direct answer."
    }
}

private struct ThemeChip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let active = state.activeCallTheme
        let isAuto = state.callThemeOverride == nil

        Menu {
            // Style sits beside the theme rather than in Settings: it is a
            // per-session choice made while composing, like the theme is.
            Picker("Answer style", selection: $state.answerStyle) {
                ForEach(AnswerStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("composer.answerStyle")
            Divider()
            // A mode, not a style, so it is a separate switch rather than
            // another row in the style picker — see SocraticMode. It changes
            // whether you get an answer, which no style does.
            Toggle(isOn: $state.socraticModeEnabled) {
                Label("Сократический режим", systemImage: "questionmark.bubble")
            }
            .accessibilityIdentifier("composer.socraticMode")
            if state.socraticModeEnabled {
                Button("Ответить прямо  ⌘⇧A") { state.answerPlainlyNext() }
                    .disabled(state.socraticBrokenOut)
                    .accessibilityIdentifier("composer.socraticBreakout")
            }
            Divider()
            Picker("Call theme", selection: $state.callThemeOverride) {
                Label("Определять автоматически", systemImage: "wand.and.stars")
                    .tag(CallTheme?.none)
                Divider()
                ForEach(CallTheme.allCases) { theme in
                    Label(theme.label, systemImage: theme.symbol)
                        .tag(CallTheme?.some(theme))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: active.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(isAuto ? "Auto · \(active.label)" : active.label)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    // No truncation: at its narrowest the label wraps to a
                    // second line inside the capsule.
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Skill pack applied to this call's AI actions — tap to change or auto-detect")
    }
}

/// The user's job position — selects the role skill layer (role-specific method
/// hints per prompt button, from the bundled RoleSkillMatrix). Hidden when the
/// matrix resource isn't bundled.
private struct RoleChip: View {
    @EnvironmentObject var state: AppState

    /// Short display form of the free-text role for the chip/menu.
    private var customLabel: String? {
        let text = Config.userCustomRole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 28 ? String(text.prefix(27)) + "…" : text
    }

    var body: some View {
        if !RoleSkillMatrix.positions.isEmpty {
            let active = RoleSkillMatrix.position(id: state.userRoleID)
            let isCustom = state.userRoleID == RoleSkillMatrix.customRoleID
            Menu {
                Picker("Ваша роль", selection: $state.userRoleID) {
                    Label("Без роли", systemImage: "person.crop.circle.dashed")
                        .tag(String?.none)
                    Divider()
                    ForEach(RoleSkillMatrix.positions) { position in
                        Label(position.label, systemImage: position.symbol)
                            .tag(String?.some(position.id))
                    }
                    // The user's own written role (Settings → General →
                    // Profile) — only offered once it exists.
                    if let customLabel {
                        Divider()
                        Label(customLabel, systemImage: "person.crop.circle.badge.plus")
                            .tag(String?.some(RoleSkillMatrix.customRoleID))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: isCustom ? "person.crop.circle.badge.plus"
                                               : (active?.symbol ?? "person.crop.circle.dashed"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active == nil && !isCustom ? Theme.inkTertiary : Theme.accent)
                    Text(isCustom ? (customLabel ?? "Role") : (active?.label ?? "Role"))
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Your job position — tailors every AI action's method to your role")
        }
    }
}

private struct GoalField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "target")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            // Wraps instead of truncating. A single-line field cut off any
            // proposed goal longer than the column — and a proposed goal is a
            // whole sentence by construction, so the interesting half was always
            // the invisible half. Grows to four lines, then scrolls internally.
            // The prompt teaches the field's job. "Goal of this call…" named the
            // input; this one says what a good answer looks like, which is the
            // difference between an empty field and a usable one on a first run.
            TextField("", text: $text,
                      prompt: Text("Что должно быть верно к концу звонка?"),
                      axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(Typo.sidebarBody)
                .foregroundStyle(Theme.ink)
                .focused($focused)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.4) : Theme.hairline, lineWidth: 1))
        .animation(Motion.quick, value: focused)
    }
}

/// The background rhetoric watch's single note — one amber line, dismissable.
/// Deliberately compact: it's an ambient nudge, not a card that competes with
/// the co-pilot suggestions.
private struct RhetoricNoteCard: View {
    let note: String
    let onDismiss: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.amber)
            Text(note)
                .font(Typo.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.xs)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.35)
            .help("Скрыть")
        }
        .padding(Space.s)
        .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("Rhetoric watch: \(note)")
    }
}

/// The background facilitation watch's steering note — a prominent, cyan cue
/// that the meeting is going off track, dismissable. Slightly heavier than the
/// rhetoric note because it's meant to catch the eye mid-call.
private struct FacilitationNoteCard: View {
    let note: String
    let onDismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.speakerThem)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ведение звонка")
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.speakerThem)
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.xs)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .opacity(hovering ? 1 : 0.35)
            .help("Скрыть")
        }
        .padding(Space.s)
        .background(Theme.speakerThem.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.speakerThem.opacity(0.35), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("Facilitation: \(note)")
    }
}

/// Internal, not private, so `SuggestionCardRenderTests` can rasterise it with
/// ImageRenderer and inspect the actual pixels. A card's whole job is how it
/// reads, and that is the one property a behavioural test cannot assert.
struct SuggestionCard: View {
    let suggestion: Suggestion
    let onAsk: () -> Void
    let onDismiss: () -> Void
    /// Withhold the transcript quote. Passed in rather than read from AppState so
    /// the card stays pure and the render tests can construct it directly.
    var hideEvidence: Bool = false
    @State private var hovering = false
    @State private var copied = false

    private var tint: Color {
        switch suggestion.kind {
        case .question:    return Theme.accent
        case .risk:        return Theme.recordRed
        case .missingInfo: return Theme.speakerThem
        case .advice:      return Theme.speakerYou
        // Amber, the theme's "transitional" hue: a hunch is explicitly unsettled,
        // and colouring it like a confirmed risk would overstate it.
        case .hypothesis:  return Theme.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // Top-aligned, not centred. The default centre alignment floated the
            // kind icon and the dismiss button to the MIDDLE of a wrapped title,
            // which was rare while titles were 13pt and became common at 14pt —
            // a two-line title left both hanging halfway down the card.
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: suggestion.kind.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    // Nudge onto the title's first line: the glyph is smaller than
                    // the text, so top-aligning the frames leaves it riding high.
                    .padding(.top, 3)
                Text(suggestion.title)
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.xs)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 18))
                .opacity(hovering ? 1 : 0.35)
                .help("Скрыть")
            }
            // The phrase this is about, shown BEFORE the comment on it. The
            // model already supplies it and it is verified against the
            // transcript; it was simply never rendered, so the comment read as
            // if it referred to nothing.
            // Quotes are hidden while recognition is struggling. A mangled quote
            // is worse than none: it makes a correct finding look wrong and
            // teaches the user to distrust the whole panel. The finding itself
            // still shows — only its evidence is withheld.
            if let evidence = suggestion.evidence,
               !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !hideEvidence {
                HStack(alignment: .top, spacing: Space.xs) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(tint.opacity(0.45))
                        .frame(width: 2)
                    Text("“\(evidence)”")
                        .font(Typo.sidebarBody.italic())
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Quoted from the call: \(evidence)")
            }
            if !suggestion.detail.isEmpty {
                Text(suggestion.detail)
                    .font(Typo.sidebarBody)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A hunch is shaped differently from an observation. The other kinds
            // describe the call back to the user; this one makes a claim and hands
            // over the sentence that settles it — so the test is the emphasised
            // line, not the claim. Reading the claim alone would leave the user
            // holding an assertion with nothing to do about it.
            if suggestion.isTestableHypothesis {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let claim = suggestion.claim {
                        Text(claim)
                            .font(Typo.sidebarBody)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let cheapTest = suggestion.cheapTest {
                        HStack(alignment: .top, spacing: Space.xs) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.top, 2)
                            Text(cheapTest)
                                .font(Typo.sidebarBody.weight(.medium))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityLabel("Say this to test it: \(cheapTest)")
                    }
                    if let cost = suggestion.costOfMissing, !cost.isEmpty {
                        Text("If wrong: \(cost)")
                            .font(Typo.caption)  // deliberately smaller: consequence, not action
                            .foregroundStyle(Theme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            }
            HStack {
                Spacer()
                // The primary action on a hunch is to say the test out loud, not
                // to ask the assistant about it — so copying it is what the button
                // does, and "Спросить" stays available for the other kinds.
                if suggestion.isTestableHypothesis, let cheapTest = suggestion.cheapTest {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cheapTest, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy the test",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Copy the sentence that settles this")
                }
                Button { onAsk() } label: {
                    Label("Спросить", systemImage: "arrow.up.circle")
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .help("Send to the assistant")
            }
        }
        .padding(Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 6)
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
