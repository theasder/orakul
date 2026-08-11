import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

/// The write-back confirm sheet's view logic. A fresh MCPConnectionManager has
/// no connected trackers (no writeback targets), so the sheet shows the connect
/// hint; the task list renders regardless so the user sees what would be filed.
@MainActor
@Suite("Task write-back sheet")
struct TaskWritebackSheetTests {
    private func item(_ task: String, owner: String? = nil) -> TasksArtifact.Item {
        TasksArtifact.Item(task: task, owner: owner, due: nil, doneCheck: nil,
                           dependency: nil, sourceRef: nil, tracked: nil)
    }

    @Test("renders the tasks and, with no tracker connected, the connect hint")
    func rendersTasksAndHint() throws {
        let view = TaskWritebackSheet(tasks: [item("Ship the beta", owner: "Alex"),
                                              item("Write the RFC")])
            .environmentObject(MCPConnectionManager())
        let sut = try view.inspect()

        #expect(throws: Never.self) { try sut.find(text: "Send tasks to a tracker") }
        #expect(throws: Never.self) { try sut.find(text: "Ship the beta") }
        #expect(throws: Never.self) { try sut.find(text: "Write the RFC") }
        #expect(throws: Never.self) { try sut.find(text: "Owner: Alex") }
        // No connected tracker → the connect hint, not a filed state.
        #expect(throws: Never.self) {
            try sut.find(textWhere: { s, _ in s.contains("Connect Linear, Jira, or Asana") })
        }
    }

    @Test("the File action is disabled when no tracker is connected")
    func fileDisabledWithoutTracker() throws {
        let view = TaskWritebackSheet(tasks: [item("Do the thing")])
            .environmentObject(MCPConnectionManager())
        let button = try view.inspect().find(viewWithAccessibilityLabel: "File task: Do the thing")
        #expect(try button.button().isDisabled())
    }
}
