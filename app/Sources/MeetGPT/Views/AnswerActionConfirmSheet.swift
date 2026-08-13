import SwiftUI

/// Confirms exactly what is about to be written into a connected app.
///
/// This sheet exists because the write is the one action in Cruxwing the user
/// cannot take back from inside Cruxwing. A chip that fires on click is fine
/// when it drafts something local; it is not fine when it puts a record in a
/// shared CRM or files tickets someone else will triage. Everything is shown,
/// everything is editable, and nothing leaves until Create is pressed.
struct AnswerActionConfirmSheet: View {
    @EnvironmentObject var state: AppState
    let pending: AppState.PendingAnswerAction

    @State private var fields: [String: String] = [:]
    @State private var items: [TasksArtifact.Item] = []
    @State private var excluded: Set<String> = []

    private var remainingItems: [TasksArtifact.Item] {
        items.filter { !excluded.contains($0.task) }
    }

    private var canCreate: Bool {
        pending.isPerItem ? !remainingItems.isEmpty : fields.values.contains { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if pending.isPerItem {
                        itemList
                    } else {
                        fieldEditor
                    }
                }
                .padding(.vertical, Space.xs)
            }
            .frame(maxHeight: 320)
            Hairline()
            footer
        }
        .padding(Space.xl)
        .frame(width: 520)
        .onAppear {
            fields = pending.fields
            items = pending.items
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: pending.action.systemImage)
                    .foregroundStyle(Theme.accentText)
                Text(pending.action.title)
                    .font(Typo.title)
                    .foregroundStyle(Theme.ink)
            }
            Text(pending.action.rationale)
                .font(Typo.callout)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Name the destination plainly — the user is authorising a write to
            // a system other people can see.
            Text("Запишет в \(pending.action.serverName) · \(pending.action.toolName)")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    /// Per-item filing: one row per task, each removable. Filing four tickets
    /// when three were wanted is the failure this prevents.
    private var itemList: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("\(remainingItems.count) item(s) will be created")
            ForEach(items, id: \.task) { item in
                let isExcluded = excluded.contains(item.task)
                HStack(alignment: .top, spacing: Space.s) {
                    Button {
                        if isExcluded { excluded.remove(item.task) } else { excluded.insert(item.task) }
                    } label: {
                        Image(systemName: isExcluded ? "square" : "checkmark.square.fill")
                            .foregroundStyle(isExcluded ? Theme.inkTertiary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExcluded ? "Include \(item.task)" : "Exclude \(item.task)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.task)
                            .font(Typo.body)
                            .foregroundStyle(isExcluded ? Theme.inkTertiary : Theme.ink)
                            .strikethrough(isExcluded)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.owner != nil || item.due != nil {
                            Text([item.owner.map { "Owner: \($0)" }, item.due.map { "Due: \($0)" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(Typo.caption)
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Single-payload writes: every schema field, editable.
    private var fieldEditor: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(pending.fieldOrder, id: \.self) { key in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    SectionLabel(key)
                    TextEditor(text: binding(for: key))
                        .font(Typo.body)
                        .frame(minHeight: isLongField(key) ? 120 : 28,
                               maxHeight: isLongField(key) ? 200 : 60)
                        .scrollContentBackground(.hidden)
                        .padding(Space.xs)
                        .background(Theme.surfaceSunken,
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .accessibilityLabel("\(key) to write")
                        .accessibilityIdentifier("connected-write.field.\(key)")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Text(pending.action.isProposed
                 ? "Предложено к этому ответу"
                 : "Подобрано среди действий \(pending.action.serverName)")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Button("Отмена") { state.cancelAnswerAction() }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("connected-write.cancel")
            Button(pending.isPerItem ? "Create \(remainingItems.count)" : "Create") {
                state.applyConfirmEdits(fields: fields, items: remainingItems)
                Task { await state.commitAnswerAction() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canCreate)
            .accessibilityIdentifier("connected-write.confirm")
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fields[key] ?? "" },
            set: { fields[key] = $0 })
    }

    private func isLongField(_ key: String) -> Bool {
        AnswerActionPlanner.bodyKeys.contains(key)
    }
}
