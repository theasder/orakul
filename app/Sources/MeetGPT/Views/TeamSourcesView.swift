import SwiftUI
import AppKit

/// Settings body for the token connectors + the channel watcher.
///
/// Two tiers: a status list of the token connectors (configured in `mac/.env`,
/// read-only at runtime) and an elevated "Channel watcher" card whose enable
/// switch + keyword rules ARE editable live (UserDefaults-backed).
struct TeamSourcesView: View {
    @ObservedObject private var watcher = TeamWatcher.shared
    @State private var watchEnabled = Config.teamWatchEnabled
    @State private var keywords: [String] = Config.teamWatchKeywords
    @State private var draft = ""

    private var hasWatchableChannels: Bool {
        TeamService.slack.isConfigured && !Config.slackChannelIDs.isEmpty
    }

    var body: some View {
        // Reports which surfaces are actually reached — see
        // cruxwing-api/docs/analytics-events.md.
        trackedBody.trackSurface(.teamSources)
    }

    @ViewBuilder private var trackedBody: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            connectors
            watcherCard
        }
    }

    // MARK: - Connectors

    private var connectors: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(TeamService.allCases) { service in
                ConnectorRow(service: service, channelCount: channelCount(service))
            }
        }
    }

    private func channelCount(_ service: TeamService) -> Int? {
        switch service {
        case .slack:      return Config.slackChannelIDs.count
        case .confluence: return nil
        }
    }

    // MARK: - Watcher

    private var watcherCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                StatusDot(color: watcher.isRunning ? Theme.recordRed : Theme.inkTertiary,
                          live: watcher.isRunning, size: 8)
                Text("Channel watcher")
                    .font(Typo.headline)
                    .foregroundStyle(Theme.ink)
                if watcher.isRunning {
                    CountBadge(count: watcher.matchCount)
                }
                Spacer()
                Toggle("", isOn: $watchEnabled)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: watchEnabled) {
                        Config.teamWatchEnabled = $0
                        TeamWatcher.shared.apply()
                    }
            }

            Text(watcherStatusLine)
                .font(Typo.caption)
                .foregroundStyle(watcher.isRunning ? Theme.inkSecondary : Theme.inkTertiary)

            Divider().overlay(Theme.hairline)

            // Keyword rules — the trigger set the watcher scans for.
            VStack(alignment: .leading, spacing: Space.s) {
                Text("KEYWORD RULES")
                    .font(Typo.label)
                    .foregroundStyle(Theme.inkTertiary)
                    .kerning(0.4)

                if keywords.isEmpty {
                    Text("No rules yet — add a keyword to start flagging.")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.inkTertiary)
                } else {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(keywords, id: \.self) { word in
                            KeywordChip(word: word) { remove(word) }
                        }
                    }
                }

                keywordInput
            }

            Divider().overlay(Theme.hairline)

            HStack(spacing: Space.s) {
                AutoAckBadge(on: Config.teamWatchAutoAck)
                Spacer()
                Button {
                    revealAuditLog()
                } label: {
                    Label("Audit log", systemImage: "doc.text.magnifyingglass")
                        .font(Typo.caption.weight(.medium))
                }
                .buttonStyle(QuietButtonStyle())
                .help("Reveal team-watch.log in Finder")
            }
        }
        .padding(Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
            .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }

    private var keywordInput: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            TextField("", text: $draft, prompt: Text("add a rule — e.g. incident, outage, breach"))
                .textFieldStyle(.plain)
                .font(Typo.callout)
                .onSubmit(addDraft)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }

    private var watcherStatusLine: String {
        if !watcher.isRunning {
            if !watchEnabled { return "Off — flip the switch to start watching." }
            return "Add at least one keyword rule to start."
        }
        return hasWatchableChannels
            ? "Scanning your designated channels every 60s."
            : "Running, but no Slack channels are connected to scan."
    }

    // MARK: - Actions

    private func addDraft() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        draft = ""
        guard !word.isEmpty, !keywords.contains(word) else { return }
        keywords.append(word)
        persistKeywords()
    }

    private func remove(_ word: String) {
        keywords.removeAll { $0 == word }
        persistKeywords()
    }

    private func persistKeywords() {
        Config.teamWatchKeywords = keywords
        TeamWatcher.shared.apply()
    }

    private func revealAuditLog() {
        let url = TeamWatcher.auditLogURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - Connector row

private struct ConnectorRow: View {
    let service: TeamService
    let channelCount: Int?
    @State private var hovering = false

    private var configured: Bool { service.isConfigured }

    var body: some View {
        HStack(spacing: Space.m) {
            iconBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(service.label)
                    .font(Typo.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(subline)
                    .font(Typo.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(configured ? "" : service.configHint)
            }
            Spacer(minLength: Space.s)
            StatusPill(configured: configured)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(hovering ? Theme.surfaceHover : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }

    private var iconBadge: some View {
        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .fill(configured ? Theme.accentSoft : Theme.surfaceSunken)
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: service.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(configured ? Theme.accent : Theme.inkTertiary)
            )
    }

    private var subline: String {
        guard configured else { return service.configHint }
        switch service {
        case .slack:
            let n = channelCount ?? 0
            return n == 0 ? "Connected · no channels set" : "Connected · \(n) channel\(n == 1 ? "" : "s") watched"
        case .confluence: return "Connected · page search"
        }
    }
}

// MARK: - Small components

private struct StatusPill: View {
    let configured: Bool
    var body: some View {
        Text(configured ? "Ready" : "Off")
            .font(Typo.label)
            .foregroundStyle(configured ? Theme.speakerYou : Theme.inkTertiary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(configured ? Theme.speakerYou.opacity(0.14) : Theme.surfaceSunken))
    }
}

private struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count) flagged")
            .font(Typo.label)
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.accentSoft))
    }
}

private struct AutoAckBadge: View {
    let on: Bool
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: on ? "arrowshape.turn.up.left.fill" : "arrowshape.turn.up.left")
                .font(.system(size: 10))
            Text(on ? "Auto-ack on" : "Auto-ack off")
                .font(Typo.caption.weight(.medium))
        }
        .foregroundStyle(on ? Theme.accentText : Theme.inkTertiary)
        .help("Auto-acknowledge into the channel on a match.")
    }
}

private struct KeywordChip: View {
    let word: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(word)
                .font(Typo.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Theme.danger : Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.xs)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.surfaceSunken))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
// Keyword chips wrap via the shared `FlowLayout` (DesignSystem/Components.swift).
