import SwiftUI
import MCP

/// The human-confirm step for the one write-back MeetGPT performs: file the
/// Tasks-button action items into a connected tracker (Linear / Jira / Asana)
/// as real issues. Nothing is written until the user picks a tracker and taps
/// File on a specific task. Results (and errors) are surfaced verbatim.
struct TaskWritebackSheet: View {
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.dismiss) private var dismiss
    let tasks: [TasksArtifact.Item]

    enum FileState: Equatable { case idle, filing, done(String), failed(String) }

    @State private var targets: [MCPServerDescriptor] = []
    @State private var selectedServerID: String?
    @State private var states: [Int: FileState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Label("Send tasks to a tracker", systemImage: "arrow.up.forward.app")
                    .font(Typo.title).foregroundStyle(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle())
            }

            if targets.isEmpty {
                Label {
                    Text("Connect Linear, Jira, or Asana in Settings → Connected Apps to file tasks. Each task is created only when you tap File.")
                        .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "link.badge.plus").foregroundStyle(Theme.accent)
                }
            } else {
                Picker("Tracker", selection: $selectedServerID) {
                    ForEach(targets) { server in
                        Text(server.name).tag(String?.some(server.id))
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { index, item in
                        TaskRow(item: item,
                                state: states[index] ?? .idle,
                                canFile: !targets.isEmpty,
                                onFile: { file(index) })
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .padding(Space.xl)
        .frame(width: 480, height: 520)
        .background(Theme.canvas)
        .task {
            targets = mcp.writebackTargets()
            if selectedServerID == nil { selectedServerID = targets.first?.id }
        }
    }

    private func file(_ index: Int) {
        guard let id = selectedServerID,
              let server = targets.first(where: { $0.id == id }) else { return }
        let item = tasks[index]
        states[index] = .filing
        Task {
            do {
                let result = try await mcp.createTrackerItem(item, on: server)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                states[index] = .done(trimmed.isEmpty ? "Created." : String(trimmed.prefix(160)))
            } catch {
                states[index] = .failed(error.localizedDescription)
            }
        }
    }
}

private struct TaskRow: View {
    let item: TasksArtifact.Item
    let state: TaskWritebackSheet.FileState
    let canFile: Bool
    let onFile: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                    .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let owner = item.owner, !owner.contains("[OWNER?]"), !owner.isEmpty {
                    Text("Owner: \(owner)").font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                }
                statusLine
            }
            Spacer()
            trailing
        }
        .padding(Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private var statusLine: some View {
        switch state {
        case .done(let text):
            Text(text).font(Typo.caption).foregroundStyle(Theme.speakerYou)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message).font(Typo.caption).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .filing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.speakerYou)
        default:
            Button("File", action: onFile)
                .buttonStyle(QuietButtonStyle())
                .disabled(!canFile)
                .accessibilityLabel("File task: \(item.task)")
        }
    }
}
