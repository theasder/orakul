import SwiftUI

/// Sidebar "Фокус" section: unique upcoming reminders and active alerts.
/// Recommendations live only in Co-pilot so users never see duplicate cards.
struct FocusSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let items = state.focusItems
        let hidden = state.dismissedMeetings
        if !items.isEmpty || !hidden.isEmpty || state.appliedMeetingContext != nil {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    SectionLabel("Фокус")
                    Spacer()
                    if !items.isEmpty {
                        Text("\(items.count)")
                            .font(Typo.mono)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                // A meeting was just loaded into the call. Tapping a row rewrites
                // the title, the goal and the attendee count as well as adding a
                // context file, so a misclick needs one control that puts all of
                // it back — not four things to undo by hand.
                if let applied = state.appliedMeetingContext {
                    AppliedMeetingBanner(
                        fileName: applied.contextFileName,
                        onUndo: { state.undoMeetingContext() },
                        onKeep: { state.forgetAppliedMeetingContext() })
                }
                VStack(spacing: Space.xs) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            FocusRow(
                                item: item,
                                onAct: { state.act(on: item) },
                                onDismiss: item.meetingID.map { id in
                                    { state.dismissMeeting(id: id) }
                                })
                            // The brief hangs off its meeting rather than
                            // standing alone: the lines only mean anything in
                            // the context of which call they are about.
                            if let meetingID = item.meetingID,
                               let brief = state.meetingBriefs[meetingID] {
                                FocusBriefLines(brief: brief)
                            }
                        }
                    }
                }
                if !hidden.isEmpty {
                    HiddenMeetingsDisclosure(
                        meetings: hidden,
                        onRestore: { state.restoreMeeting(id: $0) },
                        onRestoreAll: { state.restoreAllMeetings() })
                }
            }
        }
    }
}

/// Shown right after a Focus row is tapped. Dismissal is not the same as undo:
/// keeping the context is the common case, so "Оставить" simply retires the banner
/// while "Отменить" reverses every field the tap rewrote and hides the meeting —
/// an accidental tap almost always means "not this one".
private struct AppliedMeetingBanner: View {
    let fileName: String
    let onUndo: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                Text(fileName.replacingOccurrences(of: "Calendar · ", with: ""))
                    .font(Typo.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("Загружено в контекст этого звонка.")
                .font(Typo.caption)
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: Space.s) {
                Button("Отменить", action: onUndo)
                    .buttonStyle(.plain)
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                Button("Оставить", action: onKeep)
                    .buttonStyle(.plain)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}

/// Hidden meetings, foldable. Dismissal must not be a one-way door: without a
/// way back, hiding the wrong row means waiting for the calendar to change.
private struct HiddenMeetingsDisclosure: View {
    let meetings: [UpcomingMeeting]
    let onRestore: (String) -> Void
    let onRestoreAll: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(meetings.count) hidden")
                        .font(Typo.caption)
                }
                .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(meetings) { meeting in
                    HStack(spacing: Space.xs) {
                        Text(meeting.title)
                            .font(Typo.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.xs)
                        Button("Показать") { onRestore(meeting.id) }
                            .buttonStyle(.plain)
                            .font(Typo.caption.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                    }
                    .padding(.leading, Space.m)
                }
                if meetings.count > 1 {
                    Button("Показать все", action: onRestoreAll)
                        .buttonStyle(.plain)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.leading, Space.m)
                }
            }
        }
    }
}

private struct FocusRow: View {
    let item: FocusItem
    let onAct: () -> Void
    /// Hide this meeting from Focus. Nil for rows that are not dismissable.
    var onDismiss: (() -> Void)?
    @State private var hovering = false

    private var tint: Color {
        switch item.kind {
        case .reminder:    return Theme.amber
        case .risk:        return Theme.recordRed
        case .question:    return Theme.accent
        case .missingInfo: return Theme.speakerThem
        case .advice:      return Theme.speakerYou
        case .alert:       return Theme.danger
        }
    }

    private var actionIcon: String? {
        switch item.kind {
        case .alert:    return "xmark"
        // A meeting reminder that knows its event id loads that call's context
        // when picked; one without stays a label and shows no affordance.
        case .reminder: return item.meetingID == nil ? nil : "tray.and.arrow.down"
        default:        return "arrow.up.circle"
        }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Typo.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Space.xs)

            if let actionIcon, item.isActionable {
                Image(systemName: actionIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkTertiary)
                    .opacity(hovering ? 1 : 0.4)
            }
            // Hides the row in Cruxwing only — the event is untouched in Google.
            // Its own button so it cannot be confused with the tap that LOADS
            // the meeting, which is the misclick this whole affordance exists
            // to make survivable.
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(size: 16))
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Скрыть \(item.title)")
                .help("Убрать отсюда — в календаре звонок останется")
            }
        }
        .padding(Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture { if item.isActionable { onAct() } }
        .onHover { hovering = $0 }
        .help(helpText)
        .animation(Motion.quick, value: hovering)
    }

    private var helpText: String {
        switch item.kind {
        case .alert:    return "Скрыть"
        case .reminder:
            return item.meetingID == nil
                ? "Ближайший звонок"
                : "Подставить название, повестку и участников в контекст звонка"
        default:        return "Отправить ассистенту"
        }
    }
}

/// The pre-call brief, rendered under its meeting.
///
/// Deliberately quiet: indented, smaller, no card of its own. It is context for
/// the row above, and a second card competing with the meeting would read as a
/// separate thing to act on.
struct FocusBriefLines: View {
    let brief: MeetingBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(brief.focusLines) { line in
                HStack(alignment: .top, spacing: Space.xs) {
                    // Overdue is the only state worth a colour. Everything else
                    // is context, and colouring context spends attention the
                    // user needs for the one line that is a problem.
                    Circle()
                        .fill(line.isOverdue ? Theme.recordRed : Theme.inkTertiary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.text)
                            .font(Typo.caption)
                            .foregroundStyle(line.isOverdue ? Theme.ink : Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Provenance, always. A line with no source reads as an
                        // assertion by the app rather than a fact from a system
                        // the user connected.
                        Text(line.readFor.map { "\(line.source) — \($0)" } ?? line.source)
                            .font(Typo.monoS)
                            .foregroundStyle(Theme.inkTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.s)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Кратко: " + brief.focusLines.map(\.text).joined(separator: ". "))
    }
}
