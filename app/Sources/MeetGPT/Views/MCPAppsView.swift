import MCP
import SwiftUI

// MARK: - Settings section

/// Settings → "Connected apps": one keyless OAuth flow for every work app with
/// a hosted MCP server. No API keys, no .env entries — Connect opens the
/// browser once, the token lands in the Keychain.
struct MCPAppsSection: View {
    @EnvironmentObject var mcp: MCPConnectionManager
    @State private var showAddCustom = false
    @State private var search = ""

    /// Matched by name OR alias, so someone hunting for "Jira" finds it behind
    /// Atlassian and "tickets" surfaces every tracker.
    private var visibleServers: [MCPServerDescriptor] {
        mcp.servers.filter { $0.matches(search: search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                TextField("", text: $search, prompt: Text("Поиск приложений — например «jira», «crm», «тикеты»"))
                    .textFieldStyle(.plain)
                    .font(Typo.callout)
                    .accessibilityLabel("Поиск по приложениям")
                    .accessibilityIdentifier("settings.connected.search")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                    .accessibilityIdentifier("settings.connected.search.clear")
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, 6)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))

            ForEach(visibleServers) { server in
                MCPServerRow(server: server)
            }
            if visibleServers.isEmpty {
                // A dead end is worse than a suggestion: every MCP server is
                // connectable here whether or not it is in the catalog.
                Text("No app matches “\(search)”. If it hosts an MCP server, add it below.")
                    .font(Typo.callout)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.vertical, Space.s)
            }
            HStack {
                Button {
                    showAddCustom = true
                } label: {
                    Label("Добавить свой сервер…", systemImage: "plus")
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("settings.connected.add-custom")
                Spacer()
            }
        }
        .sheet(isPresented: $showAddCustom) { MCPAddServerSheet() }
    }
}

private struct MCPServerRow: View {
    @EnvironmentObject var mcp: MCPConnectionManager
    @EnvironmentObject var appState: AppState
    let server: MCPServerDescriptor

    private var state: MCPConnectionManager.ConnectionState { mcp.state(of: server.id) }

    private var statusText: String? {
        switch state {
        case .connected(let count):
            let workflows = appState.promptWorkflowCount(using: "mcp:\(server.id)")
            return workflows > 0
                ? "\(count) tools · \(workflows) prompt workflow\(workflows == 1 ? "" : "s") ready"
                : "\(count) tools · no relevant prompt workflows"
        case .connecting:           return nil
        case .disconnecting:        return "Finishing disconnect…"
        case .failed(let message):  return message
        case .disconnected:         return mcp.isAuthorized(server.id) ? "authorized" : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Label(server.name, systemImage: mcp.isConnected(server.id) ? "checkmark.seal.fill" : server.symbol)
                    .labelStyle(MCPRowLabelStyle())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                switch state {
                case .connecting:
                    ProgressView()
                        .controlSize(.small).scaleEffect(0.7)
                        .accessibilityLabel("Connecting \(server.name)")
                        .accessibilityIdentifier("settings.connected.provider.\(server.id).progress")
                    // Reconnect already has a persisted grant. The only
                    // race-safe stop available today is a real disconnect,
                    // because OAuth may rotate/save its token after this click.
                    // Name that destructive outcome honestly; a first-time
                    // attempt, which has no grant to lose, remains Cancel.
                    let stopTitle = mcp.isAuthorized(server.id) ? "Отключить" : "Отмена"
                    Button(stopTitle) { Task { await mcp.disconnect(server) } }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier(
                            "settings.connected.provider.\(server.id).\(mcp.isAuthorized(server.id) ? "disconnect" : "cancel")")
                case .disconnecting:
                    ProgressView()
                        .controlSize(.small).scaleEffect(0.7)
                        .accessibilityLabel("Disconnecting \(server.name)")
                        .accessibilityIdentifier(
                            "settings.connected.provider.\(server.id).disconnecting")
                case .connected:
                    Button("Отключить") { Task { await mcp.disconnect(server) } }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("settings.connected.provider.\(server.id).disconnect")
                default:
                    Button(mcp.isAuthorized(server.id) ? "Reconnect" : "Подключить") {
                        Task { await mcp.connect(server) }
                    }
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .accessibilityIdentifier(
                        "settings.connected.provider.\(server.id).\(mcp.isAuthorized(server.id) ? "reconnect" : "connect")")
                }
                if server.isCustom {
                    Button {
                        mcp.removeCustomServer(id: server.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .accessibilityLabel("Убрать свой сервер")
                    .accessibilityIdentifier("settings.connected.provider.\(server.id).remove")
                    .help("Убрать свой сервер")
                }
            }
            if let statusText {
                Text(statusText)
                    .font(Typo.caption)
                    .foregroundStyle(isFailure ? Theme.recordRed : Theme.inkTertiary)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.connected.provider.\(server.id).status")
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.connected.provider.\(server.id)")
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// Mirrors SettingsView's row label look (that style is file-private there).
private struct MCPRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            configuration.title
                .font(Typo.callout.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

private struct MCPAddServerSheet: View {
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Добавить MCP-сервер", systemImage: "puzzlepiece.extension")
                .font(Typo.title).foregroundStyle(Theme.ink)
            Text("Paste the Streamable HTTP endpoint of any MCP server (https). Cruxwing connects with standard OAuth — no keys needed if the server supports dynamic client registration.")
                .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
            TextField("", text: $name, prompt: Text("Название — например HubSpot"))
                .textFieldStyle(.plain).padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .accessibilityLabel("Имя своего сервера")
                .accessibilityIdentifier("settings.connected.custom.name")
            TextField("", text: $urlString, prompt: Text("https://mcp.example.com/mcp"))
                .textFieldStyle(.plain).padding(Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .accessibilityLabel("Адрес своего сервера")
                .accessibilityIdentifier("settings.connected.custom.url")
            if invalid {
                Text("Введите имя и корректный адрес https://")
                    .font(Typo.caption).foregroundStyle(Theme.recordRed)
                    .accessibilityIdentifier("settings.connected.custom.error")
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("settings.connected.custom.cancel")
                Button("Добавить") {
                    if mcp.addCustomServer(name: name, urlString: urlString) {
                        dismiss()
                    } else {
                        invalid = true
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.isEmpty || urlString.isEmpty)
                .accessibilityIdentifier("settings.connected.custom.add")
            }
        }
        .padding(Space.xl).frame(width: 460).background(Theme.canvas)
    }
}

// MARK: - Context import

/// "Add source → Connected app…": pick a server and one of its tools, run it,
/// and fold the text result into the meeting context.
struct MCPImportSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var mcp: MCPConnectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverID: String = ""
    @State private var toolName: String = ""
    @State private var query: String = ""
    @State private var running = false
    @State private var errorText: String?

    private var server: MCPServerDescriptor? { mcp.servers.first { $0.id == serverID } }
    /// Context import is a one-click read surface. Write, destructive and
    /// ambiguous tools remain available to explicit confirmation-backed flows,
    /// but never appear in this picker.
    private var tools: [Tool] { mcp.importTools(for: serverID) }
    private var selectedTool: Tool? { tools.first { $0.name == toolName } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Label("Импорт из подключённого приложения", systemImage: "app.connected.to.app.below.fill")
                .font(Typo.title).foregroundStyle(Theme.ink)

            Picker("App", selection: $serverID) {
                Text("Выбрать…").tag("")
                ForEach(mcp.servers) { server in
                    Text(server.name).tag(server.id)
                }
            }
            .pickerStyle(.menu)   // native macOS pop-up, consistent app-wide
            .accessibilityIdentifier("connected-import.app")
            .onChange(of: serverID) { id in
                toolName = ""
                errorText = nil
                guard let server = mcp.servers.first(where: { $0.id == id }),
                      !mcp.isConnected(id) else { return }
                Task { await mcp.connect(server) }
            }

            if let server {
                if mcp.isConnected(server.id) {
                    Picker("Tool", selection: $toolName) {
                        Text("Выбрать…").tag("")
                        ForEach(tools, id: \.name) { tool in
                            Text(tool.name).tag(tool.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("connected-import.tool")
                    if let description = selectedTool?.description, !description.isEmpty {
                        Text(description)
                            .font(Typo.caption).foregroundStyle(Theme.inkTertiary)
                            .lineLimit(3)
                    }
                    TextField("", text: $query, prompt: Text(queryPrompt))
                        .textFieldStyle(.plain).padding(Space.m)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                        .accessibilityLabel("Запрос на импорт")
                        .accessibilityIdentifier("connected-import.query")
                } else if case .connecting = mcp.state(of: server.id) {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(server.name)… (your browser may open)")
                            .font(Typo.callout).foregroundStyle(Theme.inkSecondary)
                    }
                } else if case .failed(let message) = mcp.state(of: server.id) {
                    Text(message).font(Typo.caption).foregroundStyle(Theme.recordRed)
                }
            }

            if let errorText {
                Text(errorText).font(Typo.caption).foregroundStyle(Theme.recordRed).lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("connected-import.cancel")
                Button(running ? "Running…" : "Import") { run() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(running || server == nil || selectedTool == nil)
                    .accessibilityIdentifier("connected-import.run")
            }
        }
        .padding(Space.xl).frame(width: 480).background(Theme.canvas)
    }

    private var queryPrompt: String {
        guard let tool = selectedTool else { return "query" }
        return Self.stringArgumentKey(for: tool) ?? "no text input for this tool"
    }

    private func run() {
        guard let server, let tool = selectedTool else { return }
        running = true
        errorText = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String: Value]? = nil
        if !trimmed.isEmpty, let key = Self.stringArgumentKey(for: tool) {
            arguments = [key: .string(trimmed)]
        }
        Task {
            do {
                let text = try await mcp.callImportToolText(
                    server: server, tool: tool, arguments: arguments)
                guard !text.isEmpty else {
                    errorText = "\(tool.name) returned no text."
                    running = false
                    return
                }
                state.contextFiles.append(ImportedContextFile(
                    name: "\(server.name) · \(tool.name)", text: text))
                running = false
                dismiss()
            } catch {
                errorText = error.localizedDescription
                running = false
            }
        }
    }

    /// The schema property to carry the free-text input: a well-known name
    /// first, else the first string-typed property.
    static func stringArgumentKey(for tool: Tool) -> String? {
        // Shared schema helper (deterministic, type-checked fallback).
        tool.stringArgumentKey(preferring: ["query", "q", "search", "input", "prompt", "url", "id", "keyword"])
    }
}
