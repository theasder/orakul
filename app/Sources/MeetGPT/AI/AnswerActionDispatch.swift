import Foundation

/// The exact write that leaves the confirmation boundary.
///
/// Keeping this value separate from the MCP transport gives the confirmation
/// state machine one deterministic seam: tests can stand in for a connected
/// tool without opening OAuth, while production still falls through to the
/// live `MCPConnectionManager` path in `AppState`.
struct AnswerActionDispatchRequest: Equatable {
    enum Payload: Equatable {
        /// A single document, CRM record, calendar event, or draft payload.
        case fields([String: String])
        /// One edited task from a per-item tracker confirmation.
        case trackerItem(TasksArtifact.Item)
    }

    let action: AnswerActionPlanner.Action
    let payload: Payload
}

/// Injectable connected-tool boundary used by deterministic commit tests.
/// Production leaves this unset and dispatches through its live MCP manager.
@MainActor
protocol AnswerActionDispatching: AnyObject {
    func dispatch(_ request: AnswerActionDispatchRequest) async throws -> String
}
