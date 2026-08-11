import SwiftUI

/// Renders the streaming AI response with reading typography, a blinking caret
/// while streaming, and a friendly empty state.
struct ResponseView: View {
    @EnvironmentObject var state: AppState
    @State private var followsLatest = true
    @State private var lastAutomaticScrollAt: TimeInterval?
    @State private var pendingAutomaticScroll: Task<Void, Never>?

    private static let bottomID = "response-bottom"
    private var responsePrompt: String? {
        let value = state.aiResponsePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private var submittedPrompt: String? {
        guard let value = state.submittedPromptPreview?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        // A clarification card is the only content of its turn — it appears
        // before any prompt is echoed or any workflow step exists, so the empty
        // state has to stand down for it too.
        if !state.hasContent && !state.aiStreaming && state.aiHistory.isEmpty
            && state.workflowSteps.isEmpty && responsePrompt == nil
            && submittedPrompt == nil
            && state.pendingClarification == nil && !state.clarifying {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Earlier turns, oldest first. Pressing a second prompt
                        // used to overwrite the first answer in place; the
                        // dialog now keeps the thread readable and selectable.
                        ForEach(state.aiHistory.filter(\.isArchivable)) { exchange in
                            ArchivedExchangeBlock(exchange: exchange)
                        }
                        if let responsePrompt {
                            AssistantPromptBlock(prompt: responsePrompt)
                                .padding(.bottom, Space.m)
                        }
                        // Held-back request: the card owns the turn until the
                        // user resolves or skips it, and no model call has been
                        // spent on the answer yet.
                        if submittedPrompt == nil {
                            clarificationStatus
                        }
                        // User-visible activity trace for the prompt workflow.
                        // It shows operations and connections, not private model reasoning.
                        WorkflowTracePanel(steps: state.workflowSteps, streaming: state.aiStreaming)
                        // Render the streamed text with a light markdown pass.
                        FormattedResponse(text: state.aiResponse)
                        // One-click actions into connected apps, derived from
                        // what this answer contains and what each app advertises
                        // it can do right now — plus saving it as a document.
                        if !state.aiStreaming && state.hasContent {
                            AnswerActionsRow()
                                .padding(.top, Space.l)
                                .transition(.opacity)
                        }
                        // Follow-up chips: distilled from this output and the
                        // material that produced it — the plausible next press.
                        if !state.aiStreaming && !state.followUpPrompts.isEmpty {
                            FollowUpPromptsBlock(prompts: state.followUpPrompts)
                                .padding(.top, Space.l)
                                .transition(.opacity)
                        }
                        // The caret rides the streaming answer; the pre-answer /
                        // grounding state is shown by the live step in WorkflowTracePanel.
                        if state.aiStreaming && !state.aiResponse.isEmpty {
                            TypingCaret()
                                .padding(.top, Space.xs)
                        }
                        // A typed request is accepted before clarification or
                        // grounding starts. Keep the previous live exchange
                        // intact above it, then append the new user turn at the
                        // bottom immediately — never pair an old answer with a
                        // newly submitted question.
                        if let submittedPrompt {
                            AssistantPromptBlock(prompt: submittedPrompt)
                                .padding(.top, Space.l)
                                .padding(.bottom, Space.m)
                            clarificationStatus
                        }
                        // Unlike the conditional caret, this target survives
                        // stream completion and follow-up insertion.
                        Color.clear
                            .frame(height: Space.l)
                            .id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.l)
                    .background(
                        LiveScrollPositionObserver(isNearBottom: $followsLatest)
                            .frame(width: 0, height: 0)
                    )
                }
                .scrollContentBackground(.hidden)
                .onChange(of: state.aiResponse) { _ in
                    guard state.aiStreaming, followsLatest else { return }
                    scheduleAutomaticScroll(proxy)
                }
                .onChange(of: state.aiStreaming) { streaming in
                    if streaming {
                        followsLatest = true
                        lastAutomaticScrollAt = nil
                    }
                    scheduleAutomaticScroll(proxy, throttled: false)
                }
                .onChange(of: state.submittedPromptPreview) { prompt in
                    guard prompt != nil else { return }
                    followsLatest = true
                    lastAutomaticScrollAt = nil
                    scheduleAutomaticScroll(proxy, throttled: false)
                }
                .onChange(of: followsLatest) { isFollowing in
                    if !isFollowing {
                        pendingAutomaticScroll?.cancel()
                        pendingAutomaticScroll = nil
                    }
                }
                .onDisappear {
                    pendingAutomaticScroll?.cancel()
                    pendingAutomaticScroll = nil
                }
                .onChange(of: state.followUpPrompts.count) { _ in
                    scheduleAutomaticScroll(proxy, throttled: false)
                }
                .onChange(of: state.aiResponsePrompt) { _ in
                    scheduleAutomaticScroll(proxy, throttled: false)
                }
                .onChange(of: state.aiHistory.count) { _ in
                    scheduleAutomaticScroll(proxy, throttled: false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest {
                        JumpToLatestButton(accessibilityLabel: "Jump to latest answer") {
                            pendingAutomaticScroll?.cancel()
                            followsLatest = true
                            lastAutomaticScrollAt = nil
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                        .padding(Space.l)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy, throttled: Bool = true) {
        guard followsLatest else { return }
        let delay: TimeInterval
        if throttled {
            guard pendingAutomaticScroll == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            delay = LiveScrollPolicy.delayUntilNextScroll(
                lastScrollAt: lastAutomaticScrollAt, now: now
            )
        } else {
            pendingAutomaticScroll?.cancel()
            delay = 0
        }
        pendingAutomaticScroll = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled, followsLatest else { return }
            // Unanimated. SwiftUI animates scrollTo by default, and during
            // streaming this fires repeatedly WHILE the content height grows —
            // so each animation is interrupted mid-flight by the next one and the
            // view visibly stutters. Following the bottom should look like the
            // text simply staying in view, which means moving instantly.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            lastAutomaticScrollAt = ProcessInfo.processInfo.systemUptime
            pendingAutomaticScroll = nil
        }
    }

    private var empty: some View {
        VStack(spacing: Space.m) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 56, height: 56)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: Space.xs) {
                Text("Спросить ассистента")
                    .font(Typo.headline)
                    .foregroundStyle(Theme.ink)
                Text("Pick a prompt above to turn the live conversation into agendas, action items, answers, and more.")
                    .font(Typo.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.xl)
    }

    @ViewBuilder
    private var clarificationStatus: some View {
        if let pending = state.pendingClarification {
            ClarificationCard(
                pending: pending,
                onResolve: { state.resolveClarification($0) },
                onSkip: { state.skipClarification() })
                .padding(.bottom, Space.m)
                .transition(.opacity)
        } else if state.clarifying {
            HStack(spacing: Space.s) {
                BreathingDots()
                Text("Уточняю вопрос…")
                    .font(Typo.callout)
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.bottom, Space.m)
        }
    }
}

/// Chips that write this answer into a connected app in one click.
///
/// Writing to someone else's system is the one thing here Cruxwing cannot undo,
/// so the row states what will happen before the click (the chip's help text
/// carries the rationale) and shows what came back after it — usually the
/// created item's URL. A silent success would leave the user checking the app to
/// find out whether it worked.
private struct AnswerActionsRow: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if !state.answerActions.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    // When the answer IS a list of things to do, a generic
                    // "Сделать" underneath reads as unrelated furniture. Naming
                    // the connection attaches the button to the list above it.
                    SectionLabel(AnswerChecklist.actionGroupTitle(
                        forAnswer: state.aiResponse,
                        hasTaskAction: state.answerActions.contains { $0.createsTask })
                        ?? "Сделать")
                    FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                        ForEach(state.answerActions) { action in
                            actionChip(action)
                        }
                    }
                }
            }
            // Saving a copy is a different decision from acting in someone
            // else's system, so it gets its own group rather than sitting next
            // to an irreversible CRM write.
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel("Save as")
                FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                    ForEach(state.availableDocumentExports) { export in
                        exportChip(export)
                    }
                }
            }
            if let result = state.answerActionResult {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text(result)
                        .font(Typo.callout)
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { state.dismissAnswerActionResult() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .accessibilityLabel("Скрыть")
                }
                .padding(Space.s)
                .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            }
        }
        .animation(Motion.quick, value: state.answerActionResult)
        // Nothing is written until this sheet is confirmed.
        .sheet(item: Binding(
            get: { state.pendingAnswerAction },
            set: { if $0 == nil { state.cancelAnswerAction() } }
        )) { pending in
            AnswerActionConfirmSheet(pending: pending)
        }
    }

    private func exportChip(_ export: AppState.DocumentExport) -> some View {
        let running = state.runningDocumentExport == export
        let blocked = state.runningDocumentExport != nil && !running
        return Button {
            Task { await state.runDocumentExport(export) }
        } label: {
            HStack(spacing: Space.xs) {
                if running {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: export.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(export.title)
                    .font(Typo.callout)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .foregroundStyle(Theme.inkSecondary)
            .background(Theme.surfaceHover, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(running || blocked)
        .opacity(blocked ? 0.5 : 1)
        .help("Save this answer, its prompt and its blind spots as a \(export.title).")
    }

    private func actionChip(_ action: AnswerActionPlanner.Action) -> some View {
        let running = state.runningAnswerAction == action.id
        let blocked = state.runningAnswerAction != nil && !running
        return Button {
            state.prepareAnswerAction(action)
        } label: {
            HStack(spacing: Space.xs) {
                if running {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: action.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(action.title)
                    .font(Typo.callout)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .foregroundStyle(Theme.ink)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(running || blocked)
        .opacity(blocked ? 0.5 : 1)
        .help(action.rationale)
    }
}

private struct AssistantPromptBlock: View {
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("You asked")
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
            Text(prompt)
                .font(Typo.callout)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(
            cornerRadius: Radius.m,
            style: .continuous
        ))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(prompt)")
    }
}

/// A completed earlier turn: the question, any model-substitution notice, and
/// the answer. Rendered at reduced emphasis so the LIVE turn still reads as the
/// focus, while staying fully selectable — users copy out of old answers.
private struct ArchivedExchangeBlock: View {
    @EnvironmentObject var state: AppState
    let exchange: AIExchange

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            AssistantPromptBlock(prompt: exchange.prompt)
            FormattedResponse(text: exchange.answer)
                .opacity(0.75)
            AnswerFeedbackRow(exchange: exchange)
            // Each answer shows the actions planned from ITS text. Before,
            // only the live answer had a Do this block, so sending another
            // prompt left the previous answer with no way to act on it.
            if !exchange.answerActions.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionLabel("Сделать")
                    FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                        ForEach(exchange.answerActions) { action in
                            Text(action.title)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(Theme.surfaceHover)
                                )
                                .foregroundStyle(Theme.inkSecondary)
                                .help(action.rationale)
                                .accessibilityLabel("\(action.title), from an earlier answer")
                        }
                    }
                }
                .opacity(0.75)
            }
            if !exchange.followUpPrompts.isEmpty {
                FollowUpPromptsBlock(prompts: exchange.followUpPrompts)
            }
            Divider()
                .overlay(Theme.hairline)
        }
        .padding(.bottom, Space.l)
    }
}

/// Reusable for both the live answer and archived turns. An archived chip still
/// starts a normal current request, but stays visually attached to the answer
/// that suggested it.
private struct FollowUpPromptsBlock: View {
    @EnvironmentObject var state: AppState
    let prompts: [QuickPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("Уточнить")
            FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                ForEach(prompts) { prompt in
                    PromptChip(
                        prompt: prompt,
                        disabled: state.aiStreaming,
                        workflowSummary: state.workflowSummary(for: prompt)) {
                        state.runPrompt(prompt)
                    }
                }
            }
        }
    }
}

/// Lightweight markdown-ish rendering: headings (`#`), bullets, and bold via
/// AttributedString, line by line. Keeps prose readable without a heavy dep.
final class MarkdownCache {
    static let capacity = 256
    private(set) var map: [String: AttributedString] = [:]

    func value(for text: String, make: () -> AttributedString) -> AttributedString {
        if let cached = map[text] { return cached }
        // A streamed line produces a new prefix every few tokens. Bound those
        // transient keys so long answers cannot steadily grow render memory.
        if map.count >= Self.capacity { map.removeAll(keepingCapacity: true) }
        let value = make()
        map[text] = value
        return value
    }
}

private struct FormattedResponse: View {
    @Environment(\.readingTextScale) private var readingTextScale
    let text: String
    // Memoizes inline-markdown parsing per line so streaming deltas don't
    // re-parse the whole accumulated response on every update.
    @State private var cache = MarkdownCache()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
    }

    private var lines: [String] { text.components(separatedBy: "\n") }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: Space.xs)
        } else if let heading = headingLevel(trimmed) {
            Text(inline(String(trimmed.drop(while: { $0 == "#" || $0 == " " }))))
                .font(heading == 1 ? Typo.title : Typo.headline)
                .foregroundStyle(Theme.ink)
                .padding(.top, Space.m)
        } else if isQuote(trimmed) {
            HStack(alignment: .top, spacing: Space.s) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 2.5)
                Text(inline(quoteBody(trimmed)))
                    .font(Typo.reading(scale: readingTextScale))
                    .foregroundStyle(Theme.inkSecondary)
                    .italic()
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if isBullet(trimmed) {
            HStack(alignment: .top, spacing: Space.s) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 7)
                Text(inline(bulletBody(trimmed)))
                    .font(Typo.reading(scale: readingTextScale))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inline(trimmed))
                .font(Typo.reading(scale: readingTextScale))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" }).count
        return hashes <= 3 ? hashes : nil
    }

    private func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ")
    }

    private func bulletBody(_ s: String) -> String {
        String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private func isQuote(_ s: String) -> Bool { s.hasPrefix("> ") || s == ">" }

    private func quoteBody(_ s: String) -> String {
        String(s.dropFirst(1)).trimmingCharacters(in: .whitespaces)
    }

    /// Parse inline markdown (bold/italic/code) into an AttributedString,
    /// memoized by line; falls back to plain text if parsing fails.
    private func inline(_ s: String) -> AttributedString {
        cache.value(for: s) {
            if let attr = try? AttributedString(
                markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                return attr
            }
            return AttributedString(s)
        }
    }
}

/// A compact, user-visible activity ledger for a prompt run. The entries name
/// operations and connections without exposing private model reasoning.
struct WorkflowTracePanel: View {
    let steps: [WorkflowStep]
    let streaming: Bool
    /// Collapsed by default (operator request): the answer is the product; the
    /// trace is one click away. Collapsed also skips per-step re-renders while
    /// streaming. Tests inspect the rows, so the initial state is injectable.
    @State private var expanded: Bool

    init(steps: [WorkflowStep], streaming: Bool, initiallyExpanded: Bool = false) {
        self.steps = steps
        self.streaming = streaming
        _expanded = State(initialValue: initiallyExpanded)
    }

    private static let localApp = WorkflowApp(
        id: "cruxwing",
        name: "orakul",
        symbol: "sparkles",
        kind: .local
    )

    var body: some View {
        if streaming || !steps.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                header
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(displaySteps) { step in
                            workflowRow(step)
                        }
                    }
                }
            }
            .padding(Space.m)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1))
            .padding(.bottom, Space.m)
        }
    }

    // Keep the ledger meaningful while the pipeline prepares its planned steps.
    private var displaySteps: [WorkflowStep] {
        if steps.isEmpty && streaming {
            return [
                WorkflowStep(
                    id: 0,
                    label: "Preparing workflow",
                    status: .running,
                    app: Self.localApp
                )
            ]
        }
        return steps
    }

    private var completedCount: Int {
        displaySteps.filter(\.status.isTerminal).count
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text(streaming ? "Workflow" : "How this answer was made")
                    .font(Typo.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(completedCount)/\(displaySteps.count) complete")
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
            .foregroundStyle(Theme.inkSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Collapse workflow" : "Expand workflow")
        .accessibilityValue("\(completedCount) of \(displaySteps.count) steps complete")
    }

    private func workflowRow(_ step: WorkflowStep) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            statusIcon(for: step.status)
                .frame(width: 15, height: 15)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(step.label)
                    .font(Typo.caption.weight(step.status == .running ? .semibold : .regular))
                    .foregroundStyle(labelColor(for: step.status))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Always reserve one metadata line. Replacing “waiting” with a
                // tool/result therefore cannot change row height and tug the
                // assistant scroll position while recording.
                Text(metadata(for: step).isEmpty ? " " : metadata(for: step))
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .frame(height: 13, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            appIdentity(step.app ?? Self.localApp)
                .layoutPriority(1)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(for: step))
    }

    private func appIdentity(_ app: WorkflowApp) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: app.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            Text(app.name)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Text("· \(app.kind.displayName)")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
        }
    }

    private func metadata(for step: WorkflowStep) -> String {
        [step.tool, step.detail]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func statusIcon(for status: WorkflowStep.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Theme.inkTertiary)
        case .running:
            Image(systemName: "circle.inset.filled")
                .foregroundStyle(Theme.accent)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(Theme.inkTertiary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.danger)
        }
    }

    private func labelColor(for status: WorkflowStep.Status) -> Color {
        switch status {
        case .pending, .skipped:
            Theme.inkTertiary
        case .running, .succeeded, .failed:
            Theme.ink
        }
    }

    private func accessibilitySummary(for step: WorkflowStep) -> String {
        guard step.app == nil else { return step.accessibilitySummary }
        var attributedStep = step
        attributedStep.app = Self.localApp
        return attributedStep.accessibilitySummary
    }
}


/// Was this answer any good?
///
/// Two clicks and an optional note, stored with the answer in the session file
/// and sent nowhere. It sits under the answer it judges rather than in a
/// separate panel, because a rating detached from the thing it rates is worth
/// very little later.
private struct AnswerFeedbackRow: View {
    @EnvironmentObject var state: AppState
    let exchange: AIExchange
    @State private var writingNote = false
    @State private var note = ""

    private var current: AnswerFeedback.Rating? { exchange.feedback?.rating }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                ratingButton(.helpful, filled: "hand.thumbsup.fill", hollow: "hand.thumbsup")
                ratingButton(.unhelpful, filled: "hand.thumbsdown.fill", hollow: "hand.thumbsdown")

                if current != nil {
                    Button(exchange.feedback?.note == nil ? "Add a note" : "Edit note") {
                        note = exchange.feedback?.note ?? ""
                        writingNote.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
            }

            if let saved = exchange.feedback?.note, !writingNote {
                Text(saved)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if writingNote {
                HStack(spacing: Space.xs) {
                    TextField("What was wrong, or what helped?", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .lineLimit(1...4)
                    Button("Сохранить") { saveNote() }
                        .font(.system(size: 10))
                }
            }
        }
        .padding(.top, 2)
    }

    private func ratingButton(_ rating: AnswerFeedback.Rating,
                              filled: String, hollow: String) -> some View {
        let selected = current == rating
        return Button {
            // Clicking the active rating clears it: a mis-click must be
            // undoable, or the stored opinion is not the user's.
            let next = selected ? nil : AnswerFeedback(rating: rating,
                                                       note: exchange.feedback?.note)
            state.recordAnswerFeedback(next, forExchange: exchange.id)
        } label: {
            Image(systemName: selected ? filled : hollow)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Theme.accentText : Theme.inkTertiary)
        }
        .buttonStyle(.plain)
        .help(rating == .helpful ? "This answer helped" : "This answer missed")
        .accessibilityLabel(rating == .helpful ? "Mark answer helpful" : "Mark answer unhelpful")
    }

    private func saveNote() {
        let rating = current ?? .helpful
        state.recordAnswerFeedback(AnswerFeedback(rating: rating, note: note),
                                   forExchange: exchange.id)
        writingNote = false
    }
}
