import Foundation

/// How Cruxwing reaches the app or service used by a visible workflow step.
enum WorkflowConnectionKind: String, Codable, CaseIterable, Sendable {
    case mcp
    case api
    case ai
    case local

    var displayName: String {
        switch self {
        case .mcp: "MCP"
        case .api: "API"
        case .ai: "AI API"
        case .local: "On device"
        }
    }
}

/// User-facing identity for the app or service handling a workflow step.
struct WorkflowApp: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let kind: WorkflowConnectionKind
}

/// One step in the visible "thinking process" for a prompt run — derived from the
/// pipeline's own stage transitions (grounding → analysis → composing → filing).
/// This is an activity trace, not private chain-of-thought: it identifies the
/// operation, connection, and outcome without exposing model reasoning.
struct WorkflowStep: Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case pending
        case running
        case succeeded
        case skipped
        case failed

        var isTerminal: Bool {
            switch self {
            case .pending, .running: false
            case .succeeded, .skipped, .failed: true
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .pending: "Pending"
            case .running: "In progress"
            case .succeeded: "Completed"
            case .skipped: "Skipped"
            case .failed: "Failed"
            }
        }
    }

    let id: Int
    let label: String
    var status: Status
    var app: WorkflowApp?
    var tool: String?
    var detail: String?

    /// Compatibility with the original step log used by AppState and existing
    /// callers. Terminal outcomes are all done, not just successful outcomes.
    var done: Bool {
        get { status.isTerminal }
        set {
            if newValue {
                if !status.isTerminal { status = .succeeded }
            } else if status.isTerminal {
                status = .running
            }
        }
    }

    /// Legacy initializer: an unfinished stage is already active, rather than
    /// merely queued, because AppState appends it when the stage begins.
    init(id: Int, label: String, done: Bool) {
        self.init(
            id: id,
            label: label,
            status: done ? .succeeded : .running
        )
    }

    init(
        id: Int,
        label: String,
        status: Status = .pending,
        app: WorkflowApp? = nil,
        tool: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.app = app
        self.tool = tool
        self.detail = detail
    }

    /// A concise VoiceOver description. Deliberately excludes `detail`, which
    /// may contain long or sensitive meeting/context content.
    var accessibilitySummary: String {
        var parts = [Self.cleaned(label, fallback: "Workflow step")]

        if let app {
            let appName = Self.cleaned(app.name)
            if !appName.isEmpty {
                parts.append("\(appName), \(app.kind.displayName)")
            }
        }

        if let tool {
            let toolName = Self.cleaned(tool)
            if !toolName.isEmpty { parts.append(toolName) }
        }

        parts.append(status.accessibilityLabel)
        return parts.joined(separator: ", ")
    }

    private static func cleaned(_ value: String, fallback: String = "") -> String {
        let words = value.split(whereSeparator: \Character.isWhitespace)
        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? fallback : cleaned
    }
}
