import SwiftUI

/// The prompt chip cloud — built-in Quick Prompts plus the user's own custom
/// prompts, then a "Новый" chip to add one. Custom chips carry an edit/delete
/// context menu. Disabled (dimmed) while a response streams.
struct QuickPromptsBar: View {
    @EnvironmentObject var state: AppState
    var onNewPrompt: () -> Void
    var onEditPrompt: (QuickPrompt) -> Void
    @State private var expanded = false

    /// Chips shown before the tail folds into a "+N more" chip. Generous
    /// enough that the built-in set plus a few custom prompts never folds —
    /// only heavy customizers see the toggle. Folding by chip count (not by
    /// clipping pixels) means a row is never cut mid-chip.
    private static let collapsedLimit = 16

    /// Built-ins this configuration can actually run. A prompt that would fail
    /// on click — no tracker connected, an empty credit pool — is not offered,
    /// so the failure is not discovered by pressing it.
    private var offeredBuiltins: [QuickPrompt] {
        QuickPromptResolver.resolve(QuickPrompts.all,
                                    configuration: state.quickPromptConfiguration)
    }

    private var hiddenCount: Int {
        max(0, offeredBuiltins.count + state.customPrompts.count - Self.collapsedLimit)
    }

    var body: some View {
        let folded = !expanded && hiddenCount > 0
        let offered = offeredBuiltins
        let builtins = folded ? Array(offered.prefix(Self.collapsedLimit)) : offered
        let customs = folded
            ? Array(state.customPrompts.prefix(max(0, Self.collapsedLimit - builtins.count)))
            : state.customPrompts

        FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
            ForEach(builtins) { prompt in
                let displayedPrompt = state.promptForCurrentRecording(prompt)
                PromptChip(prompt: displayedPrompt, disabled: state.aiStreaming,
                           workflowSummary: state.workflowSummary(for: prompt),
                           promptReason: state.promptReason(for: prompt)) {
                    state.runPrompt(prompt)
                }
            }
            ForEach(customs) { prompt in
                PromptChip(prompt: prompt, disabled: state.aiStreaming,
                           onEdit: { onEditPrompt(prompt) },
                           onDelete: { state.deleteCustomPrompt(id: prompt.id) },
                           workflowSummary: state.workflowSummary(for: prompt),
                           promptReason: state.promptReason(for: prompt)) {
                    state.runPrompt(prompt)
                }
            }
            NewPromptChip(action: onNewPrompt)
            if hiddenCount > 0 {
                FoldToggleChip(expanded: expanded, hiddenCount: hiddenCount) {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            }
        }
    }
}

struct PromptChip: View {
    let prompt: QuickPrompt
    let disabled: Bool
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var workflowSummary: String? = nil
    /// Item 19: a call-specific "why offered", shown in the tooltip and read to
    /// VoiceOver. Nil for most chips by design.
    var promptReason: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(prompt.icon).font(.system(size: 12))
                Text(prompt.title)
                    .font(Typo.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 240)
            .foregroundStyle(active ? Theme.accentText : Theme.ink)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous).fill(active ? Theme.accentSoft : Theme.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .scaleEffect(active ? 1.03 : 1)
        .onHover { hovering = $0 }
        .help([promptReason, prompt.tooltip, workflowSummary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n"))
        .accessibilityHint(promptReason ?? "")
        .animation(Motion.quick, value: hovering)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let onEdit {
            Button { onEdit() } label: { Label("Изменить", systemImage: "pencil") }
        }
        if let onDelete {
            Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
        }
    }

    private var active: Bool { hovering && !disabled }
}

/// Dashed "add" chip that opens the prompt editor.
private struct NewPromptChip: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Новый").font(Typo.callout.weight(.medium))
            }
            .foregroundStyle(hovering ? Theme.accentText : Theme.inkSecondary)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(hovering ? Theme.accentSoft : .clear))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(hovering ? Theme.accent.opacity(0.5) : Theme.hairlineStrong,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Create a custom prompt")
        .animation(Motion.quick, value: hovering)
    }
}

/// Quiet capsule that folds/unfolds the prompt tail ("+3 more" / "Show less").
private struct FoldToggleChip: View {
    let expanded: Bool
    let hiddenCount: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(expanded ? "Show less" : "+\(hiddenCount) more")
                    .font(Typo.callout.weight(.medium))
            }
            .foregroundStyle(hovering ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(hovering ? Theme.surface : .clear))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Show fewer prompts" : "Show all prompts")
        .accessibilityLabel(expanded ? "Show fewer prompts" : "Show \(hiddenCount) more prompts")
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Prompt editor

/// A draft passed to the editor sheet (Identifiable for `.sheet(item:)`).
struct PromptDraft: Identifiable {
    let id: String
    var icon: String
    var title: String
    var prompt: String
    let isNew: Bool

    static func blank() -> PromptDraft {
        .init(id: "custom-" + UUID().uuidString, icon: "✨", title: "", prompt: "", isNew: true)
    }

    static func from(_ prompt: QuickPrompt) -> PromptDraft {
        .init(id: prompt.id, icon: prompt.icon, title: prompt.title, prompt: prompt.prompt, isNew: false)
    }

    static func fromText(_ text: String) -> PromptDraft {
        .init(id: "custom-" + UUID().uuidString, icon: "✨", title: "", prompt: text, isNew: true)
    }
}

struct PromptEditorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State var draft: PromptDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(draft.isNew ? "New prompt" : "Edit prompt")
                .font(Typo.title)
                .foregroundStyle(Theme.ink)

            HStack(spacing: Space.s) {
                TextField("✨", text: $draft.icon)
                    .textFieldStyle(.plain)
                    .onChange(of: draft.icon) { draft.icon = String($0.prefix(2)) }
                    .multilineTextAlignment(.center)
                    .font(.system(size: 18))
                    .frame(width: 44, height: 36)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                TextField("Title (e.g. Draft follow-up email)", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, Space.m)
                    .frame(height: 36)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                SectionLabel("Промпт")
                TextEditor(text: $draft.prompt)
                    .font(Typo.body)
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(Space.s)
                    .frame(minHeight: 150, maxHeight: 240)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                Text("Sent with the live transcript and your context. Refer to “the transcript”, “past notes”, attendees, etc.")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                Label(state.workflowSummary(for: previewPrompt),
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Button("Сохранить промпт") {
                    state.saveCustomPrompt(.custom(id: draft.id, icon: draft.icon, title: draft.title, prompt: draft.prompt))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .background(Theme.canvas)
    }

    private var previewPrompt: QuickPrompt {
        .custom(id: draft.id + "-preview", icon: draft.icon, title: draft.title, prompt: draft.prompt)
    }
}
