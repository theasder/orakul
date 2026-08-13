import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

@MainActor
@Suite("Workflow trace view")
struct WorkflowTraceViewTests {
    private let notion = WorkflowApp(
        id: "mcp:notion", name: "Notion", symbol: "note.text", kind: .mcp)
    private let linear = WorkflowApp(
        id: "mcp:linear", name: "Linear", symbol: "checklist", kind: .mcp)
    private let ai = WorkflowApp(
        id: "ai:auto", name: "Cruxwing AI", symbol: "sparkles", kind: .ai)

    @Test("renders stable app-attributed rows with safe operation results")
    func rendersAppsAndResults() throws {
        let steps = [
            WorkflowStep(
                id: 1, label: "Search relevant context", status: .succeeded,
                app: notion, tool: "notion-search", detail: "Context found"),
            WorkflowStep(
                id: 2, label: "Search relevant context", status: .running,
                app: linear, tool: "search_issues", detail: "Connecting via MCP"),
            WorkflowStep(
                id: 3, label: "Compose the answer", status: .pending,
                app: ai, tool: "auto"),
        ]
        let sut = try WorkflowTracePanel(steps: steps, streaming: true, initiallyExpanded: true).inspect()

        #expect(throws: Never.self) { try sut.find(text: "Workflow") }
        #expect(throws: Never.self) { try sut.find(text: "1/3 complete") }
        #expect(throws: Never.self) { try sut.find(text: "Notion") }
        #expect(throws: Never.self) { try sut.find(text: "Linear") }
        #expect(throws: Never.self) { try sut.find(text: "Cruxwing AI") }
        #expect(throws: Never.self) {
            try sut.find(textWhere: { value, _ in
                value.contains("notion-search") && value.contains("Context found")
            })
        }
        #expect(throws: Never.self) {
            try sut.find(viewWithAccessibilityLabel:
                "Search relevant context, Notion, MCP, notion-search, Completed")
        }
    }

    @Test("finished trace keeps skipped and failed outcomes visible")
    func finishedOutcomes() throws {
        let steps = [
            WorkflowStep(
                id: 1, label: "Search relevant context", status: .skipped,
                app: notion, detail: "No usable result; workflow continued"),
            WorkflowStep(
                id: 2, label: "Compose the answer", status: .failed,
                app: ai, detail: "Generation failed"),
        ]
        let sut = try WorkflowTracePanel(steps: steps, streaming: false, initiallyExpanded: true).inspect()

        #expect(throws: Never.self) { try sut.find(text: "Как получился этот ответ") }
        #expect(throws: Never.self) { try sut.find(text: "2/2 complete") }
        #expect(throws: Never.self) {
            try sut.find(viewWithAccessibilityLabel:
                "Search relevant context, Notion, MCP, Skipped")
        }
        #expect(throws: Never.self) {
            try sut.find(viewWithAccessibilityLabel:
                "Compose the answer, Cruxwing AI, AI API, Failed")
        }
    }
}
