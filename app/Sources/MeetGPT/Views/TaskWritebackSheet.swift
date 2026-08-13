import SwiftUI
import MCP
import OrakulCore

/// The human-confirm step for the one write-back MeetGPT performs: file the
/// Tasks-button action items into a connected tracker (Linear / Jira / Asana)
/// as real issues. Nothing is written until the user picks a tracker and taps
/// File on a specific task. Results (and errors) are surfaced verbatim.
struct TaskWritebackSheet: View {
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.dismiss) private var dismiss
    let tasks: [TasksArtifact.Item]

    enum FileState: Equatable { case idle, filing, done(String), failed(String) }

    /// Куда можно завести задачу. Две разные механики за одним списком:
    /// MCP-серверы вызывают инструмент создания, российские трекеры — свой
    /// REST. Для человека это один вопрос «в какой трекер», поэтому и список
    /// один.
    enum Target: Identifiable, Equatable {
        case mcp(MCPServerDescriptor)
        case russian(RussianTrackers.Service)

        var id: String {
            switch self {
            case .mcp(let server):  return "mcp:\(server.id)"
            case .russian(let s):   return "tracker:\(s.rawValue)"
            }
        }
        var name: String {
            switch self {
            case .mcp(let server):  return server.name
            case .russian(let s):   return s.title
            }
        }
    }

    @State private var targets: [Target] = []
    @State private var selectedServerID: String?
    @State private var states: [Int: FileState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Label("Отправить задачи в трекер", systemImage: "arrow.up.forward.app")
                    .font(Typo.title).foregroundStyle(Theme.ink)
                Spacer()
                Button("Готово") { dismiss() }.buttonStyle(QuietButtonStyle())
            }

            if targets.isEmpty {
                Label {
                    Text("Подключите трекер в «Настройки → Подключённые приложения», чтобы заводить задачи. Российским трекерам нужно указать, куда класть задачу: очередь, доску или колонку. Задача создаётся только когда вы нажмёте «Создать».")
                        .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "link.badge.plus").foregroundStyle(Theme.accent)
                }
            } else {
                Picker("Трекер", selection: $selectedServerID) {
                    ForEach(targets) { target in
                        Text(target.name).tag(String?.some(target.id))
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
            // Российские трекеры идут первыми — как и везде в приложении.
            targets = mcp.trackerStore.writable.map(Target.russian)
                + mcp.writebackTargets().map(Target.mcp)
            if selectedServerID == nil { selectedServerID = targets.first?.id }
        }
    }

    private func file(_ index: Int) {
        guard let id = selectedServerID,
              let target = targets.first(where: { $0.id == id }) else { return }
        let item = tasks[index]
        states[index] = .filing
        Task {
            do {
                switch target {
                case .mcp(let server):
                    let result = try await mcp.createTrackerItem(item, on: server)
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    states[index] = .done(trimmed.isEmpty ? "Задача создана." : String(trimmed.prefix(160)))
                case .russian(let service):
                    guard let client = mcp.trackerStore.client(for: service, http: mcp.trackerHTTP) else {
                        states[index] = .failed("Трекер не настроен")
                        return
                    }
                    let issue = try await client.createIssue(title: item.task, description: item.owner)
                    // Показываем ключ, а не «готово»: по нему задачу можно
                    // найти, и он же доказывает, что она действительно создана.
                    states[index] = .done("Создана \(issue.key)")
                }
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
                    Text("Владелец: \(owner)").font(Typo.caption).foregroundStyle(Theme.inkTertiary)
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
            Button("Создать", action: onFile)
                .buttonStyle(QuietButtonStyle())
                .disabled(!canFile)
                .accessibilityLabel("Завести задачу: \(item.task)")
        }
    }
}
