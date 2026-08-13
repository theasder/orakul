import SwiftUI

/// The clarification card: one or two questions the assistant wants settled
/// before it spends an answer.
///
/// Two rules shape the layout. It must be answerable in one glance and two
/// clicks, because anything slower is worse than being answered wrongly and
/// correcting. And "Всё равно ответить" is always present and never buried — a card
/// that can trap the user into answering a question they do not care about is a
/// card they will learn to resent.
struct ClarificationCard: View {
    let pending: PendingClarification
    let onResolve: ([ClarificationAnswer]) -> Void
    let onSkip: () -> Void

    @State private var answers: [UUID: ClarificationAnswer] = [:]
    @State private var otherFocus: UUID?

    private var anyAnswered: Bool {
        answers.values.contains { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            ForEach(pending.questions) { question in
                questionBlock(question)
            }
            Hairline()
            actions
        }
        .card()
        .onAppear(perform: seedAnswers)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            SectionLabel("Прежде чем отвечу")
            Spacer(minLength: 0)
        }
    }

    // MARK: - One question

    @ViewBuilder
    private func questionBlock(_ question: ClarifyingQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(question.header.uppercased())
                    .font(Typo.label)
                    .tracking(0.7)
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xxs)
                    .background(Theme.accentSoft, in: Capsule())
                if question.multiSelect {
                    Text("любой на выбор")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Text(question.question)
                .font(Typo.bodyStrong)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(question.options) { option in
                    optionRow(question: question, option: option)
                }
                otherRow(question: question)
            }
        }
    }

    private func optionRow(question: ClarifyingQuestion, option: ClarifyingQuestion.Option) -> some View {
        let isSelected = answers[question.id]?.selected.contains(option.id) ?? false
        return Button {
            toggle(question: question, option: option)
        } label: {
            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: selectionSymbol(multiSelect: question.multiSelect, selected: isSelected))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.inkTertiary)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(option.label)
                        .font(Typo.body)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .fill(isSelected ? Theme.accentTint : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Always present. The model's options are a guess at the shape of the
    /// answer; this is the escape hatch for when that guess was wrong.
    private func otherRow(question: ClarifyingQuestion) -> some View {
        HStack(alignment: .center, spacing: Space.s) {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkTertiary)
            TextField("Свой вариант…", text: otherBinding(for: question))
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Theme.ink)
                .onSubmit { submit() }
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.s)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Space.s) {
            Button("Всё равно ответить", action: onSkip)
                .buttonStyle(QuietButtonStyle())
                .help("Пропустить вопросы и ответить на исходный запрос как есть.")
            Spacer(minLength: 0)
            Button(anyAnswered ? "Продолжить" : "Продолжить без ответа", action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    // MARK: - Selection state

    private func seedAnswers() {
        guard answers.isEmpty else { return }
        answers = Dictionary(
            uniqueKeysWithValues: pending.questions.map { ($0.id, ClarificationAnswer(questionID: $0.id)) })
    }

    private func selectionSymbol(multiSelect: Bool, selected: Bool) -> String {
        if multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(question: ClarifyingQuestion, option: ClarifyingQuestion.Option) {
        var answer = answers[question.id] ?? ClarificationAnswer(questionID: question.id)
        if question.multiSelect {
            if answer.selected.contains(option.id) {
                answer.selected.remove(option.id)
            } else {
                answer.selected.insert(option.id)
            }
        } else {
            // Single-select is also single-DEselect: tapping the chosen option
            // again clears it, so a misclick is recoverable without a reset.
            answer.selected = answer.selected.contains(option.id) ? [] : [option.id]
        }
        answers[question.id] = answer
    }

    private func otherBinding(for question: ClarifyingQuestion) -> Binding<String> {
        Binding(
            get: { answers[question.id]?.other ?? "" },
            set: { newValue in
                var answer = answers[question.id] ?? ClarificationAnswer(questionID: question.id)
                answer.other = newValue
                answers[question.id] = answer
            }
        )
    }

    /// Continue with whatever is filled in. Answering nothing is allowed and
    /// behaves exactly like skipping — the run must never be blocked by a
    /// question the user did not want to answer.
    private func submit() {
        onResolve(pending.questions.compactMap { answers[$0.id] }.filter { !$0.isEmpty })
    }
}
